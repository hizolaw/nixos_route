{ config, lib, ... }: {
  options.router.access.sshKeys = lib.mkOption { type = lib.types.listOf lib.types.str; default = []; };
  config = {
    services.openssh = {
      enable = true;
      settings.PermitRootLogin = "prohibit-password";
      settings.PasswordAuthentication = false;
      openFirewall = true;
    };
    users.users.root.openssh.authorizedKeys.keys = config.router.access.sshKeys;
    users.users.nixos = {
      isNormalUser = true;
      extraGroups = [ "wheel" ];
      openssh.authorizedKeys.keys = config.router.access.sshKeys;
    };
  };
}
