{ pkgs }:

let
  ghidra = import ./ghidra.nix { inherit pkgs; };
  burpsuite = import ./burpsuite.nix { inherit pkgs; };
  bata24-gef = import ./bata24-gef.nix { inherit pkgs; };

  ucscCert = pkgs.runCommand "ucsc-cert" {
    buildInputs = [ pkgs.openssl ];
  } ''
    mkdir -p $out
    echo | openssl s_client -connect cmpm-sec-01.acad.ucsc.edu:443 -showcerts 2>/dev/null | \
      openssl x509 -outform PEM > $out/cmpm-sec-01.pem
  '';

  firefox-configured = pkgs.wrapFirefox pkgs.firefox-unwrapped {
    extraPolicies = {
      DisplayBookmarksToolbar = "always";
      NoDefaultBookmarks = true;
      DontCheckDefaultBrowser = true;
      OverrideFirstRunPage = "";
      OverridePostUpdatePage = "";
      Homepage = {
        StartPage = "homepage";
        URL = "https://cmpm-sec-01.acad.ucsc.edu/challenges";
      };
      Bookmarks = [
        {
          Title = "Challenges";
          URL = "https://cmpm-sec-01.acad.ucsc.edu/challenges";
          Placement = "toolbar";
        }
        {
          Title = "SlugSec";
          URL = "https://slugsec.ucsc.edu";
          Placement = "toolbar";
        }
        {
          Title = "CyberChef";
          URL = "https://gchq.github.io/CyberChef/";
          Placement = "toolbar";
        }
        {
          Title = "you like jazz";
          URL = "mailto:iahphan@ucsc.edu?subject=important%20bee%20information&body=week%204%20testinggggggggggggggggggggggggggggggggggggggggggg";
          Placement = "toolbar";
        }
      ];
      Certificates = {
        ImportEnterpriseRoots = true;
        Install = [ "${ucscCert}/cmpm-sec-01.pem" ];
      };
      Preferences = {
        "security.sandbox.warn_unprivileged_namespaces" = false;
        "security.insecure_field_warning.contextual.enabled" = false;
        "security.insecure_password.ui.enabled" = false;
        "signon.rememberSignons" = false;
        "devtools.accessibility.enabled" = false;
        "devtools.memory.enabled" = false;
        "devtools.performance.enabled" = false;
        "devtools.application.enabled" = false;
      };
    };
  };

  pythonPackages = ps: with ps; [
    angr
    asteval
    flask
    ipython
    jupyter
    psutil
    pwntools
    pycryptodome
    pyroute2
    r2pipe
    requests
    ropper
    scapy
    selenium
  ];

  pythonEnv = pkgs.python3.withPackages pythonPackages;

  tools = with pkgs; {
    build = [ gcc gnumake cmake qemu ];

    compression = [ zip unzip gzip gnutar bzip2 rar ];

    system = [ htop btop rsync openssh nftables psmisc whois lsof traceroute fastfetch man-pages man-pages-posix ];

    editors = [ vim neovim emacs nano gedit helix ];

    terminal = [ tmux screen kitty.terminfo fzf tealdeer eza zoxide zsh-syntax-highlighting ];

    network = [ netcat-openbsd tcpdump wireshark termshark nmap burpsuite dig socat ];

    debugging = [ strace ltrace gdb pwndbg gef bata24-gef checksec ];

    reversing = [ file ghidra ida-free radare2 cutter angr-management binaryninja-free imhex binwalk ];

    web = [ firefox-configured geckodriver ungoogled-chromium ];

    exploitation = [ aflplusplus rappel ropgadget sage exploitdb ];

    utils = [ less jq libqalculate wordlists feh ranger lolcat tree mpv nyancat xdg-utils kitty ];
  };

in
{
  packages = with pkgs;
    [ (lib.hiPrio pythonEnv) ]
    ++ tools.build
    ++ tools.compression
    ++ tools.system
    ++ tools.editors
    ++ tools.terminal
    ++ tools.network
    ++ tools.debugging
    ++ tools.reversing
    ++ tools.web
    ++ tools.exploitation
    ++ tools.utils;
}
