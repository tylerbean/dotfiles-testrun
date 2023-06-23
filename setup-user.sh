#!/bin/bash

set -e
exec 2> >(while read line; do echo -e "\e[01;31m$line\e[0m"; done)

MY_PGP_KEY_ID="56C3E775E72B0C8B1C0C1BD0B5DB77409B11B601"

dotfiles_dir="$(
    cd "$(dirname "$0")"
    pwd
)"
cd "$dotfiles_dir"
git clone https://aur.archlinux.org/paru.git
cd paru
makepkg -si
cd ..

paru -Sy udiskie-dmenu-git iriunwebcam-bin arch-secure-boot \
mkinitcpio-encrypt-detached-header chromium-widevine wluma \
vimiv-qt webwormhole-git bfs overdue hyprland-autoname-workspaces-git \
gtk-theme-arc-gruvbox-git wlsunset wlrctl swaync ttf-courier-prime \
ttf-heuristica ttf-signika aurpublish aurutils repoctl terraform-ls \
teehee lscolors-git anydesk python-urwid_readline

# scli-git 

link() {
    orig_file="$dotfiles_dir/$1"
    if [ -n "$2" ]; then
        dest_file="$HOME/$2"
    else
        dest_file="$HOME/$1"
    fi

    mkdir -p "$(dirname "$orig_file")"
    mkdir -p "$(dirname "$dest_file")"

    rm -rf "$dest_file"
    ln -s "$orig_file" "$dest_file"
    echo "$dest_file -> $orig_file"
}

is_chroot() {
    ! cmp -s /proc/1/mountinfo /proc/self/mountinfo
}

systemctl_enable_start() {
    echo "systemctl --user enable --now "$1""
    systemctl --user enable --now "$1"
}

echo "==========================="
echo "Setting up user dotfiles..."
echo "==========================="

link ".gnupg/$(cut -d'-' -f1 /etc/hostname)-gpg.conf" ".gnupg/gpg.conf"
link ".gnupg/gpg-agent.conf"
link ".ignore"
link ".magic"
link ".p10k.zsh"
link ".p10k.zsh" ".p10k-ascii-8color.zsh"
link ".zprofile"
link ".zsh-aliases"
link ".zshenv"
link ".zshrc"

link ".mozilla/firefox/profile/user.js"
link ".mozilla/firefox/profile/chrome"

link ".config/bat"
link ".config/chromium-flags.conf"
link ".config/environment.d"
link ".config/flashfocus"
link ".config/git/$(cut -d'-' -f1 /etc/hostname)" ".config/git/config"
link ".config/git/common"
link ".config/git/home"
link ".config/git/ignore"
link ".config/git/work"
link ".config/gtk-3.0"
link ".config/htop"
link ".config/hypr"
link ".config/hyprland-autoname-workspaces"
link ".config/kak"
link ".config/kak-lsp"
link ".config/kitty"
link ".config/mimeapps.list"
link ".config/mpv"
link ".config/notmuch"
link ".config/pacman"
link ".config/pgcli/config"
link ".config/pylint"
link ".config/qalculate/qalc.cfg"
link ".config/qalculate/qalculate-gtk.cfg"
link ".config/qutebrowser"
link ".config/repoctl"
link ".config/sclirc"
link ".config/stylua"
link ".config/swappy"
link ".config/swaylock"
link ".config/swaync"
link ".config/systemd/user/backup-packages.service"
link ".config/systemd/user/backup-packages.timer"
link ".config/systemd/user/battery-low-notify.service"
link ".config/systemd/user/hyprland-session.target"
link ".config/systemd/user/polkit-gnome.service"
link ".config/systemd/user/systembus-notify.service"
link ".config/systemd/user/udiskie.service"
link ".config/systemd/user/waybar-updates.service"
link ".config/systemd/user/waybar-updates.timer"
link ".config/systemd/user/wl-clipboard-manager.service"
link ".config/systemd/user/wlsunset.service"
link ".config/tig"
link ".config/transmission/settings.json"
link ".config/udiskie"
link ".config/USBGuard"
link ".config/user-tmpfiles.d"
link ".config/vimiv"
link ".config/waybar"
link ".config/wldash"
link ".config/xdg-desktop-portal-wlr"
link ".config/xkb"
link ".config/xplr"
link ".config/zathura"

link ".local/bin"
link ".local/share/applications"

if is_chroot; then
    echo >&2 "=== Running in chroot, skipping user services..."
else
    echo ""
    echo "================================="
    echo "Enabling and starting services..."
    echo "================================="

    systemctl --user daemon-reload
    systemctl_enable_start "backup-packages.timer"
    systemctl_enable_start "battery-low-notify.service"
    systemctl_enable_start "hyprland-autoname-workspaces.service"
    systemctl_enable_start "swaync.service"
    systemctl_enable_start "polkit-gnome.service"
    systemctl_enable_start "systembus-notify.service"
    systemctl_enable_start "systemd-tmpfiles-setup.service"
    systemctl_enable_start "udiskie.service"
    systemctl_enable_start "waybar.service"
    systemctl_enable_start "waybar-updates.timer"
    systemctl_enable_start "wl-clipboard-manager.service"
    systemctl_enable_start "wlsunset.service"
    systemctl_enable_start "wluma.service"

fi

echo ""
echo "======================================="
echo "Finishing various user configuration..."
echo "======================================="

echo "Configuring MIME types"
file --compile --magic-file "$HOME/.magic"

if ! gpg -k | grep "$MY_PGP_KEY_ID" > /dev/null; then
    echo "Importing my public PGP key"
    curl -s https://maximbaz.com/pgp_keys.asc | gpg --import
    echo "5\ny\n" | gpg --command-fd 0 --no-tty --batch --edit-key "$MY_PGP_KEY_ID" trust
fi

find "$HOME/.gnupg" -type f -not -path "*#*" -exec chmod 600 {} \;
find "$HOME/.gnupg" -type d -exec chmod 700 {} \;

if [ -d "$HOME/.password-store" ]; then
    echo "Configuring automatic git push for pass"
    echo -e "#!/bin/sh\n\npass git push" > "$HOME/.password-store/.git/hooks/post-commit"
    chmod +x "$HOME/.password-store/.git/hooks/post-commit"
else
    echo >&2 "=== Password store is not configured yet, skipping..."
fi

if is_chroot; then
    echo >&2 "=== Running in chroot, skipping GTK file chooser dialog configuration..."
else
    echo "Configuring GTK file chooser dialog"
    gsettings set org.gtk.Settings.FileChooser sort-directories-first true
fi

echo "Configure repo-local git settings"
git config user.email "o0beaner@gmail.com"
git remote set-url origin "git@github.com:tylerbean/dotfiles-testrun.git"
