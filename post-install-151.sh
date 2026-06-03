
#!/bin/sh

# Arrête le script en cas d'erreur
set -e

log() {
    printf "\033[0;32m==>\033[0m %s\n" "$1"
}

if [ "$(id -u)" -ne 0 ]; then
    printf "Erreur : Ce script doit être exécuté en tant que root.\n" >&2
    exit 1
fi

log "Mise à jour du catalogue de paquets (pkg)..."
pkg update -f

# ---------------------------------------------------------
# MENU DIALOG POUR LA CARTE GRAPHIQUE
# ---------------------------------------------------------
# On utilise la redirection des descripteurs de fichiers (3>&1 1>&2 2>&3)
# pour capturer le choix de 'dialog' dans la variable GPU_CHOICE
GPU_CHOICE=$(dialog --clear \
    --backtitle "Post-Installation FreeBSD 15.1 - Lenovo P620" \
    --title "Configuration de la Carte Graphique" \
    --menu "Choisissez la carte NVIDIA installée sur ce système :\n(Sélectionnez avec les flèches, validez avec Entrée)" \
    15 65 2 \
    1 "RTX 2060 (Recommandé - Pilote Récent)" \
    2 "Quadro P1000 (Pilote Legacy 580)" \
    3>&1 1>&2 2>&3)

# Vérifie si l'utilisateur a appuyé sur Annuler (Echap ou Cancel)
if [ $? -ne 0 ]; then
    clear
    log "Installation annulée par l'utilisateur."
    exit 1
fi
clear

# Attribution des paquets NVIDIA en fonction du choix
case "$GPU_CHOICE" in
    1)
        log "Sélection : RTX 2060. Utilisation des pilotes récents."
        NVIDIA_PKGS="nvidia-driver nvidia-drm-kmod"
        ;;
    2)
        log "Sélection : Quadro P1000. Utilisation de la branche Legacy 580."
        NVIDIA_PKGS="nvidia-driver-580 nvidia-drm-kmod-580"
        ;;
    *)
        log "Choix invalide."
        exit 1
        ;;
esac

log "Installation des paquets système et graphiques..."
# Base commune + paquets NVIDIA spécifiques
PACKAGES="$NVIDIA_PKGS egl-wayland egl-wayland2 xorg sddm plasma6-plasma plasma6-wayland wayland konsole dolphin firefox vlc thunderbird libreoffice fr-libreoffice sudo"

# -y rend la commande idempotente
pkg install -y $PACKAGES

log "Configuration des services de base au démarrage (/etc/rc.conf)..."
sysrc dbus_enable="YES"
sysrc sddm_enable="YES"

log "Configuration des modules noyau (NVIDIA & AMD)..."
CURRENT_KLD=$(sysrc -n kld_list 2>/dev/null || echo "")

# Les noms des modules compilés restent les mêmes peu importe la version du paquet
case "$CURRENT_KLD" in
    *nvidia-modeset*) ;;
    *) sysrc kld_list+=" nvidia-modeset" ;;
esac

case "$CURRENT_KLD" in
    *nvidia-drm*) ;;
    *) sysrc kld_list+=" nvidia-drm" ;;
esac

# Senseur thermique pour votre CPU AMD Threadripper
case "$CURRENT_KLD" in
    *amdtemp*) ;;
    *) sysrc kld_list+=" amdtemp" ;;
esac

log "Configuration de loader.conf pour Wayland et la carte Aquantia..."
# Active le modeset DRM (obligatoire pour Wayland avec NVIDIA)
if ! grep -q '^hw.nvidiadrm.modeset=' /boot/loader.conf 2>/dev/null; then
    echo 'hw.nvidiadrm.modeset="1"' >> /boot/loader.conf
fi

# Préparation du pilote aq(4) pour la carte réseau Aquantia AQ107
if ! grep -q '^if_aq_load=' /boot/loader.conf 2>/dev/null; then
    echo 'if_aq_load="YES"' >> /boot/loader.conf
fi

log "Configuration du clavier X11/SDDM (Suisse Romand)..."
mkdir -p /usr/local/etc/X11/xorg.conf.d
cat << 'EOF' > /usr/local/etc/X11/xorg.conf.d/00-keyboard.conf
Section "InputClass"
    Identifier "system-keyboard"
    MatchIsKeyboard "on"
    Option "XkbLayout" "ch"
    Option "XkbVariant" "fr"
EndSection
EOF

log "Montage de procfs et linprocfs (Requis par Wayland/KDE/LinuxKPI)..."
if ! grep -q "[[:space:]]/proc[[:space:]]" /etc/fstab; then
    echo "proc        /proc           procfs  rw  0   0" >> /etc/fstab
fi
if ! grep -q "[[:space:]]/compat/linux/proc[[:space:]]" /etc/fstab; then
    echo "linprocfs   /compat/linux/proc linprocfs rw 0 0" >> /etc/fstab
fi
mount -a || true

log "Sécurisation de l'utilisateur 'administrateur'..."
# Si l'utilisateur n'existe pas, on le prévient sans bloquer le script
if id "administrateur" >/dev/null 2>&1; then
    # Assignation idempotente aux groupes requis
    pw groupmod wheel -m administrateur
    pw groupmod operator -m administrateur
    pw groupmod video -m administrateur
    log "  -> Utilisateur 'administrateur' bien assigné aux groupes wheel, operator et video."
    
    # S'assure que wheel peut utiliser sudo
    if ! grep -q "^%wheel ALL=(ALL:ALL) ALL" /usr/local/etc/sudoers 2>/dev/null; then
        echo "%wheel ALL=(ALL:ALL) ALL" >> /usr/local/etc/sudoers
    fi
else
    log "  ! Attention : L'utilisateur 'administrateur' n'existe pas encore sur ce système."
fi

echo "-----------------------------------------------------------------"
log "Script de post-installation terminé avec succès !"
echo "Vous pouvez maintenant redémarrer la machine."
echo "-----------------------------------------------------------------"
