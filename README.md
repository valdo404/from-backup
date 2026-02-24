# from-backup

Restore a Windows Image Backup (VHDX) to a usable virtual disk, using a Parallels Windows VM as an intermediary for NTFS repair.

## Why?

Windows Image Backup produces per-partition VHDX files that are often:
- **Sparse** — cannot be mounted by diskpart/Hyper-V
- **NTFS-compressed** — same issue
- **Corrupted** — MFT/bitmap errors from incomplete backups

These issues can only be fixed with Windows-native tools (`fsutil`, `compact`, `chkdsk`). This toolset automates the repair via a running Parallels VM, then reassembles the partitions into a usable disk.

## Scripts

### `restore_backup_to_vm.sh`

Copies the backup into the VM and repairs the VHDX files:

1. **Robocopy** the backup into the VM (`/MIR /MT:16 /J` for max throughput)
2. **Desparse + decompress** all VHDX files
3. **Mount + chkdsk /f** on every partition of every VHDX
4. **Generate a manifest** (`manifest.json`) describing each VHDX, its partitions, filesystems and roles

### `retrieve_from_vm.sh`

Copies the repaired VHDX files back from the VM to the Mac via robocopy.

### `build_parallels_data.sh`

Builds a **data-only GPT disk** (not bootable) for Parallels:
- Reads the manifest to identify partitions
- Parses actual GPT offsets from each VHDX with `sgdisk`
- Assembles Windows + Recovery partitions into a single disk
- Converts to Parallels HDD format
- Attach as a secondary disk to access files

### `build_qemu_bootable.sh`

Builds a **bootable MBR disk** for QEMU (x86_64 emulation on Apple Silicon):
- Reads the manifest to identify partitions
- Creates an MBR disk with System Reserved + Windows + Recovery
- Installs MBR bootstrap for BIOS boot
- Converts to qcow2 (compressed)
- Boot with `qemu-system-x86_64`

## Prerequisites

- macOS with [Parallels Desktop](https://www.parallels.com/)
- A running Windows VM (with Parallels Tools installed for `prlctl exec`)
- `qemu-img` (`brew install qemu`)
- `sgdisk` (`brew install gptfdisk`)

## Configuration

```bash
cp .env.example .env
# Edit .env with your values
source .env
```

### Required environment variables

| Variable | Used by | Description |
|---|---|---|
| `VM_NAME` | restore, retrieve | Parallels VM name |
| `BACKUP_SOURCE` | restore | UNC path to the backup as seen from the VM |
| `BACKUP_SUBDIR` | restore | Subfolder containing the VHDX files |
| `MANIFEST_FILE` | all | Path to the manifest (written by restore, read by others) |
| `RECON_DIR` | retrieve, build | Local path for reconstruction workspace |
| `RECON_SHARE` | retrieve | UNC path to `RECON_DIR` as seen from the VM |

## Usage

```bash
source .env

# Step 1: Repair VHDX files via the VM
./restore_backup_to_vm.sh

# Step 2: Copy repaired files back to Mac
./retrieve_from_vm.sh

# Step 3a: Build a data disk for Parallels
./build_parallels_data.sh

# Step 3b: Or build a bootable disk for QEMU
./build_qemu_bootable.sh
```

## License

MIT
