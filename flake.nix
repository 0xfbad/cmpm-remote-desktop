{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    treefmt-nix.url = "github:numtide/treefmt-nix";
  };

  outputs = { self, nixpkgs, treefmt-nix }:
    let
      systems = [ "x86_64-linux" "aarch64-linux" "x86_64-darwin" "aarch64-darwin" ];
      eachSystem = f: nixpkgs.lib.genAttrs systems (system: f nixpkgs.legacyPackages.${system});
      treefmtEval = eachSystem (pkgs: treefmt-nix.lib.evalModule pkgs ./treefmt.nix);
    in
    {
      formatter = eachSystem (pkgs: treefmtEval.${pkgs.system}.config.build.wrapper);

      checks = eachSystem (pkgs: {
        formatting = treefmtEval.${pkgs.system}.config.build.check self;
        hadolint = pkgs.runCommand "hadolint" { nativeBuildInputs = [ pkgs.hadolint ]; } ''
          hadolint --config ${self}/.hadolint.yaml ${self}/Dockerfile
          touch $out
        '';
      });

      devShells = eachSystem (pkgs: {
        default = pkgs.mkShell {
          packages = with pkgs; [
            shfmt
            shellcheck
            hadolint
          ];
          shellHook = ''
            echo "nix fmt              format all"
            echo "nix flake check      run all checks"
            echo "shellcheck **/*.sh   lint shell scripts"
            echo "hadolint Dockerfile  lint dockerfile"
          '';
        };
      });
    };
}
