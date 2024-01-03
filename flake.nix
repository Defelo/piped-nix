{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-23.11";
    proxy = {
      url = "github:TeamPiped/piped-proxy";
      flake = false;
    };
  };

  outputs = {
    self,
    nixpkgs,
    proxy,
    ...
  }: let
    inherit (nixpkgs) lib;
    defaultSystems = [
      "aarch64-linux"
      "aarch64-darwin"
      "x86_64-darwin"
      "x86_64-linux"
    ];
    eachDefaultSystem = lib.genAttrs defaultSystems;
  in {
    packages = eachDefaultSystem (system: let
      pkgs = import nixpkgs {inherit system;};
    in {
      frontend = {};
      backend = {};
      proxy = pkgs.rustPlatform.buildRustPackage {
        name = "piped-proxy";
        src = proxy;
        cargoLock.lockFile = "${proxy}/Cargo.lock";
      };
    });

    nixosModules.default = {
      config,
      lib,
      pkgs,
      ...
    }: {
      options.services.piped = with lib; {
        enable = mkEnableOption "piped";

        proxy.domain = mkOption {
          type = types.str;
        };
      };

      config = let
        cfg = config.services.piped;
      in
        lib.mkIf cfg.enable {
          systemd.services = {
            piped-proxy = {
              wantedBy = ["multi-user.target"];
              serviceConfig = {
                User = "piped-proxy";
                Group = "piped-proxy";
                DynamicUser = true;
                RuntimeDirectory = "piped-proxy";
              };
              environment = {
                UDS = "true";
                BIND_UNIX = "/run/piped-proxy/actix.sock";
              };
              script = ''
                ${self.packages.${pkgs.system}.proxy}/bin/piped-proxy
              '';
              postStart = ''
                coproc {
                  ${pkgs.inotify-tools}/bin/inotifywait -q -m -e create /run/piped-proxy/
                }
                trap 'kill "$COPROC_PID"' EXIT TERM
                until test -S /run/piped-proxy/actix.sock; do
                  read -r -u "''${COPROC[0]}"
                done
                chmod 0666 /run/piped-proxy/actix.sock
              '';
            };
          };

          services.nginx = {
            enable = true;
            virtualHosts = {
              ${cfg.proxy.domain} = let
                conf = ''
                  proxy_buffering on;
                  proxy_buffers 1024 16k;
                  proxy_set_header X-Forwarded-For "";
                  proxy_set_header CF-Connecting-IP "";
                  proxy_hide_header "alt-svc";
                  sendfile on;
                  sendfile_max_chunk 512k;
                  tcp_nopush on;
                  aio threads=default;
                  aio_write on;
                  directio 16m;
                  proxy_hide_header Cache-Control;
                  proxy_hide_header etag;
                  proxy_http_version 1.1;
                  proxy_set_header Connection keep-alive;
                  proxy_max_temp_file_size 32m;
                  access_log off;
                  proxy_pass http://unix:/run/piped-proxy/actix.sock;
                '';
              in {
                locations."~ (/videoplayback|/api/v4/|/api/manifest/)".extraConfig = ''
                  ${conf}
                  more_set_headers "Cache-Control: private always";
                '';
                locations."/".extraConfig = ''
                  ${conf}
                  more_set_headers "Cache-Control: public, max-age=604800";
                '';
              };
            };
          };
        };
    };
  };
}
