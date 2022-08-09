#!/bin/sh
# Noe's Auto Rice Boostrapping Script (NARBS)
# Stolen from and heavily inspired by Luke Smith <luke@lukesmith.xyz>

### OPTIONS AND VARIABLES ###

while getopts ":a:r:b:p:h" o; do case "${o}" in
    h) printf "Optional arguments for custom use:\\n  -r: Dotfiles repository (local file or url)\\n  -p: Dependencies and programs csv (local file or url)\\n  -a: AUR helper (must have pacman-like syntax)\\n  -h: Show this message\\n" && exit 1 ;;
    r) dotfilesrepo=${OPTARG} && git ls-remote "$dotfilesrepo" || exit 1 ;;
    b) repobranch=${OPTARG} ;;
    p) progsfile=${OPTARG} ;;
    a) aurhelper=${OPTARG} ;;
    *) printf "Invalid option: -%s\\n" "$OPTARG" && exit 1 ;;
    esac done

[ -z "$dotfilesrepo" ] && dotfilesrepo="https://github.com/thatguynoe/dots.git"
[ -z "$progsfile" ] && progsfile="https://raw.githubusercontent.com/thatguynoe/NARBS/main/progs.csv"
[ -z "$aurhelper" ] && aurhelper="yay"
[ -z "$repobranch" ] && repobranch="main"

### FUNCTIONS ###

installpkg() {
    pacman --noconfirm --needed -S "$1" >/dev/null 2>&1
}

error() {
    # Log to stderr and exit with failure.
    printf "%s\n" "$1" >&2
    exit 1
}

welcomemsg() {
    whiptail --title "Welcome!" \
        --msgbox "Welcome to Noe's Auto-Rice Bootstrapping Script!\\n\\nThis script will automatically install a fully-featured Linux desktop, which I use as my main machine.\\n\\n-Noe" 10 60

    whiptail --title "Important Note!" --yes-button "All ready!" \
        --no-button "Return..." \
        --yesno "Be sure the computer you are using has current pacman updates and refreshed Arch keyrings.\\n\\nIf it does not, the installation of some programs might fail." 8 70
}

getuserandpass() {
    # Prompts user for new username an password.
    name=$(whiptail --inputbox "First, please enter a name for the user account." 10 60 3>&1 1>&2 2>&3 3>&1) || exit 1
    while ! echo "$name" | grep -q "^[a-z_][a-z0-9_-]*$"; do
        name=$(whiptail --nocancel --inputbox "Username not valid. Give a username beginning with a letter, with only lowercase letters, - or _." 10 60 3>&1 1>&2 2>&3 3>&1)
    done
    pass1=$(whiptail --nocancel --passwordbox "Enter a password for that user." 10 60 3>&1 1>&2 2>&3 3>&1)
    pass2=$(whiptail --nocancel --passwordbox "Retype password." 10 60 3>&1 1>&2 2>&3 3>&1)
    while ! [ "$pass1" = "$pass2" ]; do
        unset pass2
        pass1=$(whiptail --nocancel --passwordbox "Passwords do not match.\\n\\nEnter password again." 10 60 3>&1 1>&2 2>&3 3>&1)
        pass2=$(whiptail --nocancel --passwordbox "Retype password." 10 60 3>&1 1>&2 2>&3 3>&1)
    done
}

usercheck() {
    ! { id -u "$name" >/dev/null 2>&1; } ||
        whiptail --title "WARNING" --yes-button "CONTINUE" \
            --no-button "No wait..." \
            --yesno "The user \`$name\` already exists on this system. NARBS can install for a user already existing, but it will OVERWRITE any conflicting settings/dotfiles on the user account.\\n\\nNARBS will NOT overwrite your user files, documents, videos, etc., so don't worry about that, but only click <CONTINUE> if you don't mind your settings being overwritten.\\n\\nNote also that NARBS will change $name's password to the one you just gave." 14 70
}

