#!/bin/bash
#
# Arch Linux installation
#
# Bootable USB:
# - [Download](https://archlinux.org/download/) ISO and GPG files
# - Verify the ISO file: `$ pacman-key -v archlinux-<version>-dual.iso.sig`
# - Create a bootable USB with: `# dd if=archlinux*.iso of=/dev/sdX && sync`
#
# UEFI setup:
#
# - Set boot mode to UEFI, disable Legacy mode entirely.
# - Temporarily disable Secure Boot.
# - Make sure a strong UEFI administrator password is set.
# - Delete preloaded OEM keys for Secure Boot, allow custom ones.
# - Set SATA operation to AHCI mode.
#
# Run installation:
#
# - Connect to wifi via: `# iwctl station wlan0 connect WIFI-NETWORK`
# - Run: `# bash <(curl -sL http://bit.ly/g14-installer)`

set -uo pipefail
trap 's=$?; echo "$0: Error on line "$LINENO": $BASH_COMMAND"; exit $s' ERR

exec 1> >(tee "stdout.log")
exec 2> >(tee "stderr.log" >&2)

export SNAP_PAC_SKIP=y

# Dialog
BACKTITLE="Arch Linux installation"

get_input() {
    title="$1"
    description="$2"

    input=$(dialog --clear --stdout --backtitle "$BACKTITLE" --title "$title" --inputbox "$description" 0 0)
    echo "$input"
}

get_password() {
    title="$1"
    description="$2"

    init_pass=$(dialog --clear --stdout --backtitle "$BACKTITLE" --title "$title" --passwordbox "$description" 0 0)
    : ${init_pass:?"password cannot be empty"}

    test_pass=$(dialog --clear --stdout --backtitle "$BACKTITLE" --title "$title" --passwordbox "$description again" 0 0)
    if [[ "$init_pass" != "$test_pass" ]]; then
        echo "Passwords did not match" >&2
        exit 1
    fi
    echo $init_pass
}

get_choice() {
    title="$1"
    description="$2"
    shift 2
    options=("$@")
    dialog --clear --stdout --backtitle "$BACKTITLE" --title "$title" --menu "$description" 0 0 0 "${options[@]}"
}

echo -e "\n### Getting mirrors"
reflector --save /etc/pacman.d/mirrorlist --country "United States" --protocol https --sort rate -l 5 > /dev/null
pacman -Syy > /dev/null

echo -e "\n### Checking UEFI boot mode"
if [ ! -f /sys/firmware/efi/fw_platform_size ]; then
    echo >&2 "You must boot in UEFI mode to continue"
    exit 2
fi

echo -e "\n### Setting up clock"
timedatectl set-ntp true
hwclock --systohc --utc

echo -e "\n### Installing additional tools"
pacman -Sy --noconfirm --needed git terminus-font dialog wget

echo -e "\n### HiDPI screens"
noyes=("Yes" "The font is too small" "No" "The font size is just fine")
hidpi=$(get_choice "Font size" "Is your screen HiDPI?" "${noyes[@]}") || exit 1
clear
[[ "$hidpi" == "Yes" ]] && font="ter-132n" || font="ter-716n"
setfont "$font"

hostname=$(get_input "Hostname" "Enter hostname") || exit 1
clear
: ${hostname:?"hostname cannot be empty"}

user=$(get_input "User" "Enter username") || exit 1
clear
: ${user:?"user cannot be empty"}

password=$(get_password "User" "Enter password") || exit 1
clear
: ${password:?"password cannot be empty"}

disksize=$(get_input "Disk Size" "Enter install size in GB") || exit 1
clear
: ${disksize:?"disk size cannot be empty"}

devicelist=$(lsblk -dplnx size -o name,size | grep -Ev "boot|rpmb|loop" | tac | tr '\n' ' ')
read -r -a devicelist <<< $devicelist

device=$(get_choice "Installation" "Select installation disk" "${devicelist[@]}") || exit 1
clear

luks_header_device=$(get_choice "Installation" "Select disk to write LUKS header to" "${devicelist[@]}") || exit 1

clear

echo -e "\n### Setting up partitions"
umount -R /mnt 2> /dev/null || true
cryptsetup luksClose luks 2> /dev/null || true

