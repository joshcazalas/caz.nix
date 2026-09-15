{ pkgs }:
let
  requirements = [
    {
      path = "/mnt/state/app";
      filesystem = {
        mountPoint = "/mnt/state";
        device = "/dev/disk/by-label/PREFLIGHT_DATA";
        fsType = "ext4";
      };
      minimumFreeMiB = 8;
      minimumFreeInodes = 32;
    }
    {
      path = "/mnt/efi";
      filesystem = {
        mountPoint = "/mnt/efi";
        device = "/dev/disk/by-label/TEST_EFI";
        fsType = "vfat";
      };
      minimumFreeMiB = 8;
      minimumFreeInodes = 32;
    }
  ];
  checker = pkgs.writeShellApplication {
    name = "caz-check-deployment-storage";
    runtimeInputs = [ pkgs.util-linux ];
    text = ''
      exec ${pkgs.python3}/bin/python ${../scripts/check-deployment-storage.py} \
        --config ${pkgs.writeText "storage-test.json" (builtins.toJSON requirements)}
    '';
  };
  metadata = pkgs.writeText "release.json" (
    builtins.toJSON {
      id = 123;
      tag_name = "caz.nix-2026.09.14-g0123456789ab";
      target_commitish = "0123456789ab0000000000000000000000000000";
      published_at = "2026-09-14T00:00:00Z";
      draft = false;
      prerelease = false;
      immutable = true;
      assets = [ ];
    }
  );
  mockCommands = pkgs.runCommand "storage-preflight-mock-commands" { } ''
    mkdir -p "$out/bin"
    cat > "$out/bin/curl" <<'SH'
    #!${pkgs.bash}/bin/bash
    while (( $# > 0 )); do
      if [[ "$1" == --output ]]; then
        cp ${metadata} "$2"
        exit 0
      fi
      shift
    done
    exit 22
    SH
    for name in nix nix-env caz-pre-deployment-backup; do
      cat > "$out/bin/$name" <<'SH'
    #!${pkgs.bash}/bin/bash
    touch /tmp/unexpected-deployment-work
    exit 99
    SH
    done
    chmod +x "$out/bin/"*
  '';
in
pkgs.testers.runNixOSTest {
  name = "deployment-storage";
  nodes.server = {
    virtualisation.emptyDiskImages = [
      128
      64
    ];
    environment.systemPackages = [
      checker
      pkgs.dosfstools
      pkgs.e2fsprogs
      pkgs.jq
      pkgs.parted
    ];
    system.stateVersion = "26.05";
  };
  testScript = ''
    start_all()
    server.wait_for_unit("multi-user.target")
    server.succeed("mkfs.ext4 -F -L PREFLIGHT_DATA /dev/vdb")
    # Use a partitioned EFI disk like the server. Whole-disk mkfs.fat can
    # create a fake MBR entry, making udev's label point at vdc1 while a mount
    # of vdc reports the whole-disk device number instead.
    server.succeed("parted --script /dev/vdc mklabel gpt mkpart ESP fat32 1MiB 100% set 1 esp on")
    server.succeed("udevadm settle; mkfs.vfat -F 32 -n TEST_EFI /dev/vdc1")
    server.succeed("udevadm settle; mkdir -p /mnt/state /mnt/efi")
    server.succeed("mount /dev/vdb /mnt/state; mount /dev/vdc1 /mnt/efi; mkdir /mnt/state/app")
    listing = server.succeed("find /mnt/state /mnt/efi -printf '%p\\n' | sort")
    server.succeed("caz-check-deployment-storage")
    assert listing == server.succeed("find /mnt/state /mnt/efi -printf '%p\\n' | sort")

    server.succeed("rmdir /mnt/state/app")
    assert "directory is missing" in server.fail("caz-check-deployment-storage 2>&1")
    server.succeed("mkdir /mnt/state/app")

    server.succeed("mount -o remount,ro /mnt/state")
    assert "read-only" in server.fail("caz-check-deployment-storage 2>&1")
    server.succeed("mount -o remount,rw /mnt/state")

    server.succeed("umount /mnt/efi")
    assert "expected mount /mnt/efi, found /" in server.fail("caz-check-deployment-storage 2>&1")

    # Run the real updater with local discovery fixtures. Storage must stop it
    # before any build, backup, profile change, or quarantine record.
    server.succeed("mkdir -p /boot /home /root /run/user /tmp/updater-runtime")
    status, output = server.execute(
        "PATH=${mockCommands}/bin:$PATH "
        "CAZ_RELEASE_STATE_DIRECTORY=/tmp/updater-state "
        "RUNTIME_DIRECTORY=/tmp/updater-runtime "
        "${pkgs.bash}/bin/bash ${../scripts/stage-server-release.sh} 2>&1"
    )
    assert status == 1, output
    assert "expected mount /mnt/efi, found /" in output, output
    server.fail("test -e /tmp/unexpected-deployment-work")
    server.fail("test -e /tmp/updater-state/failed-release.json")
    server.fail("test -e /tmp/updater-state/accepted-release.json")

    server.succeed("mount /dev/vdb /mnt/efi")
    assert "mounted device does not match" in server.fail("caz-check-deployment-storage 2>&1")
    server.succeed("umount /mnt/efi; mount /dev/vdc1 /mnt/efi")

    # Fill only a disposable test disk, leaving less than its 8 MiB threshold.
    server.succeed("available=$(df --output=avail -B1 /mnt/state | tail -1); fallocate -l $((available - 4*1024*1024)) /mnt/state/fill")
    assert "need at least 8 MiB" in server.fail("caz-check-deployment-storage 2>&1")
    server.succeed("rm /mnt/state/fill; caz-check-deployment-storage")
  '';
}
