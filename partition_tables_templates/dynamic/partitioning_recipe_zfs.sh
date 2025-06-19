#!/bin/bash

# Dynamic generation of disk partitioning table which Subiquity autoinstaller will use.
# Run from the early commands section of user-data.

process_name=$(basename $0)

log () { printf '%s %s\n' "$me: " "$@"; }

# Fetch disk rotation and size properties
get_disk_details() {
  local disk=$1
  local rotational=$(cat /sys/block/$disk/queue/rotational)
  local size=$(cat /sys/block/$disk/size)                   	# size in kernel blocks (1024 bytes)
  # Install smartctl utility, do it quietly to preserve our return values
  type -a smartctl > /dev/null
  if [ $? -ne 0 ]; then
    wget http://mirrors.edge.kernel.org/ubuntu/pool/main/s/smartmontools/smartmontools_7.0-0ubuntu1~ubuntu18.04.1_amd64.deb -P /tmp > /dev/null
    dpkg -i /tmp/smartmontools* > /dev/null
  fi
  local serialnum=$(smartctl --all "/dev/$disk" | awk '/Serial Number/ { print $3 }')	# smartctl shows serial for both SATA and NVMe disk types
  echo "$rotational $size $serialnum"
}

# ---------------------------------------------------------
# Main
log "Started dynamic ${process_name}"

# Target path
recipe_file="/autoinstall.yaml"

# Iterate over all block devices and shortlist only devices "sd.." or "nvme.."
physical_block_devices=()
all_block_devices=$(lsblk -d -P)				# Example lsblk NAME="sda" MAJ:MIN="8:0" RM="0" SIZE="14.6T" RO="0" TYPE="disk" MOUNTPOINTS=""
while read block_device; do
    if echo "$block_device" | grep -q -E "NAME=\"(nvme|sd)"; then
        device_name=$(echo "$block_device" | awk ' { print $1 }' | cut -d'"' -f 2)
        #if ! grep -qs "$device_name" /proc/mounts; then		# Exclude disks already mounted
          physical_block_devices+="$device_name"$'\n'
        #fi
    fi
done <<< "$all_block_devices"

# Populate disks_listof file with all available disks
disks_listof="/disks_listof"
rm "$disks_listof"
terrabyte_block=$(("1<<30"))        # Block unit is 512B
while read disk; do
    if [ ! -z "$disk" ]; then             # There's always an empty string(?) glorious bash
        log "DISK: /dev/$disk"
        details=$(get_disk_details $disk)
echo "DETAILS: $details" >> /debug
        rotational=$(echo $details | cut -d ' ' -f 1)
        log "ROTATIONAL: $rotational"
        size=$(echo $details | cut -d ' ' -f 2)
        log "SIZE: $size"
        serialnum=$(echo $details | cut -d ' ' -f 3)
        log "SERIALNUMBER: $serialnum"

        # Store columns as: rotation device size serialnum
        printf "%s %s %d %s\n" "$rotational /dev/$disk $size $serialnum" >> "$disks_listof"
        echo
    fi
done <<< "$physical_block_devices"

if [ ! -f "$disks_listof" ]; then
    echo "ERROR no available disks found, exit failure"
    exit 255
fi

# Select the smallest SSD for system drive
os_disk_sortline=$(sort -k1,1 -k3,3 $disks_listof | head -n 1)		# Sort by SSD, then by size
rotational=$(echo "$os_disk_sortline" | awk ' { print $1 }')
if (( $rotational != 0 )); then
  # Disk is not an SSD, exit
  echo "ERROR no suitable SSD system disk found, exit failure"
  exit 255
fi
export OS_DISK=$(echo "$os_disk_sortline" | awk ' { print $2 }')	# Export for yq use later, as yq's strenv can only read from shell environment
OS_DISK_SIZE=$(echo "$os_disk_sortline" | awk ' { print 512*$3 }')   	# Blocks are 512B size
log "OS_DISK=$OS_DISK"
log "OS_DISK_SIZE=$OS_DISK_SIZE"

# Remove selected OS disk from the list of available disks
os_disk_sortline_escaped=$(echo "$os_disk_sortline" | sed "s|\/|\\\/|g")
sed -i "/$os_disk_sortline_escaped/d" "$disks_listof"

# Install yq version 4
YQ_BINARY_PATH=/usr/bin/yq
yq --version | grep -q "?*version v4." || wget https://github.com/mikefarah/yq/releases/download/v4.45.1/yq_linux_amd64 -O $YQ_BINARY_PATH
if [ -f $YQ_BINARY_PATH ]; then chmod 777 $YQ_BINARY_PATH; fi

# Replace storage layout, begin with a comment
yq -i '.storage.config = null' $recipe_file
yq -i '(.storage | key) line_comment="Dynamically generated storage layout"' $recipe_file

# Append NVMe interface, when necessary.  Place ahead of disk declaration.
if [[ $OS_DISK =~ nvme ]]; then
  yq -i '.storage.config |= . + [{
      "transport": "pcie",
      "preserve": true,
      "id": "nvme-controller-nvme0",
      "type": "nvme_controller"
    }]' $recipe_file
fi

# OS system disk
yq -i '.storage.config |= . + [{
    "id": "os-disk",
    "type": "disk",
    "path": strenv(OS_DISK),
    "ptable": "gpt",
    "wipe": "superblock-recursive",
    "preserve": false
    }]' $recipe_file
    #         "name": "",

