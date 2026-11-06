{
  # These stable labels are the root-disk installation contract. Partitioning
  # and formatting are manual operations, never part of system activation.
  fileSystems."/" = {
    device = "/dev/disk/by-label/NIXOS_ROOT";
    fsType = "ext4";
  };

  fileSystems."/boot" = {
    device = "/dev/disk/by-label/NIXOS_BOOT";
    fsType = "vfat";
    options = [
      "fmask=0077"
      "dmask=0077"
    ];
  };

  # Provision and verify this unique label locally. Keep physical device
  # identifiers in private records. Its absence must not prevent boot.
  fileSystems."/var/backup-secondary" = {
    device = "/dev/disk/by-label/CAZ_BACKUPS";
    fsType = "ext4";
    options = [
      "nofail"
      "nodev"
      "nosuid"
      "noexec"
      "x-systemd.device-timeout=10s"
    ];
  };

  boot.initrd.availableKernelModules = [
    "ahci"
    "nvme"
    "sd_mod"
    "uas"
    "usb_storage"
    "xhci_pci"
  ];
  boot.kernelModules = [ "kvm-intel" ];
}
