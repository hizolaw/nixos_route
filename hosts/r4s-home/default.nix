{ config, ... }: {
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
  services.router-console = {
    enable = true;
    listenAddress = config.router.network.address;
    port = 9080;
    environmentFiles = [ "-/var/lib/metacubexd/environment" ];
    settings = {
      title = "R4S · Router Console";
      plugins = [
        { id = "system"; name = "系统资源"; kind = "system"; interval_secs = 5; }
        {
          id = "dns"; name = "局域网 DNS"; kind = "dns";
          dns_server = "${config.router.network.address}:53";
          dns_name = "example.com";
        }
        {
          id = "mihomo"; name = "Mihomo API"; kind = "http";
          probe_url = "http://127.0.0.1:${toString config.router.metacubexd.apiPort}/version";
          token_env = "CLASH_SECRET";
          url = "http://${config.router.network.address}:${toString config.router.metacubexd.port}";
        }
        {
          id = "dashboard"; name = "现有代理面板"; kind = "http";
          probe_url = "http://127.0.0.1:${toString config.router.metacubexd.port}/";
          url = "http://${config.router.network.address}:${toString config.router.metacubexd.port}";
        }
        {
          id = "udpxy"; name = "udpxy"; kind = "http";
          enabled = config.router.udpxy.enable;
          probe_url = "http://${config.router.network.address}:${toString config.router.udpxy.port}/status";
          url = "http://${config.router.network.address}:${toString config.router.udpxy.port}/status";
        }
      ];
    };
  };
  router.access.sshKeys = [
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIIwhLf3GOrAj8BuOZrRGNf3JbCF4aTsoUuk8Xu0X4ivR hzluo@macbook-t2"
  ];
  system.stateVersion = "24.05";
}
