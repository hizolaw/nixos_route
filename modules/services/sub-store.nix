{ config, lib, pkgs, ... }:
let
  cfg = config.router.subStore;
  state = "/var/lib/sub-store";
  prepare = pkgs.writeShellScript "sub-store-prepare" ''
    set -eu
    umask 077
    if [ ! -s ${state}/api-token ]; then
      ${pkgs.openssl}/bin/openssl rand -hex 32 > ${state}/api-token.tmp
      ${pkgs.coreutils}/bin/mv ${state}/api-token.tmp ${state}/api-token
    fi
  '';
  start = pkgs.writeShellScript "sub-store-start" ''
    set -eu
    SUB_STORE_FRONTEND_BACKEND_PATH="/$(cat ${state}/api-token)"
    export SUB_STORE_FRONTEND_BACKEND_PATH
    exec ${lib.getExe cfg.package}
  '';
  healthHost = if cfg.listenAddress == "0.0.0.0" then "127.0.0.1"
    else if cfg.listenAddress == "::" then "[::1]"
    else if lib.hasInfix ":" cfg.listenAddress then "[${cfg.listenAddress}]"
    else cfg.listenAddress;
  openURL = pkgs.writeShellScriptBin "sub-store-open-url" ''
    token=$(${pkgs.coreutils}/bin/cat ${state}/api-token)
    printf '${cfg.publicURL}/?api=${cfg.publicURL}/%s\n' "$token"
  '';
  health = pkgs.writeShellApplication {
    name = "sub-store-health";
    runtimeInputs = [ pkgs.curl pkgs.coreutils ];
    text = ''
      token=$(cat ${state}/api-token)
      # Pass the secret URL through stdin, not the process argument list.
      printf 'url = "http://${healthHost}:${toString cfg.port}/%s/api/utils/env"\n' "$token" |
        curl --config - --noproxy '*' --fail --silent --max-time 5 --output /dev/null
    '';
  };
in {
  options.router.subStore = {
    enable = lib.mkEnableOption "independent Sub-Store subscription manager";
    package = lib.mkOption {
      type = lib.types.package;
      default = pkgs.sub-store;
      description = "Sub-Store backend package; may be supplied from a newer package set.";
    };
    frontendPackage = lib.mkOption {
      type = lib.types.package;
      default = pkgs.sub-store-frontend;
      description = "Sub-Store static frontend package.";
    };
    listenAddress = lib.mkOption {
      type = lib.types.str;
      default = "127.0.0.1";
      description = "HTTP bind address. Only expose to a trusted LAN.";
    };
    publicURL = lib.mkOption {
      type = lib.types.str;
      default = "http://${healthHost}:${toString cfg.port}";
      description = "Browser-facing origin for the explicit sub-store-open-url command.";
    };
    allowedOrigins = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ cfg.publicURL ];
      description = "Browser origins allowed by Sub-Store, including its public frontend origin.";
    };
    port = lib.mkOption { type = lib.types.port; default = 17893; };
  };

  config = lib.mkIf cfg.enable {
    users.groups.sub-store = { };
    users.users.sub-store = {
      isSystemUser = true;
      group = "sub-store";
    };
    environment.systemPackages = [ health openURL ];
    systemd.services.sub-store = {
      description = "Sub-Store subscription manager";
      wantedBy = [ "multi-user.target" ];
      after = [ "network.target" ];
      environment = {
        SUB_STORE_DATA_BASE_PATH = state;
        SUB_STORE_BACKEND_API_HOST = cfg.listenAddress;
        SUB_STORE_BACKEND_API_PORT = toString cfg.port;
        SUB_STORE_BACKEND_MERGE = "true";
        SUB_STORE_CORS_ALLOWED_ORIGINS = lib.concatStringsSep "," cfg.allowedOrigins;
        SUB_STORE_FRONTEND_PATH = toString cfg.frontendPackage;
        NODE_OPTIONS = "--max-old-space-size=96";
      };
      serviceConfig = {
        User = "sub-store";
        Group = "sub-store";
        StateDirectory = "sub-store";
        StateDirectoryMode = "0700";
        WorkingDirectory = state;
        UMask = "0077";
        ExecStartPre = prepare;
        ExecStart = start;
        Restart = "on-failure";
        RestartSec = "3s";
        MemoryMax = "192M";
        # Upstream logs include the secret API prefix and subscription URLs.
        # Query systemd and sub-store-health instead of retaining these logs.
        StandardOutput = "null";
        StandardError = "null";
        NoNewPrivileges = true;
        ProtectSystem = "strict";
        ProtectHome = true;
        PrivateTmp = true;
        ReadWritePaths = [ state ];
        RestrictAddressFamilies = [ "AF_INET" "AF_INET6" "AF_UNIX" ];
      };
    };
  };
}
