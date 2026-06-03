#!/bin/sh

# Stop the script on any critical error
set -e

# ==========================================
# USER CONFIGURATION VARIABLES
# Change these values before running if needed
# ==========================================
# Keyboard layout for X11/Wayland (e.g., 'us', 'fr', 'ch')
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

# 2. Disclaimer & Acceptance (Dialog Menu)
dialog --clear \
    --backtitle "FreeBSD 15.1 Post-Installation" \
    --title "DISCLAIMER" \
    --yesno "This script will automatically configure FreeBSD 15.1 with NVIDIA drivers, KDE Plasma 6, Wayland, and essential software.\n\nIt is provided 'AS IS', without warranty of any kind. You are solely responsible for any data loss or system breakage.\n\nDo you accept these terms and wish to proceed?" \
    12 65
if [ $? -ne 0 ]; then
    clear
    log "Installation aborted by the user."
    exit 1
fi

# 3. Target User Selection (Dialog Input)
TARGET_USER=$(dialog --clear \
    --backtitle "FreeBSD 15.1 Post-Installation" \
    --title "User Configuration" \
    --inputbox "Enter the name of your primary user to add to the 'wheel', 'operator', and 'video' groups:\n(This is required for sudo, power management, and 3D acceleration)" \
    12 65 "administrateur" \
    3>&1 1>&2 2>&3)
if [ $? -ne 0 ]; then
    clear
    log "Installation aborted by the user."
    exit 1
fi

# 4. GPU Selection (Dialog Menu)
GPU_CHOICE=$(dialog --clear \
    --backtitle "FreeBSD 15.1 Post-Installation" \
    --title "Graphics Card Configuration" \
    --menu "Choose the NVIDIA graphics card architecture installed on this system:\n(Select with arrows, press Enter to confirm)" \
    15 65 2 \
    1 "Modern GPU (e.g., RTX 2060, 3000, 4000) - Latest Drivers" \
    2 "Legacy Pascal GPU (e.g., Quadro P1000) - 580 Branch" \
    3>&1 1>&2 2>&3)
if [ $? -ne 0 ]; then
    clear
    log "Installation aborted by the user."
    exit 1
fi
clear

# Assign NVIDIA packages based on user choice
case "$GPU_CHOICE" in
    1)
        log "Selected: Modern GPU. Using the latest NVIDIA branch."
        NVIDIA_PKGS="nvidia-driver nvidia-drm-kmod"
        ;;
    2)
        log "Selected: Legacy Pascal GPU. Using the 580 Legacy branch."
        NVIDIA_PKGS="nvidia-driver-580 nvidia-drm-kmod-580"
        ;;
    *)
        log "Invalid choice."
        exit 1
        ;;
esac

log "Updating pkg repository..."
pkg update -f

log "Installing system and GUI packages..."
# Base software + Wayland EGL + KDE Plasma 6 + Apps
PACKAGES="$NVIDIA_PKGS egl-wayland egl-wayland2 xorg sddm plasma6-plasma plasma6-wayland wayland konsole dolphin firefox vlc thunderbird libreoffice fr-libreoffice sudo"

# -y makes the installation idempotent
pkg install -y $PACKAGES

log "Configuring startup services (/etc/rc.conf)..."
sysrc dbus_enable="YES"
sysrc sddm_enable="YES"

log "Configuring kernel modules (NVIDIA & AMD Thermal)..."
CURRENT_KLD=$(sysrc -n kld_list 2>/dev/null || echo "")

# Order matters: modeset first, then drm
case "$CURRENT_KLD" in
    *nvidia-modeset*) ;;
    *) sysrc kld_list+=" nvidia-modeset" ;;
esac

case "$CURRENT_KLD" in
    *nvidia-drm*) ;;
    *) sysrc kld_list+=" nvidia-drm" ;;
esac

# AMD CPU thermal sensor
case "$CURRENT_KLD" in
    *amdtemp*) ;;
    *) sysrc kld_list+=" amdtemp" ;;
esac

log "Configuring Wayland DRM & Aquantia Network (/boot/loader.conf)..."
# Enable DRM modeset (Mandatory for Wayland with NVIDIA)
if ! grep -q '^hw.nvidiadrm.modeset=' /boot/loader.conf 2>/dev/null; then
    echo 'hw.nvidiadrm.modeset="1"' >> /boot/loader.conf
fi

# Prepare driver for Aquantia AQ107 network card
if ! grep -q '^if_aq_load=' /boot/loader.conf 2>/dev/null; then
    echo 'if_aq_load="YES"' >> /boot/loader.conf
fi

log "Configuring X11/SDDM Keyboard Layout ($KBD_LAYOUT-$KBD_VARIANT)..."
mkdir -p /usr/local/etc/X11/xorg.conf.d
cat << EOF > /usr/local/etc/X11/xorg.conf.d/00-keyboard.conf
Section "InputClass"
    Identifier "system-keyboard"
    MatchIsKeyboard "on"
    Option "XkbLayout" "$KBD_LAYOUT"
    Option "XkbVariant" "$KBD_VARIANT"
EndSection
EOF

log "Mounting procfs and linprocfs (Required by Wayland/KDE/LinuxKPI)..."
if ! grep -q "[[:space:]]/proc[[:space:]]" /etc/fstab; then
    echo "proc        /proc           procfs  rw  0   0" >> /etc/fstab
fi
if ! grep -q "[[:space:]]/compat/linux/proc[[:space:]]" /etc/fstab; then
    echo "linprocfs   /compat/linux/proc linprocfs rw 0 0" >> /etc/fstab
fi
mount -a || true

log "Securing and configuring user '$TARGET_USER'..."
if id "$TARGET_USER" >/dev/null 2>&1; then
    # Idempotent assignment to required groups
    pw groupmod wheel -m "$TARGET_USER"
    pw groupmod operator -m "$TARGET_USER"
    pw groupmod video -m "$TARGET_USER"
    log "  -> User '$TARGET_USER' successfully added to wheel, operator, and video groups."
    
    # Ensure the wheel group can use sudo
    if ! grep -q "^%wheel ALL=(ALL:ALL) ALL" /usr/local/etc/sudoers 2>/dev/null; then
        echo "%wheel ALL=(ALL:ALL) ALL" >> /usr/local/etc/sudoers
    fi
else
    log "  ! Warning: User '$TARGET_USER' does not exist on this system. Please create it manually."
fi

echo "-----------------------------------------------------------------"
log "Post-installation script completed successfully!"
echo "You can now safely reboot your machine."
echo "-----------------------------------------------------------------"
