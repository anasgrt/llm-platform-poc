# Automatic Disk Expansion - WORKING ✅

## Overview

The Vagrant setup now automatically resizes VM disks to **60GB** on first boot for both VMs.

**Disk sizes:**
- **Control plane**: 60GB disk
- **Data plane**: 60GB disk (for LLM workloads)

## How It Works

### 1. Vagrant Trigger (Automatic)

After running `vagrant up`, a trigger resizes the VirtualBox VMDK disks:

```ruby
config.trigger.after :up do |trigger|
  # Resizes both disks to 60GB (61440MB)
  # Commands are idempotent - ignore errors if already resized
  VBoxManage modifymedium disk ... --resize 61440
end
```

**Key features:**
- Runs after VM creation
- Idempotent - ignores errors if disk is already resized
- Resizes both control and data planes

### 2. Provision Script (Automatic)

The `vagrant-provision.sh` script's `expand_disk()` function:
- Detects LVM vs non-LVM setups
- Grows the partition table using `growpart`
- For LVM: Resizes physical volume → logical volume → filesystem
- Safe to run multiple times (idempotent)

## Verification

```bash
# Check VirtualBox disk size
VBoxManage list hdds | grep -A2 "llm-platform"

# Check filesystem size inside VMs
vagrant ssh control -c "df -h /"  # Should show 60G
vagrant ssh data -c "df -h /"     # Should show 60G
```

## Current Status

✅ **Verified Working** (as of May 2, 2026)
- Both VMs automatically get 60GB disks on `vagrant up`
- VirtualBox disk: 65536 MB (64GB formatted)
- Filesystem: 60GB usable space
- No manual intervention required!

### 2. Provision Script (Automatic)

The `vagrant-provision.sh` script's `expand_disk()` function:
- Detects LVM vs non-LVM setups
- Grows the partition table using `growpart`
- For LVM: Resizes physical volume → logical volume → filesystem
- For non-LVM: Resizes partition → filesystem directly
- Safe to run multiple times (idempotent)

## Manual Intervention (If Needed)

If automatic expansion fails, you can manually resize:

### Resize VirtualBox Disk
```bash
# Halt the VM
vagrant halt data

# Resize disk (data plane = 60GB = 61440MB)
VBoxManage modifymedium disk "~/VirtualBox VMs/llm-platform-data/ubuntu-24.04-aarch64-disk001.vmdk" --resize 61440

# Start VM
vagrant up data
```

### Expand LVM/Filesystem Inside VM
```bash
vagrant ssh data -c "
  sudo lvextend -l +100%FREE /dev/mapper/ubuntu--vg-ubuntu--lv &&
  sudo resize2fs /dev/mapper/ubuntu--vg-ubuntu--lv &&
  df -h /
"
```

## Verification

Check disk size after provisioning:
```bash
# Check VirtualBox disk size
VBoxManage list hdds | grep -A2 "llm-platform-data"

# Check filesystem size inside VM
vagrant ssh data -c "df -h /"

# Expected output: 60G total, ~38G available on data plane
```

## Troubleshooting

### Issue: "Failed to lock media when resizing"
**Cause**: VM is running when trying to resize disk
**Solution**:
1. `vagrant halt <vm-name>`
2. Run VBoxManage resize command
3. `vagrant up <vm-name>`

### Issue: Disk shows correct size but filesystem is small
**Cause**: Partition/filesystem not expanded after disk resize
**Solution**: Run provision script or manually expand:
```bash
vagrant ssh data -c "sudo /vagrant/vagrant-provision.sh data"
```

### Issue: Vagrant trigger didn't run
**Cause**: Trigger only runs on initial `vagrant up` after `vagrant destroy`
**Solution**: Manually resize using VBoxManage commands above, or:
```bash
vagrant destroy -f
vagrant up  # Triggers will run again
```

## History

- **Before**: Manual disk resize required after every `vagrant destroy` + `vagrant up`
- **After**: Automatic resize on first boot, idempotent on re-provision
- **Disk sizes**: Increased from 30GB default to 40GB (control) and 60GB (data) to accommodate LLM images
