#!/bin/sh

# Stop the script on any critical error
set -e

# ==========================================
# USER CONFIGURATION VARIABLES
# ==========================================
# Keyboard layout for XLibre (e.g., 'us', 'fr', 'ch')
KBD_LAYOUT="ch"
# Keyboard variant (e.g., '', 'fr', 'mac')
KBD_VARIANT="fr"
# ==========================================

log() {
    printf "\033[0;32m==>\033[0m %s\n" "$1"
}

# 1. Check Root Privileges
if [ "$(id -u)" -ne 0 ]; then
    printf "Error: This script must be run as root.\n" >&2
    exit 1
fi

# 2. Disclaimer & Acceptance
bsddialog --clear \
    --backtitle "FreeBSD 15.1 Post-Installation (XLibre Edition)" \
    --title "DISCLAIMER" \
    --yesno "This script will configure FreeBSD 15.1 using the new XLibre display server, XLibre-specific NVIDIA drivers, and KDE Plasma 6.\n\nDo you accept these terms and wish to proceed?" \
    10 65
if [ $? -ne 0 ]; then
    clear
    log "Installation aborted by the user."
    exit 1
fi

# 3. Target User Selection
TARGET_USER=$(bsddialog --clear \
    --backtitle "FreeBSD 15.1 Post-Installation" \
    --title "User Configuration" \
    --inputbox "Enter the name of your primary user to add to the 'wheel', 'operator', and 'video' groups:" \
    10 65 "administrateur" \
    3>&1 1>&2 2>&3)
if [ $? -ne 0 ]; then
    clear
    log "Installation aborted by the user."
    exit 1
fi

# 4. NTP Time Server Selection
NTP_CHOICE=$(bsddialog --clear \
    --backtitle "FreeBSD 15.1 Post-Installation" \
    --title "NTP Configuration" \
    --menu "Select your time server pool:" \
    15 65 7 \
    1 "Switzerland (ch.pool.ntp.org)" \
    2 "Europe (europe.pool.ntp.org)" \
    3 "North America" \
    4 "South America" \
    5 "Asia" \
    6 "Africa" \
    7 "Oceania" \
    3>&1 1>&2 2>&3)
if [ $? -ne 0 ]; then
    clear
    log "Installation aborted by the user."
    exit 1
fi

case "$NTP_CHOICE" in
    1) NTP_SERVER="ch.pool.ntp.org" ;;
    2) NTP_SERVER="europe.pool.ntp.org" ;;
    3) NTP_SERVER="north-america.pool.ntp.org" ;;
    *) NTP_SERVER="pool.ntp.org" ;;
esac

# 5. GPU Selection (XLIBRE SPECIFIC)
GPU_CHOICE=$(bsddialog --clear \
    --backtitle "FreeBSD 15.1 Post-Installation" \
    --title "GPU Configuration" \
    --menu "Choose your NVIDIA architecture:" \
    12 65 2 \
    1 "Modern GPU (RTX 2060) - Latest Drivers" \
    2 "Legacy Pascal GPU (Quadro P1000) - 580 Branch" \
    3>&1 1>&2 2>&3)
if [ $? -ne 0 ]; then
    clear
    log "Installation aborted."
    exit 1
fi
clear

case "$GPU_CHOICE" in
    1) NVIDIA_PKGS="xlibre-nvidia-driver nvidia-drm-kmod" ;;
    2) NVIDIA_PKGS="xlibre-nvidia-driver-580 nvidia-drm-kmod-580" ;;
esac

log "Updating pkg repository..."
pkg update -f

# ---------------------------------------------------------
# IDEMPOTENCY: CLEANUP LEGACY CONFLICTING PACKAGES
# ---------------------------------------------------------
log "Checking for conflicting legacy Xorg/NVIDIA packages..."
CONFLICTING_PKGS="xorg xorg-server xorg-minimal nvidia-driver nvidia-driver-580"

for pkg in $CONFLICTING_PKGS; do
    if pkg info -e "$pkg" >/dev/null 2>&1; then
        log "  -> Removing conflicting package: $pkg"
        pkg delete -y "$pkg"
    fi
done

# Clean up any orphaned dependencies left by the old Xorg stack
log "Cleaning up orphaned dependencies..."
pkg autoremove -y