while true; do
    read -p "Wipe existing partitions? " yn
    case $yn in
        [Yy]* ) lsblk -plnx size -o name "${device}" | xargs -n1 wipefs --all; sgdisk --clear "${device}"; break;;
        [Nn]* ) break;;
        * ) echo "Please answer yes or no.";;
    esac
done

sgdisk -p "${device}"

meginblocks=2048
efi_start=2048
efi_end="$(((512*meginblocks)+2047))"
root_start=$((efi_end+1))
root_end=$((disksize*(meginblocks*1024)))

sgdisk --new 1:$root_start:$root_end "${device}" --new 2:$efi_start:$efi_end --typecode 2:ef00 "${device}"
sgdisk --change-name=1:primary --change-name=2:ESP "${device}"

part_root="$(ls ${device}* | grep -E "^${device}p?1$")"
part_boot="$(ls ${device}* | grep -E "^${device}p?2$")"

if [ "$device" != "$luks_header_device" ]; then
    cryptargs="--header $luks_header_device"
else
    cryptargs=""
    luks_header_device="$part_root"
fi

echo -e "\n### Formatting partitions"
mkfs.vfat -n "EFI" -F 32 "${part_boot}"
echo -n ${password} | cryptsetup luksFormat --type luks2 --pbkdf argon2id --label luks $cryptargs "${part_root}"
echo -n ${password} | cryptsetup luksOpen $cryptargs "${part_root}" luks
mkfs.btrfs -L btrfs /dev/mapper/luks

echo -e "\n### Setting up BTRFS subvolumes"
mount /dev/mapper/luks /mnt
btrfs subvolume create /mnt/root
btrfs subvolume create /mnt/home
btrfs subvolume create /mnt/pkgs
btrfs subvolume create /mnt/aurbuild
btrfs subvolume create /mnt/archbuild
btrfs subvolume create /mnt/docker
btrfs subvolume create /mnt/logs
btrfs subvolume create /mnt/temp
btrfs subvolume create /mnt/swap
btrfs subvolume create /mnt/snapshots
mkdir /mnt/boot
umount /mnt

mount -o noatime,nodiratime,compress=zstd,subvol=root /dev/mapper/luks /mnt
mkdir -p /mnt/{mnt/btrfs-root,boot,home,var/{cache/pacman,log,tmp,lib/{aurbuild,archbuild,docker}},swap,.snapshots}
mount "${part_boot}" /mnt/boot
mount -o noatime,nodiratime,compress=zstd,subvol=/ /dev/mapper/luks /mnt/mnt/btrfs-root
mount -o noatime,nodiratime,compress=zstd,subvol=home /dev/mapper/luks /mnt/home
mount -o noatime,nodiratime,compress=zstd,subvol=pkgs /dev/mapper/luks /mnt/var/cache/pacman
mount -o noatime,nodiratime,compress=zstd,subvol=aurbuild /dev/mapper/luks /mnt/var/lib/aurbuild
mount -o noatime,nodiratime,compress=zstd,subvol=archbuild /dev/mapper/luks /mnt/var/lib/archbuild
mount -o noatime,nodiratime,compress=zstd,subvol=docker /dev/mapper/luks /mnt/var/lib/docker
mount -o noatime,nodiratime,compress=zstd,subvol=logs /dev/mapper/luks /mnt/var/log
mount -o noatime,nodiratime,compress=zstd,subvol=temp /dev/mapper/luks /mnt/var/tmp
mount -o noatime,nodiratime,compress=zstd,subvol=swap /dev/mapper/luks /mnt/swap
mount -o noatime,nodiratime,compress=zstd,subvol=snapshots /dev/mapper/luks /mnt/.snapshots

# echo -e "\n### Configuring custom repo"
# mkdir "/mnt/var/cache/pacman/${user}-local"
# march="$(uname -m)"

# if [[ "${user}" == "m0x" ]]; then
#     wget -m -nH -np -q --show-progress --progress=bar:force --reject='index.html*' --cut-dirs=3 -P "/mnt/var/cache/pacman/${user}-local" "https://pkgbuild.com/~maximbaz/repo/${march}"
#     rename -- 'maximbaz.' "${user}-local." "/mnt/var/cache/pacman/${user}-local"/*
# else
#     repo-add "/mnt/var/cache/pacman/${user}-local/${user}-local.db.tar"
# fi

