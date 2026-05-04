#!/bin/bash
set -e

HOME_DIR=$(eval echo ~)
CONTROL_DISK="$HOME_DIR/VirtualBox VMs/llm-platform-control/ubuntu-24.04-aarch64-disk001.vmdk"
DATA_DISK="$HOME_DIR/VirtualBox VMs/llm-platform-data/ubuntu-24.04-aarch64-disk001.vmdk"

# Expected sizes in MB
CONTROL_EXPECTED_SIZE=40960
DATA_EXPECTED_SIZE=61440

echo "Checking disk sizes..."

# Function to get current disk size
get_disk_size() {
    local disk_path="$1"
    if [ -f "$disk_path" ]; then
      VBoxManage showmediuminfo disk "$disk_path" 2>/dev/null | grep "Capacity:" | awk '{print $2}' || echo "0"
    else
      echo "0"
    fi
}

# Resize control plane disk only if it doesn't exist or is smaller than expected
if VBoxManage list vms | grep -q "llm-platform-control"; then
  echo "Control VM exists, checking disk size..."
  CURRENT_SIZE=$(get_disk_size "$CONTROL_DISK")
  echo "  Current control disk size: ${CURRENT_SIZE}MB (expected: ${CONTROL_EXPECTED_SIZE}MB)"

  if [ "$CURRENT_SIZE" -lt "$CONTROL_EXPECTED_SIZE" ]; then
    echo "  Resizing control plane disk from ${CURRENT_SIZE}MB to ${CONTROL_EXPECTED_SIZE}MB..."
    VBoxManage modifymedium disk "$CONTROL_DISK" --resize $CONTROL_EXPECTED_SIZE || echo "Control disk resize completed or failed"
  else
    echo "  Control disk already at or above expected size, skipping resize"
  fi
else
  echo "Control VM does not exist yet, skipping resize (will be created with default size)"
fi

# Resize data plane disk only if it doesn't exist or is smaller than expected
if VBoxManage list vms | grep -q "llm-platform-data"; then
  echo "Data VM exists, checking disk size..."
  CURRENT_SIZE=$(get_disk_size "$DATA_DISK")
  echo "  Current data disk size: ${CURRENT_SIZE}MB (expected: ${DATA_EXPECTED_SIZE}MB)"

  if [ "$CURRENT_SIZE" -lt "$DATA_EXPECTED_SIZE" ]; then
    echo "  Resizing data plane disk from ${CURRENT_SIZE}MB to ${DATA_EXPECTED_SIZE}MB..."
    VBoxManage modifymedium disk "$DATA_DISK" --resize $DATA_EXPECTED_SIZE || echo "Data disk resize completed or failed"
  else
    echo "  Data disk already at or above expected size, skipping resize"
  fi
else
  echo "Data VM does not exist yet, skipping resize (will be created with default size)"
fi

echo "Disk resize check completed"
