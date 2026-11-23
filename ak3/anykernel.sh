### AnyKernel3 Ramdisk Mod Script
## osm0sis @ xda-developers

### AnyKernel setup
properties() { '
kernel.string=OnePlus 15 6.12.58 KernelSU SUSFS
do.devicecheck=0
do.modules=0
do.systemless=0
do.cleanup=1
do.cleanuponabort=0
do.check_boot_version=0
device.name1=
supported.versions=
supported.patchlevels=
supported.vendorpatchlevels=
'; } # end properties

### AnyKernel install
block=boot
is_slot_device=auto
ramdisk_compression=auto
patch_vbmeta_flag=auto
no_magisk_check=1

. tools/ak3-core.sh

kernel_version=$(cat /proc/version | awk '{print $3}')
case $kernel_version in
  6.12*) ;;
  *) abort "  -> This kernel is for 6.12 GKI (OnePlus 15), current: $kernel_version" ;;
esac

split_boot
if [ -f "$SPLITIMG/ramdisk.cpio" ]; then
  unpack_ramdisk
  write_boot
else
  flash_boot
fi