# if ! grep "${user}" /etc/pacman.conf > /dev/null; then
#     cat >> /etc/pacman.conf << EOF
# [${user}-local]
# Server = file:///mnt/var/cache/pacman/${user}-local

# [maximbaz]
# Server = https://pkgbuild.com/~maximbaz/repo/${march}

# [options]
# CacheDir = /mnt/var/cache/pacman/pkg
# CacheDir = /mnt/var/cache/pacman/${user}-local
# EOF
# fi

echo -e "\n### Installing packages"
pacstrap /mnt base base-devel dash linux-firmware kernel-modules-hook \
logrotate man-pages btrfs-progs htop jre-openjdk-headless pipewire-jack \
vi posix autoconf automake bison fakeroot flex gcc gettext groff gzip \
libtool make pacman pkgconf sudo texinfo which pacman-contrib vim pkgstats \
progress gocryptfs ntfs-3g sshfs udiskie xplr dua-cli croc bat exa fd \
ripgrep ripgrep-all tree trash-cli imagemagick jq dfrs zathura-pdf-mupdf \
pdftk inotify-tools lftp lbzip2 pigz pixz p7zip unrar unzip zip iwd nftables \
iptables-nft bandwhich net-tools nmap openbsd-netcat bind dog mtr sipcalc \
wget rsync openssh curlie speedtest-cli wireguard-tools systemd-resolvconf \
vnstat proxychains-ng socat arch-audit ccid usbguard gcr checksec snapper \
polkit-gnome mokutil earlyoom systembus-notify fwupd dmidecode upower \
acpi pipewire-pulse pipewire wireplumber pulseaudio-alsa pulseaudio-bluetooth \
pamixer pavucontrol playerctl bluez bluez-utils helvum hyprland swaybg \
swaylock swayidle xorg-server-xwayland wl-clipboard python-i3ipc waybar light \
slurp qt5-wayland qt6-wayland wtype wldash ttf-dejavu ttf-liberation noto-fonts \
cantarell-fonts ttf-droid ttf-lato ttf-opensans otf-font-awesome ttf-joypixels \
aurpublish rebuild-detector git git-delta meld tig github-cli kakoune kak-lsp \
prettier dos2unix editorconfig-core-c docker docker-compose direnv terraform \
lurk fzf visidata bash-language-server checkbashisms shfmt bash-completion \
python-lsp-server python-black python-pip python-pylint yapf bpython go go-tools \
gopls revive staticcheck npm yarn typescript-language-server rust rust-analyzer \
postgresql-libs pgformatter pgcli dbmate mariadb-clients aspell-en android-tools \
android-udev kitty zsh pass pwgen msitools gnome-keyring libgnome-keyring urlscan \
w3m qutebrowser python-adblock python-tldextract chromium man-db mkinitcpio \
firefox vivaldi vivaldi-ffmpeg-codecs grim swappy wf-recorder xdg-desktop-portal-wlr \
mpv mpv-mpris ffmpeg yt-dlp kubectl kubectx hugo krita qalculate-gtk libreoffice-fresh \
urlwatch mkcert shellcheck linux linux-headers devtools reflector amd-ucode \
terminus-font libvirt virt-manager qemu-base dnsmasq ebtables edk2-ovmf vulkan-headers

echo -e "\n### Generating base config files"
ln -sfT dash /mnt/usr/bin/sh

cryptsetup luksHeaderBackup "${luks_header_device}" --header-backup-file /tmp/header.img
luks_header_size="$(stat -c '%s' /tmp/header.img)"
rm -f /tmp/header.img

echo "cryptdevice=PARTLABEL=primary:luks:allow-discards cryptheader=LABEL=luks:0:$luks_header_size root=LABEL=btrfs rw rootflags=subvol=root quiet mem_sleep_default=deep" > /mnt/etc/kernel/cmdline