preinstallmsg() {
    whiptail --title "Let's get this party started!" --yes-button "Let's go!" \
        --no-button "No, nevermind!" \
        --yesno "The rest of the installation will now be totally automated, so you can sit back and relax.\\n\\nIt will take some time, but when done, you can relax even more with your complete system.\\n\\nNow just press <Let's go!> and the system will begin installation!" 13 60 || {
        clear
        exit 1
    }
}

adduserandpass() {
    # Adds user `$name` with password $pass1.
    whiptail --infobox "Adding user \"$name\"..." 7 50
    useradd -m -g wheel -s /bin/zsh "$name" >/dev/null 2>&1 ||
        usermod -a -G wheel "$name" && mkdir -p /home/"$name" && chown "$name":wheel /home/"$name"
    export repodir="/home/$name/.local/src"
    mkdir -p "$repodir"
    chown -R "$name":wheel "$(dirname "$repodir")"
    echo "$name:$pass1" | chpasswd
    unset pass1 pass2
}

refreshkeys() {
    case "$(readlink -f /sbin/init)" in
    *systemd*)
        whiptail --infobox "Refreshing Arch Keyring..." 7 40
        pacman --noconfirm -S archlinux-keyring >/dev/null 2>&1
        ;;
    *)
        pacman --noconfirm --needed -S artix-keyring artix-archlinux-support >/dev/null 2>&1
        whiptail --infobox "Enabling Arch Repositories..." 7 40
        for repo in extra community; do
            grep -q "^\[$repo\]" /etc/pacman.conf ||
                echo "[$repo]
Include = /etc/pacman.d/mirrorlist-arch" >>/etc/pacman.conf
        done
        pacman -Sy >/dev/null 2>&1
        pacman-key --populate archlinux
        ;;
    esac
}

newperms() { # Set special sudoers settings for install (or after).
    sed -i "/#NARBS/d" /etc/sudoers
    echo "$* #NARBS" >>/etc/sudoers
}

manualinstall() {
    # Installs $1 manually. Used only for AUR helper here.
    # Should be run after repodir is created and var is set.
    whiptail --infobox "Installing \"$1\", an AUR helper..." 7 50
    sudo -u "$name" mkdir -p "$repodir/$1"
    sudo -u "$name" git clone --depth 1 "https://aur.archlinux.org/$1.git" "$repodir/$1" >/dev/null 2>&1 ||
        {
            cd "$repodir/$1" || return 1
            sudo -u "$name" git pull --force origin master
        }
    cd "$repodir/$1"
    sudo -u "$name" -D "$repodir/$1" makepkg --noconfirm -si >/dev/null 2>&1 || return 1
}

maininstall() {
    # Installs all needed programs from main repo.
    whiptail --title "NARBS Installation" --infobox "Installing \`$1\` ($n of $total). $1 $2" 9 70
    installpkg "$1"
}

gitmakeinstall() {
    progname="${1##*/}"
    progname="${progname%.git}"
    dir="$repodir/$progname"
    whiptail --title "NARBS Installation" \
        --infobox "Installing \`$progname\` ($n of $total) via \`git\` and \`make\`. $(basename "$1") $2" 8 70
    sudo -u "$name" git -C "$repodir" clone --depth 1 --single-branch \
        --no-tags -q "$1" "$dir" ||
        {
            cd "$dir" || return 1
            sudo -u "$name" git pull --force origin main
        }
    cd "$dir" || exit 1
    make >/dev/null 2>&1
    make install >/dev/null 2>&1
    cd /tmp || return 1
}

aurinstall() {
    whiptail --title "NARBS Installation" \
        --infobox "Installing \`$1\` ($n of $total) from the AUR. $1 $2" 9 70
    echo "$aurinstalled" | grep -q "^$1$" && return 1
    sudo -u "$name" $aurhelper -S --noconfirm "$1" >/dev/null 2>&1
}

pipinstall() {
    whiptail --title "NARBS Installation" \
        --infobox "Installing the Python package \`$1\` ($n of $total). $1 $2" 9 70
    [ -x "$(command -v "pip")" ] || installpkg python-pip >/dev/null 2>&1
    yes | pip install "$1"
}

