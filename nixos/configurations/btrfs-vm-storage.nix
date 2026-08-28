{ ... }:
{
  # Development and contract-test VMs receive a dedicated Atlas data disk.
  # The host system remains independently operable if environment data fills
  # this filesystem. Physical installation and encryption remain separate
  # proofs.
  virtualisation.emptyDiskImages = [ 4096 ];

  virtualisation.fileSystems."/var/lib/atlas" = {
    device = "/dev/vdb";
    fsType = "btrfs";
    autoFormat = true;
    options = [
      "compress=zstd"
      "noatime"
    ];
  };
}