echo "FONT=$font" > /mnt/etc/vconsole.conf
genfstab -L /mnt >> /mnt/etc/fstab
echo "${hostname}" > /mnt/etc/hostname
echo "en_US.UTF-8 UTF-8" >> /mnt/etc/locale.gen
ln -sf /usr/share/zoneinfo/America/Chicago /mnt/etc/localtime
arch-chroot /mnt locale-gen
cat << EOF > /mnt/etc/mkinitcpio.conf
MODULES=(amdgpu)
BINARIES=()
FILES=()
HOOKS=(base consolefont udev autodetect modconf block encrypt filesystems keyboard)
EOF
arch-chroot /mnt bootctl --path=/boot install
arch-chroot /mnt bash -c "echo -e 'default arch.conf\ntimeout 3\neditor 0' > /boot/loader/loader.conf"
arch-chroot /mnt bash -c "echo -e 'title    Arch Linux\nlinux     /vmlinuz-linux\ninitrd    /amd-ucode.img\ninitrd    /initramfs-linux.img\noptions	cryptdevice=UUID=$(blkid -t LABEL=luks -s UUID -o value):luks root=/dev/mapper/luks rootflags=subvol=/root rw' > /boot/loader/entries/arch.conf"
arch-chroot /mnt bash -c "echo -e 'title    Arch Linux G14 Kernel\nlinux     /vmlinuz-linux-g14\ninitrd    /amd-ucode.img\ninitrd    /initramfs-linux-g14.img\noptions	cryptdevice=UUID=$(blkid -t LABEL=luks -s UUID -o value):luks root=/dev/mapper/luks rootflags=subvol=/root rw' > /boot/loader/entries/arch-g14.conf"
arch-chroot /mnt mkinitcpio -P
arch-chroot /mnt pacman -Sy --noconfirm acpid
arch-chroot /mnt systemctl enable acpid

# g14 specific
arch-chroot /mnt pacman -Syy --noconfirm nvidia-dkms nvidia-settings nvidia-prime acpi_call linux-headers
arch-chroot /mnt bash -c "echo -e '\r[g14]\nSigLevel = DatabaseNever Optional TrustAll\nServer = https://naru.jhyub.dev/\$repo\n' >> /etc/pacman.conf"
arch-chroot /mnt pacman -Syy --noconfirm asusctl supergfxctl linux-g14 linux-g14-headers 
arch-chroot /mnt systemctl enable supergfxd
arch-chroot /mnt sed -i "s/arch/arch-g14/g" /boot/loader/loader.conf

echo -e "\n### Configuring swap file"
btrfs filesystem mkswapfile --size 16G /mnt/swap/swapfile
echo "/swap/swapfile none swap defaults 0 0" >> /mnt/etc/fstab

echo -e "\n### Creating user"
arch-chroot /mnt useradd -m -s /usr/bin/zsh "$user"
for group in wheel network video input; do
    arch-chroot /mnt groupadd -rf "$group"
    arch-chroot /mnt gpasswd -a "$user" "$group"
done
arch-chroot /mnt chsh -s /usr/bin/zsh
echo "$user:$password" | arch-chroot /mnt chpasswd
arch-chroot /mnt passwd -dl root

echo -e "\n### Setting permissions on the custom repo"
# arch-chroot /mnt chown -R "$user:$user" "/var/cache/pacman/${user}-local/"

if [ "${user}" = "m0x" ]; then
    echo -e "\n### Cloning dotfiles"
    arch-chroot /mnt sudo -u $user bash -c 'git clone --recursive https://github.com/tylerbean/dotfiles-testrun.git ~/.dotfiles'

    echo -e "\n### Running initial setup"
    arch-chroot /mnt /home/$user/.dotfiles/setup-system.sh
    arch-chroot /mnt sudo -u $user /home/$user/.dotfiles/setup-user.sh
    arch-chroot /mnt sudo -u $user zsh -ic true

    echo -e "\n### DONE - reboot and re-run both ~/.dotfiles/setup-*.sh scripts"
else
    echo -e "\n### DONE - read POST_INSTALL.md for tips on configuring your setup"
fi

echo -e "\n### Reboot now, and after power off remember to unplug the installation USB"
umount -R /mnt


#### aur 
# linux-g14 linux-g14-headers udiskie-dmenu-git mkinitcpio-encrypt-detached-header chromium-widevine scli-git wluma vimiv-qt webwormhole-git bfs overdue hyprland-autoname-workspaces-git gtk-theme-arc-gruvbox-git wlsunset wlrctl swaync ttf-courier-prime ttf-heuristica ttf-signika # aurpublish aurutils repoctl terraform-ls teehee lscolors-git anydesk python-urwid_readline arch-secure-boot iriunwebcam-bin 

#arch-chroot /mnt arch-secure-boot initial-setup