installationloop() {
    ([ -f "$progsfile" ] && cp "$progsfile" /tmp/progs.csv) || curl -Ls "$progsfile" | sed '/^#/d' >/tmp/progs.csv
    total=$(wc -l </tmp/progs.csv)
    aurinstalled=$(pacman -Qqm)
    while IFS=, read -r tag program comment; do
        n=$((n + 1))
        echo "$comment" | grep -q "^\".*\"$" && comment="$(echo "$comment" | sed "s/\(^\"\|\"$\)//g")"
        case "$tag" in
        "A") aurinstall "$program" "$comment" ;;
        "G") gitmakeinstall "$program" "$comment" ;;
        "P") pipinstall "$program" "$comment" ;;
        *) maininstall "$program" "$comment" ;;
        esac
    done </tmp/progs.csv
}

putgitrepo() {
    # Downloads a gitrepo $1 and places the files in $2 only overwriting conflicts
    whiptail --infobox "Downloading and installing config files..." 7 60
    [ -z "$3" ] && branch="main" || branch="$repobranch"
    dir=$(mktemp -d)
    [ ! -d "$2" ] && mkdir -p "$2"
    chown -R "$name":wheel "$dir" "$2"
    sudo -u "$name" git clone --recursive -b "$branch" --depth 1 "$1" "$dir" >/dev/null 2>&1
    sudo -u "$name" cp -rfT "$dir" "$2"
}

systembeepoff() {
    dialog --infobox "Getting rid of that retarded error beep sound..." 10 50
    rmmod pcspkr
    echo "blacklist pcspkr" >/etc/modprobe.d/nobeep.conf
}

finalize() {
    whiptail --title "All done!" \
        --msgbox "Congrats! Provided there were no hidden errors, the script completed successfully and all the programs and configuration files should be in place.\\n\\nTo run the new graphical environment, log out and log back in as your new user, then run the command \"startx\" to start the graphical environment (it will start automatically in tty1).\\n\\n.t Noe" 13 80
}

### THE ACTUAL SCRIPT ###

### This is how everything happens in an intuitive format and order.

# Check if user is root on Arch distro. Install whiptail.
pacman --noconfirm --needed -Sy libnewt ||
    error "Are you sure you're running this as the root user, are on an Arch-based distribution and have an internet connection?"

# Welcome user and pick dotfiles.
welcomemsg || error "User exited."

# Get and verify username and password.
getuserandpass || error "User exited."

# Give warning if user already exists.
usercheck || error "User exited."

# Last chance for user to back out before install.
preinstallmsg || error "User exited."

### The rest of the script requires no user input.

# Refresh Arch keyrings.
refreshkeys ||
    error "Error automatically refreshing Arch keyring. Consider doing so manually."

for x in curl base-devel git ntp zsh; do
    whiptail --title "NARBS Installation" \
        --infobox "Installing \`$x\` which is required to install and configure other programs." 8 70
    installpkg "$x"
done

whiptail --title "NARBS Installation" \
    --infobox "Synchronizing system time to ensure successful and secure installation of software..." 8 70
ntpdate 0.us.pool.ntp.org >/dev/null 2>&1

adduserandpass || error "Error adding username and/or password."

[ -f /etc/sudoers.pacnew ] && cp /etc/sudoers.pacnew /etc/sudoers # Just in case

# Allow the user to run sudo without password. Since AUR programs must be
# installed in a fakeroot environment, this is required for all builds with AUR.
newperms "%wheel ALL=(ALL) NOPASSWD: ALL"

# Make pacman colorful, add eye candy on the progress bar, and enable concurrent downloads.
sed -i "s/^#ParallelDownloads.*$/ParallelDownloads = 5/;s/^#Color$/Color/" /etc/pacman.conf
grep -q "ILoveCandy" /etc/pacman.conf || sed -i "/#VerbosePkgLists/a ILoveCandy" /etc/pacman.conf

# Disable login lockout.
grep -q "^deny = 0" /etc/security/faillock.conf || sed -i "s/^# deny = 3$/deny = 0/" /etc/security/faillock.conf

# Use all cores for compilation.
sed -i "s/-j2/-j$(nproc)/;s/^#MAKEFLAGS/MAKEFLAGS/" /etc/makepkg.conf

