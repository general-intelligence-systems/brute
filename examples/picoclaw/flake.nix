{
  description = "picoclaw-clone";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, utils }:
    utils.lib.eachDefaultSystem (system:
      let
        name = baseNameOf ./.;

        pkgs = nixpkgs.legacyPackages.${system};

        gems = pkgs.bundlerEnv {
          name = name;
          ruby = pkgs.ruby_3_4;
          gemfile = ./Gemfile;
          lockfile = ./Gemfile.lock;
          gemset = ./gemset.nix;
          # extralite is a native extension — it needs sqlite headers/lib.
          gemConfig = pkgs.defaultGemConfig // {
            extralite = attrs: {
              buildInputs = [ pkgs.sqlite pkgs.sqlite.dev ];
              dontUseBundlerConfigure = true;
              buildFlags = [ "--with-sqlite3-dir=${pkgs.sqlite.dev}" ];
            };
          };
        };



        runner = pkgs.writeShellApplication {
          name = name;
          runtimeInputs = [ pkgs.nix pkgs.coreutils ];
          text = ''
            if [ "''${1:-}" = "--overwrite" ]; then
              shift
              cp -r --no-preserve=mode --remove-destination ${./work}/. .
            else
              cp -r --no-preserve=mode ${./work}/. .
            fi
            nix develop "path:${./.}" -c ruby ${./main.rb} "$@"
          '';
        };

        scheduler = pkgs.writeShellApplication {
          name = "${name}-schedule";
          text = ''
            schedule="''${PICOCLAW_CLONE_SCHEDULE:-hourly}"
            dir="''${1:-$PWD}"
            if [ $# -gt 0 ]; then shift; fi
            dir="$(realpath "$dir")"
            unit="''${AGENT_UNIT:-${name}}"
            chgrp users "$dir"
            chmod g+rwXs "$dir"
            if [ "$(id -u)" -eq 0 ]; then sudo_cmd=(); else sudo_cmd=(sudo); fi
            cert_file="''${SSL_CERT_FILE:-/etc/ssl/certs/ca-certificates.crt}"
            # DynamicUser=yes implies ProtectSystem=strict, PrivateTmp=yes,
            # RemoveIPC=yes and NoNewPrivileges=yes.
            "''${sudo_cmd[@]}" systemctl stop "$unit".timer "$unit".service 2>/dev/null || true
            "''${sudo_cmd[@]}" systemctl reset-failed "$unit".timer "$unit".service 2>/dev/null || true
            "''${sudo_cmd[@]}" systemd-run \
              --unit="$unit" \
              --description="$unit agent on $dir" \
              --on-calendar="$schedule" \
              --property=DynamicUser=yes \
              --property=SupplementaryGroups=users \
              --property=StateDirectory="$unit" \
              --property=UMask=0002 \
              --property=ProtectHome=tmpfs \
              --property=PrivateDevices=yes \
              --property=ProtectProc=invisible \
              --property=ProtectClock=yes \
              --property=ProtectHostname=yes \
              --property=ProtectKernelLogs=yes \
              --property=ProtectKernelModules=yes \
              --property=ProtectKernelTunables=yes \
              --property=ProtectControlGroups=yes \
              --property=LockPersonality=yes \
              --property=RestrictRealtime=yes \
              --property=RestrictSUIDSGID=yes \
              --property=RestrictNamespaces=yes \
              --property=SystemCallArchitectures=native \
              --property=MemoryDenyWriteExecute=yes \
              --property=CapabilityBoundingSet= \
              --property=SocketBindDeny=any \
              --property=InaccessiblePaths=/run/dbus \
              --property="RestrictAddressFamilies=AF_UNIX AF_INET AF_INET6" \
              --property="SystemCallFilter=@system-service" \
              --property=BindPaths="$dir" \
              --property=WorkingDirectory="$dir" \
              --property=Environment=HOME="$dir" \
              --property=Environment=XDG_CACHE_HOME="$dir/.cache" \
              --property=Environment=XDG_STATE_HOME="$dir/.local/state" \
              --property=Environment=SSL_CERT_FILE="$cert_file" \
              --property=BindReadOnlyPaths="$cert_file" \
              "$@" \
              ${runner}/bin/${name}
          '';
        };
      in
      {
        devShells.default = pkgs.mkShell {
          buildInputs = with pkgs; [
            gems
            gems.wrappedRuby
            bundix
            libyaml
            openssl
          ];
        };

        apps.default = {
          type = "app";
          program = "${runner}/bin/${name}";
        };

        apps.schedule = {
          type = "app";
          program = "${scheduler}/bin/${name}-schedule";
        };
      }
    );
}
