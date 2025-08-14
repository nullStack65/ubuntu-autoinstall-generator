#!/usr/bin/env python3
"""
Ubuntu Autoinstall ISO Builder - Python Version
Creates a modified Ubuntu Server ISO with autoinstall parameters injected into boot configs.
"""

import argparse
import os
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path
from typing import Optional, List, Tuple
import logging

# Configure logging
logging.basicConfig(
    level=logging.INFO,
    format='[%(asctime)s] %(levelname)s: %(message)s',
    datefmt='%H:%M:%S'
)
logger = logging.getLogger(__name__)


class UbuntuISOBuilder:
    def __init__(self, source_iso: Path, output_iso: Optional[Path] = None,
                 http_ip: str = "10.0.2.2", http_port: int = 8080):
        self.source_iso = Path(source_iso)
        self.output_iso = Path(output_iso) if output_iso else Path(f"{self.source_iso.stem}-autoinstall.iso")
        self.http_ip = http_ip
        self.http_port = http_port
        self.work_dir = None
        self.iso_dir = None
        
        # Autoinstall parameters
        self.autoinstall_params = f"autoinstall ds=nocloud-net;s=http://{http_ip}:{http_port}/"
        
        # Boot configuration patterns
        self.grub_patterns = [
            # Standard kernel patterns
            (r'(linux\s+/casper/(?:hwe-)?vmlinuz)(\s+---\s+|\s*$)', 
             rf'\1 {self.autoinstall_params}\2'),
            # EFI kernel patterns  
            (r'(linuxefi\s+/casper/(?:hwe-)?vmlinuz)(\s+---\s+|\s*$)', 
             rf'\1 {self.autoinstall_params}\2'),
        ]
        
        self.isolinux_pattern = (r'(append\s+)', rf'\1{self.autoinstall_params} ')

    def __enter__(self):
        self.work_dir = Path(tempfile.mkdtemp(prefix="ubuntu_iso_"))
        self.iso_dir = self.work_dir / "iso"
        return self
        
    def __exit__(self, exc_type, exc_val, exc_tb):
        if self.work_dir and self.work_dir.exists():
            shutil.rmtree(self.work_dir)

    def check_dependencies(self) -> None:
        """Check if required tools are available."""
        required = ['xorriso']
        missing = []
        
        for tool in required:
            if not shutil.which(tool):
                missing.append(tool)
                
        if missing:
            raise RuntimeError(f"Missing required tools: {', '.join(missing)}")

    def validate_iso(self) -> Tuple[str, str]:
        """Validate source ISO and detect version/format."""
        if not self.source_iso.exists():
            raise FileNotFoundError(f"Source ISO not found: {self.source_iso}")
            
        # Extract version info
        version = "Unknown"
        try:
            result = subprocess.run([
                'xorriso', '-osirrox', 'on', '-indev', str(self.source_iso),
                '-extract', '/.disk/info', str(self.work_dir / 'info.txt')
            ], capture_output=True, text=True, timeout=30)
            
            if result.returncode == 0:
                info_file = self.work_dir / 'info.txt'
                if info_file.exists():
                    content = info_file.read_text()
                    match = re.search(r'(\d{2}\.\d{2})', content)
                    if match:
                        version = match.group(1)
        except subprocess.TimeoutExpired:
            logger.warning("Version detection timed out")
        except Exception as e:
            logger.warning(f"Could not detect version: {e}")
            
        # Detect format by listing files
        iso_format = "Unknown"
        try:
            result = subprocess.run([
                'xorriso', '-indev', str(self.source_iso), '-find', '/', '-type', 'f'
            ], capture_output=True, text=True, timeout=60)
            
            if result.returncode == 0:
                files = result.stdout
                if 'casper/vmlinuz' in files:
                    iso_format = "Live Server"
                elif 'boot/grub' in files:
                    iso_format = "GRUB EFI"
                elif '1-Boot-NoEmul.img' in files:
                    iso_format = "Legacy Boot"
        except subprocess.TimeoutExpired:
            logger.warning("Format detection timed out")
        except Exception as e:
            logger.warning(f"Could not detect format: {e}")
            
        logger.info(f"Detected Ubuntu version: {version}")
        logger.info(f"Detected ISO format: {iso_format}")
        return version, iso_format

    def extract_iso(self) -> None:
        """Extract ISO contents to working directory."""
        logger.info("Extracting ISO contents...")
        self.iso_dir.mkdir(parents=True, exist_ok=True)
        
        try:
            result = subprocess.run([
                'xorriso', '-osirrox', 'on', '-indev', str(self.source_iso),
                '-extract', '/', str(self.iso_dir)
            ], capture_output=True, text=True, timeout=300)
            
            if result.returncode != 0:
                raise RuntimeError(f"ISO extraction failed: {result.stderr}")
                
            # Make files writable
            for root, dirs, files in os.walk(self.iso_dir):
                for d in dirs:
                    os.chmod(os.path.join(root, d), 0o755)
                for f in files:
                    os.chmod(os.path.join(root, f), 0o644)
                    
        except subprocess.TimeoutExpired:
            raise RuntimeError("ISO extraction timed out")

    def modify_file_with_patterns(self, file_path: Path, patterns: List[Tuple[str, str]]) -> bool:
        """Modify a file using regex patterns."""
        if not file_path.exists():
            return False
            
        try:
            content = file_path.read_text(encoding='utf-8', errors='ignore')
            original_content = content
            
            for pattern, replacement in patterns:
                content = re.sub(pattern, replacement, content, flags=re.MULTILINE)
                
            # Clean up multiple spaces
            content = re.sub(r'  +', ' ', content)
            
            if content != original_content:
                # Backup original
                backup_path = file_path.with_suffix(file_path.suffix + '.bak')
                backup_path.write_text(original_content, encoding='utf-8')
                
                # Write modified content
                file_path.write_text(content, encoding='utf-8')
                logger.info(f"Modified boot config: {file_path.name}")
                return True
                
        except Exception as e:
            logger.error(f"Failed to modify {file_path}: {e}")
            
        return False

    def modify_boot_configs(self) -> None:
        """Modify all boot configuration files."""
        logger.info("Modifying boot configurations...")
        
        modified_count = 0
        
        # GRUB configuration files
        grub_configs = [
            self.iso_dir / 'boot' / 'grub' / 'grub.cfg',
            self.iso_dir / 'EFI' / 'BOOT' / 'grub.cfg',
            self.iso_dir / 'boot' / 'grub' / 'loopback.cfg',
        ]
        
        for config_file in grub_configs:
            if self.modify_file_with_patterns(config_file, self.grub_patterns):
                modified_count += 1
                
        # ISOLINUX configuration files
        isolinux_configs = [
            self.iso_dir / 'isolinux' / 'isolinux.cfg',
            self.iso_dir / 'isolinux' / 'txt.cfg',
            self.iso_dir / 'syslinux' / 'isolinux.cfg',
            self.iso_dir / 'syslinux' / 'txt.cfg',
        ]
        
        for config_file in isolinux_configs:
            if self.modify_file_with_patterns(config_file, [self.isolinux_pattern]):
                modified_count += 1
                
        if modified_count == 0:
            logger.warning("No boot configuration files were modified")
        else:
            logger.info(f"Successfully modified {modified_count} boot configuration files")

    def get_volume_label(self) -> str:
        """Extract volume label from source ISO."""
        try:
            result = subprocess.run([
                'xorriso', '-indev', str(self.source_iso), '-report_about', 'NOTE'
            ], capture_output=True, text=True, timeout=30)
            
            if result.returncode == 0:
                for line in result.stderr.split('\n'):
                    if 'Volume id' in line:
                        match = re.search(r"Volume id\s+:\s+'([^']+)'", line)
                        if match:
                            return match.group(1)
        except Exception as e:
            logger.warning(f"Could not extract volume label: {e}")
            
        return "Ubuntu"

    def detect_boot_structure(self) -> Tuple[bool, bool]:
        """Detect if ISO has UEFI and/or BIOS boot support."""
        # Ubuntu 22.04+ uses EFI/boot/bootx64.efi instead of boot/grub/efi.img
        has_uefi = (
            (self.iso_dir / 'boot' / 'grub' / 'efi.img').exists() or
            (self.iso_dir / 'EFI' / 'boot' / 'bootx64.efi').exists()
        )
        has_bios = (self.iso_dir / 'isolinux' / 'isolinux.bin').exists()
        
        logger.info(f"Boot structure - UEFI: {'✓' if has_uefi else '✗'}, BIOS: {'✓' if has_bios else '✗'}")
        return has_uefi, has_bios

    def create_iso(self) -> None:
        """Create the modified ISO by replicating the original's boot structure."""
        import shlex  # Import shlex for robust command parsing

        logger.info("Creating modified ISO...")
        
        # 1. Extract the exact boot arguments from the original ISO.
        # This is the most reliable way to ensure the new ISO is bootable.
        logger.info("Extracting boot information from original ISO...")
        try:
            result = subprocess.run(
                ['xorriso', '-indev', str(self.source_iso), '-report_el_torito', 'as_mkisofs'],
                capture_output=True, text=True, check=True, timeout=60
            )
            # Use shlex.split to correctly parse the command-line arguments,
            # handling quotes and spaces properly. This is the key fix.
            boot_args = shlex.split(result.stdout.strip())
            logger.info(f"Successfully extracted {len(boot_args)} boot arguments.")

        except (subprocess.CalledProcessError, subprocess.TimeoutExpired) as e:
            stderr = e.stderr if hasattr(e, 'stderr') else 'Timeout'
            raise RuntimeError(f"Failed to extract boot information from source ISO: {stderr}")

        # 2. Build the final xorriso command.
        # Start with the basic command and add our specific overrides.
        cmd = [
            'xorriso', '-as', 'mkisofs',
            '-r',  # Add Rock Ridge extensions for permissions
            '-o', str(self.output_iso),
        ]
        
        # Add the extracted boot arguments, which contain the correct volume ID,
        # boot catalog, boot images, and all other necessary parameters.
        cmd.extend(boot_args)
        
        # Finally, add the path to the source directory for the new ISO.
        cmd.append(str(self.iso_dir))
        
        logger.info("Creating new ISO with replicated boot structure...")
        logger.debug(f"Running command: {shlex.join(cmd)}")
        
        try:
            result = subprocess.run(cmd, capture_output=True, text=True, timeout=600)
            
            if result.returncode != 0:
                # Provide detailed error output from xorriso for easier debugging
                logger.error(f"xorriso failed with exit code {result.returncode}")
                logger.error(f"xorriso stdout:\n{result.stdout}")
                logger.error(f"xorriso stderr:\n{result.stderr}")
                raise RuntimeError("ISO creation failed. See logs above for details.")

            if not self.output_iso.exists():
                raise RuntimeError("Output ISO was not created")
                
            size_mb = self.output_iso.stat().st_size / (1024 * 1024)
            if size_mb < 1:
                raise RuntimeError(f"Output ISO seems too small: {size_mb:.1f} MB")
                
            logger.info(f"✓ ISO created successfully: {self.output_iso} ({size_mb:.1f} MB)")
            
        except subprocess.TimeoutExpired:
            raise RuntimeError("ISO creation timed out")

    def build(self, validate_only: bool = False) -> None:
        """Main build process."""
        self.check_dependencies()
        version, iso_format = self.validate_iso()
        
        if validate_only:
            logger.info("Validation complete ✅")
            return
            
        if self.output_iso.exists():
            logger.info(f"Output ISO already exists: {self.output_iso}")
            return
            
        logger.info(f"Building autoinstall ISO for Ubuntu {version} ({iso_format})")
        logger.info(f"HTTP server: {self.http_ip}:{self.http_port}")
        logger.info("⚠️  Ensure your HTTP server serves:")
        logger.info(f"   - http://{self.http_ip}:{self.http_port}/user-data")
        logger.info(f"   - http://{self.http_ip}:{self.http_port}/meta-data")
        
        self.extract_iso()
        self.modify_boot_configs()
        self.create_iso()
        
        logger.info("🎉 Build complete!")
        logger.info(f"Output: {self.output_iso}")