manualinstall $aurhelper || error "Failed to install AUR helper."

# The command that does all the installing. Reads the progs.csv file and
# installs each needed program the way required. Be sure to run this only after
# the user has been created and has priviledges to run sudo without a password
# and all build dependencies are installed.
installationloop

whiptail --title "NARBS Installation" \
    --infobox "Finally, installing the newest version of \`libxft\` to enable color emoji in suckless software without crashes." 8 70
pacman -Qs libxft-git ||
    yes | sudo -u "$name" $aurhelper -S libxft-git >/dev/null 2>&1

# Install the dotfiles in the user's home directory
putgitrepo "$dotfilesrepo" "/home/$name" "$repobranch"
rm -f "/home/$name/README.md"
# make git ignore deleted README.md file
git update-index --assume-unchanged "/home/$name/README.md"

# Most important command! Get rid of the beep!
systembeepoff

# Make zsh the default shell for the user.
chsh -s /bin/zsh "$name" >/dev/null 2>&1
sudo -u "$name" mkdir -p "/home/$name/.cache/zsh/"

# Create basic directories.
sudo -u "$name" mkdir "/home/$name/Documents" "/home/$name/Downloads" "/home/$name/Pictures"

# Start services on boot.
for service in cupsd cronie bluetoothd backlight; do
    ln -s /etc/runit/sv/"$service" /run/runit/service
done

# Link /bin/sh to dash.
ln -sfT dash /usr/bin/sh

# Relink /bin/sh to dash after Bash updates.
[ ! -f /usr/share/libalpm/hooks/dash.hook ] && printf '[Trigger]
Type = Package
Operation = Install
Operation = Upgrade
Target = bash

[Action]
Description = Re-pointing /bin/sh symlink to dash...
When = PostTransaction
Exec = /usr/bin/ln -sfT dash /usr/bin/sh
Depends = dash' >/usr/share/libalpm/hooks/dash.hook

# dbus UUID must be generated for Artix runit.
dbus-uuidgen >/var/lib/dbus/machine-id

# Automatic timezone detection through a WIFI connection.
[ ! -f /etc/NetworkManager/dispatcher.d/09-timezone ] && printf '#!/bin/sh

case "$2" in
    up)
        ln -sf /usr/share/zoneinfo/"$(curl -s --fail https://ipapi.co/timezone)" /etc/localtime
    ;;
esac' >/etc/NetworkManager/dispatcher.d/09-timezone && chmod +x /etc/NetworkManager/dispatcher.d/09-timezone

# Tap to click (and more)
[ ! -f /etc/X11/xorg.conf.d/30-synaptics.conf ] && printf 'Section "InputClass"
    Identifier "libinput touchpad catchall"
    Driver "libinput"
    MatchIsTouchpad "on"
        # Enable left mouse button by tapping and other settings
        Option "Tapping" "on"
        Option "NaturalScrolling" "true"
        Option "TapButton1" "1"
        Option "TapButton2" "2"
        Option "TapButton3" "3"
        Option "FingerLow" "30"
        Option "FingerHigh" "50"
        Option "MaxTapTime" "125"
EndSection' >/etc/X11/xorg.conf.d/30-synaptics.conf

# This line, overwriting the `newperms` command above will allow the user to
# run serveral important commands, `shutdown`, `reboot`, updating, etc. without
# a password.
newperms "%wheel ALL=(ALL) ALL #NARBS
%wheel ALL=(ALL) NOPASSWD: /usr/bin/shutdown,/usr/bin/reboot,/usr/bin/systemctl suspend,/usr/bin/wifi-menu,/usr/bin/mount,/usr/bin/umount,/usr/bin/pacman -Syu,/usr/bin/pacman -Syyu,/usr/bin/packer -Syu,/usr/bin/packer -Syyu,/usr/bin/systemctl restart NetworkManager,/usr/bin/rc-service NetworkManager restart,/usr/bin/pacman -Syyu --noconfirm,/usr/bin/loadkeys,/usr/bin/yay,/usr/bin/pacman -Syyuw --noconfirm"

# Last message! Install complete!
finalize
clear
