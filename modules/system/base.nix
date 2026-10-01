{ pkgs, ... }: {
  # Persist the journal so a crash can be diagnosed from the SD card.
  services.journald.storage = "persistent";

  # A router does not need the NixOS manual or man pages.
  documentation = {
    enable = false;
    man.enable = false;
  };

  # ------------------------------------------------------------------ nix
  nix.settings = {
    experimental-features = [
      "nix-command"
      "flakes"
    ];
    substituters = [
      "https://mirrors.ustc.edu.cn/nix-channels/store"
      "https://cache.nixos.org"
    ];
    trusted-public-keys = [
      "cache.nixos.org-1:6NCHdD59X431o0gWypbMrAURkbJ16ZPMQFGspcDShjY="
    ];
  };

  # ----------------------------------------------------------------- misc
  time.timeZone = "Asia/Shanghai";
  i18n.defaultLocale = "en_US.UTF-8";

  environment.systemPackages = with pkgs; [
    curl
    git
    htop
    vim
    just
  ];

}
