#!/bin/bash
ARGS=(
    -m 4G -smp 2 -cpu qemu64
    -drive file=/Users/laurentvaldes/from-backup/reconstruction/windows_bootable.qcow2,format=qcow2,cache=writeback,if=ide,index=0
    -display cocoa
)

if [ "$1" = "cd" ]; then
    ARGS+=(
        -cdrom /Users/laurentvaldes/from-backup/Win10_22H2_French_x64.iso
        -boot once=d
    )
fi

qemu-system-x86_64 "${ARGS[@]}"
