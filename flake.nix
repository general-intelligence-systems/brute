{
  description = "brute — Ruby gem";
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    utils.url = "github:numtide/flake-utils";
  };
  outputs = { self, nixpkgs, utils }:
    utils.lib.eachDefaultSystem (system:
      let
        pkgs = nixpkgs.legacyPackages.${system};
        ruby = pkgs.ruby_3_4;
      in
      {
        devShells.default = pkgs.mkShell {
          nativeBuildInputs = [ pkgs.pkg-config ];
          buildInputs = with pkgs; [
            pkgs.trufflehog
            ruby
            libyaml 
            openssl
          ];

          shellHook = ''
            export GEM_HOME="$HOME/.gem-${ruby.version}"
            export GEM_PATH="$GEM_HOME"
            export PATH="$GEM_HOME/bin:$PATH"
            export BUNDLE_GEMFILE="$PWD/Gemfile"
            export BUNDLE_PATH="$GEM_HOME"
            export BUNDLE_BIN="$GEM_HOME/bin"
          '';
        };
      }
    );
}
