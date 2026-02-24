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
4. **Generate a manifest** (`manifest.json`) describing each VHDX, its partitions, filesystems and roles (EFI, Windows, Recovery)

### `reconstruct_disk.sh`

Retrieves the repaired files and builds a bootable Parallels disk:

1. **Robocopy** the repaired backup back to the Mac
2. **Read the manifest** to identify partition roles (no guessing by size)
3. **Convert** each VHDX to raw with `qemu-img`
4. **Parse GPT tables** of each raw image with `sgdisk` to find exact partition offsets
5. **Assemble** a full GPT disk (EFI + MSR + Windows + Recovery) with `sgdisk` + `dd`
6. **Verify** the final GPT table with `sgdisk --verify`
7. **Convert** to Parallels HDD format with `qemu-img`

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
| `MANIFEST_FILE` | both | Path to the manifest file (written by restore, read by reconstruct) |
| `RECON_DIR` | reconstruct | Local path for reconstruction workspace |
| `RECON_SHARE` | reconstruct | UNC path to `RECON_DIR` as seen from the VM |

## Usage

```bash
source .env

# Step 1: Copy backup to VM, repair VHDX files, generate manifest
./restore_backup_to_vm.sh

# Step 2: Retrieve repaired files, build Parallels disk
./reconstruct_disk.sh
```

The resulting `reconstruction/windows_restored.hdd` can be attached to a new Parallels VM (EFI boot mode).

## License

MIT