# Insert NVMe interface into "os-disk" declaration, when necessary
if [[ $OS_DISK =~ nvme ]]; then
  yq -i '(.storage.config.[] | select(.id == "os-disk")) += {
    "nvme_controller": "nvme-controller-nvme0"
    }' $recipe_file
fi

# Prepare for UEFI or BIOS boot based on this installer host
if [ -d "/sys/firmware/efi" ]; then
  yq -i '(.storage.config.[] | select(.id == "os-disk")) += {
    "grub_device": false
    }' $recipe_file
else
  yq -i '(.storage.config.[] | select(.id == "os-disk")) += {
    "grub_device": true
    }' $recipe_file
fi

# Partition devices have different identifiers for SATA and NVMe
if [[ $OS_DISK =~ nvme ]]; then
  # NVMe partitions (nvme0n1)p1, (nvme0n1)p2
  export OS_BOOT_PARTITION="$OS_DISK"p1
  export OS_ROOT_PARTITION="$OS_DISK"p2
else
  # SATA partitions (sda)1, (sda)2
  export OS_BOOT_PARTITION="$OS_DISK"1
  export OS_ROOT_PARTITION="$OS_DISK"2
fi

# OS boot partition
yq -i '.storage.config |= . + [{
      "device": "os-disk",
      "id": "boot-partition",
      "type": "partition",
      "number": 1,
      "offset": 1048576,
      "preserve": false,
      "wipe": "superblock",
      "grub_device": true
  }]' $recipe_file
  #   "path": strenv(OS_BOOT_PARTITION),

 # Boot partition append bios grub flag for BIOS, or boot flag for UEFI
if [ -d "/sys/firmware/efi" ]; then
  yq -i '(.storage.config.[] | select(.id == "boot-partition")) += {
    "flag": "boot",
    "size": 1127219200
    }' $recipe_file
else
  yq -i '(.storage.config.[] | select(.id == "boot-partition")) += {
    "flag": "bios_grub",
    "grub_device": false,
    "size": 1048576
    }' $recipe_file
fi

# UEFI requires boot filesystem format FAT32
if [ -d "/sys/firmware/efi" ]; then
  yq -i '.storage.config |= . + [{
      "fstype": "fat32",
      "volume": "boot-partition",
      "preserve": false,
      "id": "boot-format",
      "type": "format"
  }]' $recipe_file
fi

# MOVED BOOT MOUNT BELOW..

# OS root partition
export OS_ROOT_PARTITION_SIZE=$(( ($OS_DISK_SIZE * 9)/10 ))     # Allocate 9/10 = 90%.  Spare space for TRIM and to minimise write amplification.
log "Choosing OS root partition size: $OS_ROOT_PARTITION_SIZE"
yq -i '.storage.config |= . + [{
      "device": "os-disk",
      "id": "root-partition",
      "type": "partition",
      "number": 2,
      "size": strenv(OS_ROOT_PARTITION_SIZE),
      "offset": 1128267776,
      "preserve": false,
      "wipe": "superblock",
      "grub_device": false
  }]' $recipe_file
  #     offset    2097152  1128267776
  #    "path": strenv(OS_ROOT_PARTITION),

# OS format /
yq -i '.storage.config |= . + [{
      "id": "root-format",
      "type": "format",
      "fstype": "ext4",
      "volume": "root-partition",
      "preserve": false
  }]' $recipe_file

# OS mount /
yq -i '.storage.config |= . + [{
      "id": "root-mount",
      "type": "mount",
      "device": "root-format",
      "path": "/"
  }]' $recipe_file

# UEFI requires boot mount
if [ -d "/sys/firmware/efi" ]; then
  yq -i '.storage.config |= . + [{
        "id": "boot-mount",
        "type": "mount",
        "device": "boot-format",
        "path": "/boot/efi"
    }]' $recipe_file
fi



# Select disks for the ZFS array, choose from the largest group of same sized disks
array_disk_size=$(awk '{counts[$3]++} END {for (value in counts) print value, counts[value]}' "$disks_listof" | sort -k2,2 | tail -n1 | cut -d ' ' -f1)
        # The above revolting piece of awk code is
        #       1) counting occurances of lines having the same size value,
        #       2) sort by occurances count,
        # 3) keep line having highest occurance,
        # 4) keep the size value only.
disks_zfs_array=$(grep $array_disk_size "$disks_listof")

build_zfs_cmd="/build_zfs_cmd"

# Write ZFS build command or warning message to the target
mkdir -p $(dirname "$build_zfs_cmd")          # Prepare parent directories
if [ $(echo "$disks_zfs_array" | wc -l) -ge 3 ]; then

  echo "zpool create -fn varimages raidz -m /var/images " > "$build_zfs_cmd.tmp"

  # Find ZFS disks by serial id
  while IFS= read -r disk_spec; do
    if [ ! -z "$disk_spec" ]; then             # Ignore empty string
      disk_serial=$(echo "$disk_spec" | awk ' { print $4 }')
      find /dev/disk/by-id/ -regextype posix-extended -regex ".*?(ata|nvme).*?$disk_serial$" >> "$build_zfs_cmd.tmp"
    fi
  done <<< "$disks_zfs_array"

  cat "$build_zfs_cmd.tmp" | tr '\n' ' ' > "$build_zfs_cmd.sh"
  rm "$build_zfs_cmd.tmp"
  chmod +x "$build_zfs_cmd.sh"
else
  log "Warning not enough drives found to create ZFS"
  log "Not creating build ZFS command"
  echo "Warning not enough drives found to create ZFS" > "$build_zfs_cmd.tmp"
fi

log
log "Partition recipe finished"

exit 0
