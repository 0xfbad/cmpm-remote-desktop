{ pkgs }:

let

  # revert novnc pr 1672 - breaks reconnect functionality
  reconnectPatch = pkgs.writeText "reconnect_patch.diff" ''
    --- a/share/webapps/novnc/app/ui.js
    +++ b/share/webapps/novnc/app/ui.js
    @@ -1,3 +1,3 @@
    -        if (UI.getSetting('reconnect', false) === true && !UI.inhibitReconnect) {
    +        else if (UI.getSetting('reconnect', false) === true && !UI.inhibitReconnect) {
  '';
  novnc = pkgs.novnc.overrideAttrs (oldAttrs: {
    postInstall = (oldAttrs.postInstall or "") + ''
      patch -p1 -d $out < ${reconnectPatch}
    '';
  });

  desktopService = pkgs.symlinkJoin {
    name = "desktop-service-env";
    paths = [ 
      xfce 
      pkgs.elementary-xfce-icon-theme
      (pkgs.runCommand "desktop-configs" {} ''
        mkdir -p $out
        cp -r ${./desktop}/* $out/
      '')
    ];
  };

  serviceScript = pkgs.writeScript "desktop-service" ''
    #!${pkgs.bash}/bin/bash

    # machine-id required for dbus
    if [ ! -f /etc/machine-id ]; then
      ${pkgs.dbus}/bin/dbus-uuidgen > /etc/machine-id
    fi
    mkdir -p /var/lib/dbus
    ln -sf /etc/machine-id /var/lib/dbus/machine-id

    if ! id -u user >/dev/null 2>&1; then
      useradd -m -s /bin/zsh user
      echo "user ALL=(ALL) NOPASSWD: ALL" >> /etc/sudoers

      su - user -c "mkdir -p ~/.config ~/.local/share/applications ~/Downloads"
      
      if [ -d "${./desktop}/etc/xdg" ]; then
        cp -r ${./desktop}/etc/xdg/* /home/user/.config/ 2>/dev/null || true
        chown -R user:user /home/user/.config
        chmod -R 755 /home/user/.config
      fi

      cat > /home/user/.config/mimeapps.list << EOF
[Default Applications]
application/pdf=firefox.desktop
text/html=firefox.desktop
x-scheme-handler/http=firefox.desktop
x-scheme-handler/https=firefox.desktop
EOF

      ANGR_ICON=$(find /nix/store -path "*/angrmanagement/resources/images/angr.png" 2>/dev/null | head -1)
      if [ -z "$ANGR_ICON" ]; then
        ANGR_ICON="application-x-executable"
      fi
      
      cat > /home/user/.local/share/applications/angr-management.desktop << EOF
[Desktop Entry]
Version=1.0
Type=Application
Name=angr Management
Comment=Binary analysis platform GUI
Exec=angr-management
Icon=$ANGR_ICON
Terminal=false
Categories=Development;Security;
StartupNotify=true
EOF
      
      cp /etc/zsh/newuser.zshrc.recommended /home/user/.zshrc 2>/dev/null || touch /home/user/.zshrc
      echo 'prompt off' >> /home/user/.zshrc
      echo 'bindkey "^H" backward-kill-word' >> /home/user/.zshrc
      echo 'bindkey "^[[1;5C" forward-word' >> /home/user/.zshrc
      echo 'bindkey "^[[1;5D" backward-word' >> /home/user/.zshrc
      echo 'bindkey "^[^?" backward-kill-word' >> /home/user/.zshrc
      echo 'source <(fzf --zsh 2>/dev/null || true)' >> /home/user/.zshrc
      echo 'alias ls="eza -l --icons"' >> /home/user/.zshrc
      echo 'alias grep="grep --color=auto"' >> /home/user/.zshrc
      echo 'alias open="xdg-open 2>/dev/null"' >> /home/user/.zshrc
      echo 'eval "$(zoxide init zsh)"' >> /home/user/.zshrc
      echo 'source ${pkgs.zsh-syntax-highlighting}/share/zsh-syntax-highlighting/zsh-syntax-highlighting.zsh' >> /home/user/.zshrc
      cat >> /home/user/.zshrc << 'ZSHEOF'
PROMPT=$'\n%F{green}%n@%m%f %F{blue}%(4~|%-1~/.../%2~|%3~)%f\n%F{red}$%f '
ZSHEOF
      
      chown -R user:user /home/user
      chmod 755 /home/user
      chmod -R 755 /home/user/.config
      chmod 644 /home/user/.zshrc
      
      su - user -c "PATH='/nix/var/nix/profiles/security-env/bin:$PATH' tldr --update" || true
    fi

    DUMPCAP=$(find /nix/var/nix/profiles/security-env -name dumpcap 2>/dev/null | head -1)
    if [ -n "$DUMPCAP" ]; then
      setcap cap_net_raw,cap_net_admin=ep "$DUMPCAP"
    fi

    export DISPLAY=:0
    export XDG_DATA_DIRS="${desktopService}/share:''${XDG_DATA_DIRS:-/usr/local/share:/usr/share}"
    export XDG_CONFIG_DIRS="${desktopService}/etc/xdg:''${XDG_CONFIG_DIRS:-/etc/xdg}"

    ${pkgs.tigervnc}/bin/Xvnc \
      $DISPLAY \
      -localhost 0 \
      -SecurityTypes None \
      -geometry 1920x1080 \
      -depth 24 &

    ${novnc}/bin/novnc \
      --vnc localhost:5900 \
      --listen 6080 &

    until [ -e /tmp/.X11-unix/X0 ]; do sleep 0.1; done
    until ${pkgs.curl}/bin/curl -fs localhost:6080 >/dev/null; do sleep 0.1; done

    su - user -c "
      export DISPLAY=$DISPLAY
      export PATH='/nix/var/nix/profiles/security-env/bin:$PATH'
      export XDG_DATA_DIRS='${desktopService}/share:$XDG_DATA_DIRS'
      export XDG_CONFIG_DIRS='${desktopService}/etc/xdg:$XDG_CONFIG_DIRS'
      export HOME=/home/user
      exec ${pkgs.dbus}/bin/dbus-launch --sh-syntax --exit-with-session --config-file=${pkgs.dbus}/share/dbus-1/session.conf ${pkgs.xfce.xfce4-session}/bin/xfce4-session
    "
  '';

  xfce = pkgs.symlinkJoin {
    name = "xfce";
    paths = with pkgs.xfce; [
      xfce4-session
      xfce4-settings
      xfce4-terminal
      xfce4-panel
      xfce4-appfinder
      xfwm4
      xfdesktop
      xfconf
      exo
      thunar
    ] ++ (with pkgs; [
      dbus
      dejavu_fonts
      nerd-fonts.fira-code
      nerd-fonts.hack
      blackbird
    ]);
  };

in pkgs.symlinkJoin {
  name = "desktop-service";
  paths = [ 
    desktopService
    (pkgs.writeScriptBin "desktop-service" serviceScript)
  ];
}
