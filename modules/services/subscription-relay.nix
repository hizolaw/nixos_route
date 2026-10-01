{ config, lib, pkgs, ... }:
let
 cfg = config.router.subscriptionRelay;
  subscriptionRelay = pkgs.writeText "mihomo-subscription-relay.py" ''
    from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
    from urllib.error import HTTPError, URLError
    from urllib.request import Request, urlopen

    class Handler(BaseHTTPRequestHandler):
        def do_OPTIONS(self):
            self.send_response(204)
            self.send_header("Access-Control-Allow-Origin", "*")
            self.send_header("Access-Control-Allow-Methods", "GET, OPTIONS")
            self.end_headers()

        def do_GET(self):
            target = self.path.lstrip("/")
            if not target.startswith(("http://", "https://")):
                self.send_error(400, "prefix the subscription URL with this relay URL")
                return
            try:
                request = Request(target, headers={"User-Agent": "clash.meta"})
                with urlopen(request, timeout=30) as upstream:
                    body = upstream.read()
                    self.send_response(upstream.status)
                    for name in ("Content-Type", "Content-Disposition",
                                 "Subscription-Userinfo", "Profile-Update-Interval"):
                        value = upstream.headers.get(name)
                        if value:
                            self.send_header(name, value)
                    self.send_header("Content-Length", str(len(body)))
                    self.send_header("Access-Control-Allow-Origin", "*")
                    self.end_headers()
                    self.wfile.write(body)
            except HTTPError as error:
                self.send_error(error.code, str(error.reason))
            except (URLError, TimeoutError, ValueError) as error:
                self.send_error(502, str(error))

        def log_message(self, format, *args):
            print("%s - %s" % (self.client_address[0], format % args), flush=True)

    ThreadingHTTPServer((${builtins.toJSON cfg.listenAddress}, ${toString cfg.port}), Handler).serve_forever()
  '';

in {
 options.router.subscriptionRelay = {
 enable = lib.mkEnableOption "subscription User-Agent relay";
 listenAddress = lib.mkOption { type = lib.types.str; };
 port = lib.mkOption { type = lib.types.port; default = 18080; };
 };
 config = lib.mkIf cfg.enable {
  systemd.services.mihomo-subscription-relay = {
    description = "LAN subscription relay with a Clash-compatible User-Agent";
    wantedBy = [ "multi-user.target" ];
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];
    serviceConfig = {
      ExecStart = "${pkgs.python3}/bin/python3 ${subscriptionRelay}";
      DynamicUser = true;
      Restart = "on-failure";
      RestartSec = "2s";
      NoNewPrivileges = true;
      PrivateTmp = true;
      ProtectSystem = "strict";
      ProtectHome = true;
      RestrictAddressFamilies = [ "AF_INET" "AF_INET6" ];
    };
  };

};
}