def main():
    parser = argparse.ArgumentParser(
        description="Create Ubuntu autoinstall ISO with injected boot parameters",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
Examples:
  %(prog)s ubuntu-22.04.4-live-server-amd64.iso
  %(prog)s --source ubuntu.iso --output custom.iso --http-server 192.168.1.100
  %(prog)s --validate-only ubuntu.iso
        """
    )
    
    parser.add_argument('iso_file', nargs='?', help='Source Ubuntu ISO file')
    parser.add_argument('--source', help='Source Ubuntu ISO file')
    parser.add_argument('--output', help='Output ISO filename')
    parser.add_argument('--http-server', default='10.0.2.2', help='HTTP server IP (default: 10.0.2.2)')
    parser.add_argument('--http-port', type=int, default=8080, help='HTTP server port (default: 8080)')
    parser.add_argument('--validate-only', action='store_true', help='Only validate ISO, don\'t build')
    parser.add_argument('--verbose', '-v', action='store_true', help='Verbose output')
    
    args = parser.parse_args()
    
    if args.verbose:
        logging.getLogger().setLevel(logging.DEBUG)
        
    # Determine source ISO
    source_iso = args.source or args.iso_file
    if not source_iso:
        parser.error("No source ISO specified")
        
    # Use environment variables if available
    http_ip = os.environ.get('PACKER_HTTP_IP', args.http_server)
    http_port = int(os.environ.get('PACKER_HTTP_PORT', args.http_port))
    
    try:
        with UbuntuISOBuilder(
            source_iso=source_iso,
            output_iso=args.output,
            http_ip=http_ip,
            http_port=http_port
        ) as builder:
            builder.build(validate_only=args.validate_only)
            
    except KeyboardInterrupt:
        logger.error("Build interrupted by user")
        sys.exit(1)
    except Exception as e:
        logger.error(f"Build failed: {e}")
        sys.exit(1)


if __name__ == '__main__':
    main()