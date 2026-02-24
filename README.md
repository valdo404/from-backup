# from-backup

Restore a Windows Image Backup (VHDX) to a bootable Parallels virtual disk, using a Parallels Windows VM as an intermediary for NTFS repair.

## Why?

Windows Image Backup produces per-partition VHDX files that are often:
- **Sparse** — cannot be mounted by diskpart/Hyper-V
- **NTFS-compressed** — same issue
- **Corrupted** — MFT/bitmap errors from incomplete backups

These issues can only be fixed with Windows-native tools (`fsutil`, `compact`, `chkdsk`). This toolset automates the repair via a running Parallels VM, then reassembles the partitions into a single bootable GPT disk.

## Scripts

### `restore_backup_to_vm.sh`

Copies the backup into the VM and repairs the VHDX files:

1. **Robocopy** the backup into the VM (`/MIR /MT:16 /J` for max throughput)
2. **Desparse + decompress** all VHDX files (`fsutil sparse setflag 0` + `compact /u`)
3. **Mount + chkdsk /f** on every partition of every VHDX

### `reconstruct_disk.sh`

Retrieves the repaired files and builds a bootable Parallels disk:

1. **Robocopy** the repaired backup back to the Mac
2. **Convert** each VHDX to raw with `qemu-img`
3. **Assemble** a full GPT disk (EFI + MSR + Windows + Recovery) with `sgdisk` + `dd`
4. **Convert** to Parallels HDD format with `qemu-img`

## Prerequisites

- macOS with [Parallels Desktop](https://www.parallels.com/)
- A running Windows VM (with Parallels Tools installed for `prlctl exec`)
- `qemu-img` (`brew install qemu`)
- `sgdisk` (`brew install gptfdisk`)

## Configuration

Copy `.env.example` and set the required variables:

```bash
cp .env.example .env
# Edit .env with your values
source .env
```

### Required environment variables

| Variable | Used by | Description |
|---|---|---|
| `VM_NAME` | both | Parallels VM name (e.g. `Windows 11`) |
| `BACKUP_SOURCE` | restore | UNC path to the backup as seen from the VM |
| `BACKUP_SUBDIR` | restore | Subfolder containing the VHDX files |
| `RECON_DIR` | reconstruct | Local path for reconstruction workspace |
| `RECON_SHARE` | reconstruct | UNC path to `RECON_DIR` as seen from the VM |

## Usage

```bash
source .env

# Step 1: Copy backup to VM, repair VHDX files
./restore_backup_to_vm.sh

# Step 2: Retrieve repaired files, build Parallels disk
./reconstruct_disk.sh
```

The resulting `reconstruction/windows_restored.hdd` can be attached to a new Parallels VM (EFI boot mode).

## License

MIT