# ---------------------------------------------------------
# INSTALLATION
# ---------------------------------------------------------
log "Installing XLibre system and GUI packages..."
PACKAGES="$NVIDIA_PKGS xlibre sddm plasma6-plasma konsole dolphin firefox vlc thunderbird libreoffice fr-libreoffice sudo"
pkg install -y $PACKAGES

log "Configuring startup services (/etc/rc.conf)..."
sysrc dbus_enable="YES"
sysrc sddm_enable="YES"
sysrc ntpd_enable="YES"
sysrc ntpd_sync_on_start="YES"

log "Writing NTP configuration..."
if [ ! -f /etc/ntp.conf.bak ]; then
    cp /etc/ntp.conf /etc/ntp.conf.bak
fi
cat << EOF > /etc/ntp.conf
server $NTP_SERVER iburst
restrict default kod nomodify notrap nopeer noquery
restrict -6 default kod nomodify notrap nopeer noquery
restrict 127.0.0.1
restrict -6 ::1
EOF

log "Configuring kernel modules (NVIDIA & Audio)..."
CURRENT_KLD=$(sysrc -n kld_list 2>/dev/null || echo "")

case "$CURRENT_KLD" in
    *nvidia-modeset*) ;;
    *) sysrc kld_list+=" nvidia-modeset" ;;
esac

case "$CURRENT_KLD" in
    *amdtemp*) ;;
    *) sysrc kld_list+=" amdtemp" ;;
esac

case "$CURRENT_KLD" in
    *snd_hda*) ;;
    *) sysrc kld_list+=" snd_hda" ;;
esac

log "Configuring Network (/boot/loader.conf)..."
if ! grep -q '^if_aq_load=' /boot/loader.conf 2>/dev/null; then
    echo 'if_aq_load="YES"' >> /boot/loader.conf
fi

log "Configuring XLibre (Keyboard & Drivers)..."
mkdir -p /usr/local/etc/X11/xorg.conf.d

cat << EOF > /usr/local/etc/X11/xorg.conf.d/00-keyboard.conf
Section "InputClass"
    Identifier "system-keyboard"
    MatchIsKeyboard "on"
    Option "XkbLayout" "$KBD_LAYOUT"
    Option "XkbVariant" "$KBD_VARIANT"
EndSection
EOF

cat << EOF > /usr/local/etc/X11/xorg.conf.d/20-nvidia.conf
Section "Device"
    Identifier "NVIDIA Card"
    Driver "nvidia"
EndSection
EOF

log "Configuring SDDM (Theme)..."
mkdir -p /usr/local/etc/sddm.conf.d
cat << EOF > /usr/local/etc/sddm.conf.d/10-theme.conf
[Theme]
Current=maldives
EOF

log "Mounting linprocfs (Required by LinuxKPI)..."
mkdir -p /compat/linux/proc
if ! grep -q "[[:space:]]/proc[[:space:]]" /etc/fstab; then
    echo "proc        /proc           procfs  rw  0   0" >> /etc/fstab
fi
if ! grep -q "[[:space:]]/compat/linux/proc[[:space:]]" /etc/fstab; then
    echo "linprocfs   /compat/linux/proc linprocfs rw 0 0" >> /etc/fstab
fi
mount -a || true

log "Securing users..."
if id "sddm" >/dev/null 2>&1; then
    pw groupmod video -m sddm
    log "  -> System user 'sddm' added to 'video' group."
fi

if id "$TARGET_USER" >/dev/null 2>&1; then
    pw groupmod wheel -m "$TARGET_USER"
    pw groupmod operator -m "$TARGET_USER"
    pw groupmod video -m "$TARGET_USER"
    log "  -> User '$TARGET_USER' added to wheel, operator, and video groups."
    
    if ! grep -q "^%wheel ALL=(ALL:ALL) ALL" /usr/local/etc/sudoers 2>/dev/null; then
        echo "%wheel ALL=(ALL:ALL) ALL" >> /usr/local/etc/sudoers
    fi
else
    log "  ! Warning: User '$TARGET_USER' does not exist."
fi

echo "-----------------------------------------------------------------"
log "Installation completed with XLibre ecosystem!"
echo "Please reboot your machine."
echo "-----------------------------------------------------------------"
