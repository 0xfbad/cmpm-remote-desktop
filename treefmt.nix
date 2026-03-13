{
  projectRootFile = "flake.nix";
  programs.shfmt.enable = true;
  programs.shellcheck.enable = true;
  settings.global.excludes = [ ".envrc" ];
}
