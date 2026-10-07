{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    treefmt-nix.url = "github:numtide/treefmt-nix";
  };

  outputs =
    {
      self,
      nixpkgs,
      treefmt-nix,
    }:
    let
      systems = [
        "x86_64-linux"
        "aarch64-linux"
        "x86_64-darwin"
        "aarch64-darwin"
      ];
      eachSystem = f: nixpkgs.lib.genAttrs systems (system: f nixpkgs.legacyPackages.${system});
      treefmtEval = eachSystem (pkgs: treefmt-nix.lib.evalModule pkgs ./treefmt.nix);
    in
    {
      formatter = eachSystem (pkgs: treefmtEval.${pkgs.system}.config.build.wrapper);

      checks = eachSystem (
        pkgs:
        let
          ttydInstaller = builtins.readFile ./install/install-ttyd.sh;
          ttydPin =
            re: what:
            let
              m = builtins.match re ttydInstaller;
            in
            if m == null then throw "install-ttyd.sh: cannot extract ${what}" else builtins.head m;
          ttydVersion = ttydPin ".*\nTTYD_VERSION=([^\n]+)\n.*" "TTYD_VERSION";
          ttydSha256 = ttydPin ".*\nTTYD_SOURCE_SHA256=([0-9a-f]{64})\n.*" "TTYD_SOURCE_SHA256";
          ttydSource = pkgs.fetchurl {
            url = "https://github.com/tsl0922/ttyd/archive/refs/tags/${ttydVersion}.tar.gz";
            sha256 = ttydSha256;
          };
        in
        {
          formatting = treefmtEval.${pkgs.system}.config.build.check self;
          hadolint = pkgs.runCommand "hadolint" { nativeBuildInputs = [ pkgs.hadolint ]; } ''
            hadolint --config ${self}/.hadolint.yaml ${self}/Dockerfile
            touch $out
          '';
          # xfconf and firefox ignore malformed configuration at runtime
          config-validation =
            pkgs.runCommand "config-validation"
              {
                nativeBuildInputs = [
                  pkgs.jq
                  pkgs.libxml2
                ];
              }
              ''
                cd ${self}
                find configs -name '*.xml' -exec xmllint --noout {} +
                jq -e . configs/firefox/policies.json >/dev/null
                jq -e . configs/tlog/tlog-rec-session.conf >/dev/null
                touch $out
              '';
          script-validation =
            pkgs.runCommand "script-validation"
              {
                nativeBuildInputs = [
                  pkgs.bash
                  pkgs.findutils
                  pkgs.shellcheck
                  pkgs.zsh
                ];
              }
              ''
                cd ${self}
                while IFS= read -r -d $'\0' script; do
                  bash -n "$script"
                  shellcheck -x -P "$PWD" "$script"
                done < <(find configs install provisioning -type f \
                  \( -name '*.sh' -o -name '*.bash' \) -print0)
                # zsh -n only parses its first file argument
                zsh -n configs/zshrc
                zsh -n configs/session-init/hooks.zsh
                touch $out
              '';
          python-tests =
            pkgs.runCommand "python-tests"
              {
                nativeBuildInputs = [ pkgs.python3 ];
              }
              ''
                cd ${self}
                export PYTHONPYCACHEPREFIX="$TMPDIR/pycache"
                python3 -m py_compile \
                  provisioning/tlog/rd_tlog_collector.py \
                  configs/session-init/collector
                touch $out
              '';
          provisioning-safety =
            pkgs.runCommand "provisioning-safety"
              {
                nativeBuildInputs = [
                  pkgs.bash
                  pkgs.coreutils
                  pkgs.gnugrep
                  pkgs.jq
                ];
              }
              ''
                cd ${self}
                bash provisioning/storage/tests/storage-safety-static.sh
                bash provisioning/storage/tests/storage-install-regression.sh
                bash provisioning/tlog/tests/tlog-store-safety-static.sh
                touch $out
              '';
          ttyd-patch =
            pkgs.runCommand "ttyd-patch"
              {
                nativeBuildInputs = [
                  pkgs.gnutar
                  pkgs.gzip
                  pkgs.patch
                ];
              }
              ''
                mkdir source
                tar -xzf ${ttydSource} -C source --strip-components=1
                patch --batch --forward --fuzz=0 --dry-run -d source -p1 \
                  < ${self}/install/ttyd-zero-frame.patch
                patch --batch --forward --fuzz=0 -d source -p1 \
                  < ${self}/install/ttyd-zero-frame.patch
                touch $out
              '';
          systemd-unit-contracts =
            pkgs.runCommand "systemd-unit-contracts"
              {
                nativeBuildInputs = [ pkgs.gnugrep ];
              }
              ''
                grep -Fx 'Requires=rd-network-policy.service' \
                  ${self}/provisioning/network/systemd/docker.service.d/10-rd-network-policy.conf
                grep -Fx 'After=rd-network-policy.service' \
                  ${self}/provisioning/network/systemd/docker.service.d/10-rd-network-policy.conf
                grep -Fx 'After=local-fs.target nftables.service' \
                  ${self}/provisioning/network/systemd/rd-network-policy.service
                grep -Fx 'Before=network-pre.target docker.service' \
                  ${self}/provisioning/network/systemd/rd-network-policy.service
                grep -Fx 'PartOf=nftables.service' \
                  ${self}/provisioning/network/systemd/rd-network-policy.service
                grep -Fx 'MemoryMax=90%' \
                  ${self}/provisioning/compute/systemd/rd.slice
                grep -Fx 'MemoryMin=2G' \
                  ${self}/provisioning/compute/systemd/system.slice.d/50-rd-host-reserve.conf
                grep -Fx 'ExecStart=/usr/local/lib/rd-io-tripwire.sh' \
                  ${self}/provisioning/storage/systemd/rd-io-tripwire.service
                grep -Fx 'ExecCondition=/usr/bin/systemctl --quiet is-active docker.service' \
                  ${self}/provisioning/storage/systemd/rd-io-tripwire.service
                grep -Fx 'ExecCondition=/usr/bin/systemctl --quiet is-active docker.service' \
                  ${self}/provisioning/compute/telemetry/rd-telemetry.service
                ! grep -Eq '^(Requires|Wants)=docker\.service$' \
                  ${self}/provisioning/storage/systemd/rd-io-tripwire.service
                ! grep -Eq '^(Requires|Wants)=docker\.service$' \
                  ${self}/provisioning/compute/telemetry/rd-telemetry.service
                touch $out
              '';
        }
      );

      devShells = eachSystem (pkgs: {
        default = pkgs.mkShell {
          packages = with pkgs; [
            shfmt
            shellcheck
            hadolint
            python3Packages.pytest
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
