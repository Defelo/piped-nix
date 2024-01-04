{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-23.11";
    pnpm2nix.url = "github:nzbr/pnpm2nix-nzbr";
    frontend = {
      url = "github:TeamPiped/Piped";
      flake = false;
    };
    backend = {
      url = "github:TeamPiped/Piped-Backend";
      flake = false;
    };
    proxy = {
      url = "github:TeamPiped/piped-proxy";
      flake = false;
    };
  };

  outputs = {
    self,
    nixpkgs,
    pnpm2nix,
    frontend,
    backend,
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
      frontend = pnpm2nix.packages.${system}.mkPnpmPackage {
        name = "piped-frontend";
        src = frontend;
      };
      backend = pkgs.writeShellScriptBin "piped-backend" ''
        MAX_MEMORY=''${MAX_MEMORY:-1G}
        ${pkgs.jdk21}/bin/java -server -Xmx"$MAX_MEMORY" -XX:+UnlockExperimentalVMOptions -XX:+HeapDumpOnOutOfMemoryError -XX:+OptimizeStringConcat -XX:+UseStringDeduplication -XX:+UseCompressedOops -XX:+UseNUMA -XX:+UseG1GC -jar ${./backend.jar}
      '';
      proxy = pkgs.rustPlatform.buildRustPackage {
        name = "piped-proxy";
        src = proxy;
        cargoLock.lockFile = "${proxy}/Cargo.lock";
      };

      buildBackend = pkgs.writeShellScriptBin "build-piped-backend" ''
        set -ex
        export PATH=${lib.makeBinPath (with pkgs; [coreutils findutils gnused jdk21])}
        tmp=$(mktemp -d)
        trap "rm -rf $tmp" EXIT TERM ERR
        cp -r ${backend} $tmp/backend
        chmod -R +w $tmp
        pushd $tmp/backend
        export GRADLE_USER_HOME=$tmp/.gradle-home
        ./gradlew --no-daemon shadowJar
        popd
        cp $tmp/backend/build/libs/*.jar backend.jar
      '';
    });

    nixosModules.default = {
      config,
      lib,
      pkgs,
      ...
    }: {
      options.services.piped = with lib; {
        enable = mkEnableOption "piped";

        frontend.domain = mkOption {
          type = types.str;
        };

        backend = {
          domain = mkOption {
            type = types.str;
          };
          port = mkOption {
            type = types.port;
          };
          settings = mkOption {
            type = types.attrsOf types.str;
          };
          database = {
            host = mkOption {
              type = types.str;
            };
            port = mkOption {
              type = types.port;
              default = 5432;
            };
            username = mkOption {
              type = types.str;
              default = "piped";
            };
            passwordFile = mkOption {
              type = types.path;
            };
            database = mkOption {
              type = types.str;
              default = "piped";
            };
            createLocally = mkOption {
              type = types.bool;
              default = true;
            };
          };
        };

        proxy.domain = mkOption {
          type = types.str;
        };

        defaultNginxConfig = mkOption {
          type = types.attrsOf types.anything;
          default = {};
        };
      };

      config = let
        cfg = config.services.piped;
      in
        lib.mkIf cfg.enable {
          services.piped.backend.settings = {
            PORT = toString cfg.backend.port;
            HTTP_WORKERS = lib.mkDefault "2";
            PROXY_PART = "https://${cfg.proxy.domain}";
            API_URL = "https://${cfg.backend.domain}";
            FRONTEND_URL = "https://${cfg.frontend.domain}";
            COMPROMISED_PASSWORD_CHECK = lib.mkDefault "true";
            DISABLE_REGISTRATION = lib.mkDefault "true";
            FEED_RETENTION = lib.mkDefault "30";
          };

          services.piped.backend.database = lib.mkIf cfg.backend.database.createLocally {
            host = "127.0.0.1";
          };
          services.postgresql = lib.mkIf cfg.backend.database.createLocally {
            enable = true;
            enableTCPIP = true;
            ensureDatabases = [cfg.backend.database.database];
            ensureUsers = [
              {
                name = cfg.backend.database.username;
                ensureDBOwnership = true;
              }
            ];
          };

          systemd.services = {
            piped-backend = {
              wantedBy = ["multi-user.target"];
              serviceConfig = {
                User = "piped-backend";
                Group = "piped-backend";
                DynamicUser = true;
                RuntimeDirectory = "piped-backend";
                LoadCredential = ["databasePassword:${cfg.backend.database.passwordFile}"];
              };
              environment = cfg.backend.settings;
              preStart = let
                db = cfg.backend.database;
              in ''
                cat << EOF > /run/piped-backend/config.properties
                hibernate.connection.url: jdbc:postgresql://${db.host}:${toString db.port}/${db.database}
                hibernate.connection.driver_class: org.postgresql.Driver
                hibernate.dialect: org.hibernate.dialect.PostgreSQLDialect
                hibernate.connection.username: ${db.username}
                hibernate.connection.password: $(cat $CREDENTIALS_DIRECTORY/databasePassword)
                EOF
              '';
              script = ''
                cd /run/piped-backend
                ${self.packages.${pkgs.system}.backend}/bin/piped-backend
              '';
            };

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
            appendHttpConfig = ''
              proxy_cache_path /tmp/pipedapi_cache levels=1:2 keys_zone=pipedapi:4m max_size=2g inactive=60m use_temp_path=off;
            '';
            virtualHosts = {
              ${cfg.frontend.domain} = lib.mkMerge [
                cfg.defaultNginxConfig
                {
                  root = pkgs.runCommand "piped-frontend-patched" {} ''
                    cp -r ${self.packages.${pkgs.system}.frontend} $out
                    chmod -R +w $out
                    ${pkgs.gnused}/bin/sed -i s/pipedapi.kavin.rocks/${cfg.backend.domain}/g $out/{opensearch.xml,assets/*}
                  '';
                  locations."/".tryFiles = "$uri /index.html";
                }
              ];

              ${cfg.backend.domain} = lib.mkMerge [
                cfg.defaultNginxConfig
                {
                  locations."/" = {
                    proxyPass = "http://127.0.0.1:${toString cfg.backend.port}";
                    proxyWebsockets = true;
                    extraConfig = ''
                      proxy_cache pipedapi;
                    '';
                  };
                  locations."/webhooks/pubsub" = {
                    proxyPass = "http://127.0.0.1:${toString cfg.backend.port}";
                    proxyWebsockets = true;
                    extraConfig = ''
                      proxy_cache pipedapi;
                      allow all;
                    '';
                  };
                }
              ];

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
              in
                lib.mkMerge [
                  cfg.defaultNginxConfig
                  {
                    locations."~ (/videoplayback|/api/v4/|/api/manifest/)".extraConfig = ''
                      ${conf}
                      more_set_headers "Cache-Control: private always";
                    '';
                    locations."/".extraConfig = ''
                      ${conf}
                      more_set_headers "Cache-Control: public, max-age=604800";
                    '';
                  }
                ];
            };
          };
        };
    };
  };
}
