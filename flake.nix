{
  description = "Security Workspace Flake";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.05";
    nixpkgs-24-11.url = "github:NixOS/nixpkgs/nixos-24.11";
    nixpkgs-pr-angr-management.url = "github:NixOS/nixpkgs/pull/360310/head";
    pwndbg.url = "github:pwndbg/pwndbg";
  };

  outputs =
    {
      self,
      nixpkgs,
      nixpkgs-24-11,
      nixpkgs-pr-angr-management,
      pwndbg,
    }:
    {
      packages = {
        x86_64-linux =
          let
            system = "x86_64-linux";
            config = {
              allowUnfree = true;
              allowBroken = true; # angr is currently marked "broken" in nixpkgs, but works fine (without unicorn)
            };

            angr-management-overlay = self: super: {
              angr-management = (import nixpkgs-pr-angr-management { inherit system config; }).angr-management;
            };

            ida-free-overlay = self: super: {
              ida-free = (import nixpkgs-24-11 { inherit system config; }).ida-free;
            };

            pwndbg-overlay = self: super: {
              pwndbg = pwndbg.packages.${system}.pwndbg;
            };

            sage-overlay = final: prev: {
              sage = prev.sage.override {
                extraPythonPackages = ps: with ps; [
                  pycryptodome
                  pwntools
                ];
              requireSageTests = false;
              };
            };

            pkgs = import nixpkgs {
              inherit system config;
              overlays = [
                angr-management-overlay
                ida-free-overlay
                sage-overlay
                pwndbg-overlay
              ];
            };

            desktop-service = import ./services/desktop.nix { inherit pkgs; };

            ldd = pkgs.writeShellScriptBin "ldd" ''
              ldd=/usr/bin/ldd
              for arg in "$@"; do
                case "$arg" in
                  -*) ;;
                  *)
                    case "$(readlink -f "$arg")" in
                      /nix/store/*) ldd="${pkgs.lib.getBin pkgs.glibc}/bin/ldd" ;;
                    esac
                    ;;
                esac
              done
              exec "$ldd" "$@"
            '';

            additional = import ./additional/additional.nix { inherit pkgs; };

            basePackages = with pkgs; [
              bashInteractive
              cacert
              coreutils
              curl
              findutils
              gawk
              glibc
              glibc.static
              glibcLocales
              gnugrep
              gnused
              hostname
              iproute2
              less
              man
              ncurses
              nettools
              procps
              python3
              util-linux
              wget
              which

              (lib.hiPrio ldd)
              
              desktop-service
            ];

          in
          {
            default = pkgs.buildEnv {
              name = "security-env";
              paths = basePackages ++ additional.packages;
            };
          };
      };

    };
}
