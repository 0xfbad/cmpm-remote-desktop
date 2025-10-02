{ pkgs }:

let
  ghidra = import ./ghidra.nix { inherit pkgs; };
  burpsuite = import ./burpsuite.nix { inherit pkgs; };
  bata24-gef = import ./bata24-gef.nix { inherit pkgs; };

  firefox-configured = pkgs.wrapFirefox pkgs.firefox-unwrapped {
    extraPolicies = {
      DisplayBookmarksToolbar = "always";
      NoDefaultBookmarks = true;
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
      ];
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

    system = [ htop btop rsync openssh nftables psmisc whois lsof traceroute fastfetch ];

    editors = [ vim neovim emacs nano gedit helix ];

    terminal = [ tmux screen kitty.terminfo fzf tealdeer ];

    network = [ netcat-openbsd tcpdump wireshark termshark nmap burpsuite dig socat ];

    debugging = [ strace ltrace gdb pwndbg gef bata24-gef checksec ];

    reversing = [ file ghidra ida-free radare2 cutter angr-management binaryninja-free imhex binwalk ];

    web = [ firefox-configured geckodriver ungoogled-chromium ];

    exploitation = [ aflplusplus rappel ropgadget sage exploitdb ];

    utils = [ less jq libqalculate wordlists feh ];
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
