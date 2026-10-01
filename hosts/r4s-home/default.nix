{ ... }: {
  imports = [ ../../hardware/nanopi-r4s-ddr3 ../../profiles/side-router.nix ];
  networking.hostName = "r4s";
  router.network = {
    interfaces = [ "eth0" "eth1" ];
    address = "192.168.1.5";
    gateway = "192.168.1.1";
  };
  networking.interfaces.eth1.macAddress = "a2:fe:c3:06:8f:79";
  router.udpxy = {
    enable = true;
    listenAddress = "192.168.1.5";
    # Physical WAN eth0 is a member of br0; IPv4/IGMP belongs to the bridge.
    multicastInterface = "br0";
  };
  router.access.sshKeys = [
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIIwhLf3GOrAj8BuOZrRGNf3JbCF4aTsoUuk8Xu0X4ivR hzluo@macbook-t2"
  ];
  system.stateVersion = "24.05";
}
