{
  description = "brute examples — runnable agents";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, utils }:
    utils.lib.eachDefaultSystem (system:
      let
        pkgs = nixpkgs.legacyPackages.${system};

        runner = pkgs.writeShellApplication {
          name = "agent";
          runtimeInputs = [ pkgs.nix ];
          text = ''
            dir="''${1:?usage: nix run . <directory> [args...]}"
            shift
            exec nix run "path:${./.}/$dir" -- "$@"
          '';
        };

        scheduler = pkgs.writeShellApplication {
          name = "agent-schedule";
          runtimeInputs = [ pkgs.nix ];
          text = ''
            dir="''${1:?usage: nix run .#schedule <directory> [args...]}"
            shift
            AGENT_UNIT="$dir" exec nix run "path:${./.}/$dir#schedule" -- "$@"
          '';
        };
      in
      {
        devShells.default = pkgs.mkShell {
          buildInputs = with pkgs; [
            # nothing here right now
          ];
        };

        apps.default = {
          type = "app";
          program = "${runner}/bin/agent";
        };

        apps.schedule = {
          type = "app";
          program = "${scheduler}/bin/agent-schedule";
        };
      }
    );
}
