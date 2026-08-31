#!/bin/bash
# ============================================================
#  USTANOVKA ARCH LINUX (BIOS/MBR + SWAP + Wi-Fi)
#  Versija: 4.1 (s transliteraciej)
#  Avtor: catDaVinchi
#  GitHub: https://github.com/catDaVinchi/installScripts
# ============================================================

set -e  # Ostanovka pri oshibke

# ==================== FUNKCII ====================

error_exit() {
    echo "❌ OSHIBKA: $1"
    echo "Skript ostanovlen."
    exit 1
}

confirm() {
    read -p "⚠️  $1 (y/N): " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        error_exit "Dejstvie otmeneno polzovatelem."
    fi
}

# ==================== NACALO USTANOVKI ====================

echo "============================================================"
echo "  USTANOVKA ARCH LINUX"
echo "  Versija skripta: 4.1"
echo "============================================================"

# === 1. Proverka interneta ===
echo "=== 1. Proverka interneta ==="
ping -c 3 archlinux.org || error_exit "Net interneta! Podkluchi Wi-Fi cherez iwctl"

# === 2. ZAPROS RAZMERA SWAP ===
echo "=== 2. Nastrojka SWAP ==="
echo "Rekomenduemye razmery SWAP:"
echo "  - 2 GB (dlja OZU ≤ 4 GB)"
echo "  - 4 GB (dlja OZU 4-8 GB)"
echo "  - 8 GB (dlja OZU 8-16 GB)"
echo "  - 16 GB (dlja hibernacii ili OZU > 16 GB)"
read -p "Vvedite razmer SWAP v GB (naprimer, 4): " SWAP_SIZE_GB

# Proverka, chto vvedeno chislo
if ! [[ "$SWAP_SIZE_GB" =~ ^[0-9]+$ ]] || [ "$SWAP_SIZE_GB" -lt 1 ]; then
    error_exit "Nekorrektnyj razmer SWAP. Vvedite polozhitel'noe chislo."
fi

SWAP_SIZE_MIB=$((SWAP_SIZE_GB * 1024))
echo "✅ SWAP ustanovlen: ${SWAP_SIZE_GB} GB (${SWAP_SIZE_MIB} MiB)"
confirm "Prodolzhit' ustanovku s SWAP = ${SWAP_SIZE_GB} GB?"

# === 3. Sinhronizacija vremeni ===
echo "=== 3. Sinhronizacija vremeni ==="
timedatectl set-ntp true

# === 4. OBNOVLENIE ZERKAL ===
echo "=== 4. Obnovlenie zerkal ==="
pacman -Sy --noconfirm reflector || error_exit "Ne udalos' ustanovit' reflector"
reflector --latest 20 --protocol https --sort rate --save /etc/pacman.d/mirrorlist || echo "⚠️  Reflector ne srabotal, no prodolzhaem..."

# === 5. RAZMETKA DISKA ===
echo "=== 5. Razmetka diska /dev/sda (MBR) ==="
confirm "Budut UDALENY VSE DANNYE na diske /dev/sda. Prodolzhit'?"

# Vychisljaem granicy razdelov
BOOT_END=513
SWAP_START=$BOOT_END
SWAP_END=$((SWAP_START + SWAP_SIZE_MIB))
ROOT_START=$SWAP_END

echo "Sozdajom razdely:"
echo "  - boot: 1-${BOOT_END} MiB (512 MB)"
echo "  - swap: ${SWAP_START}-${SWAP_END} MiB (${SWAP_SIZE_GB} GB)"
echo "  - root: ${ROOT_START}-100% MiB (ostal'noe)"

parted /dev/sda mklabel msdos || error_exit "Ne udalos' sozdat' MBR-tablicu"

parted /dev/sda mkpart primary ext4 1MiB ${BOOT_END}MiB || error_exit "Oshibka sozdanija boot-razdela"
parted /dev/sda mkpart primary linux-swap ${SWAP_START}MiB ${SWAP_END}MiB || error_exit "Oshibka sozdanija swap-razdela"
parted /dev/sda mkpart primary ext4 ${ROOT_START}MiB 100% || error_exit "Oshibka sozdanija root-razdela"

parted /dev/sda set 1 boot on || error_exit "Oshibka ustanovki flaga boot"

# === 6. FORMATIROVANIE ===
echo "=== 6. Formatirovanie razdelov ==="
mkfs.ext4 /dev/sda1 || error_exit "Oshibka formatirovanija boot"
mkswap /dev/sda2 || error_exit "Oshibka formatirovanija swap"
mkfs.ext4 /dev/sda3 || error_exit "Oshibka formatirovanija root"

# === 7. MONTIRovanie ===
echo "=== 7. Montirovanie razdelov ==="
mount /dev/sda3 /mnt || error_exit "Oshibka montirovanija root"
mkdir -p /mnt/boot
mount /dev/sda1 /mnt/boot || error_exit "Oshibka montirovanija boot"
swapon /dev/sda2 || error_exit "Oshibka vkljuchenija swap"

# === 8. USTANOVKA SISTEMY ===
echo "=== 8. Ustanovka bazovoj sistemy ==="
echo "Eto zajmet neskol'ko minut. Pozhalujsta, podozhdite..."
pacstrap -K /mnt base linux linux-firmware nano sudo iwd dhcpcd btop mc fastfetch || error_exit "Oshibka pacstrap"

# === 9. GENERACIJA FSTAB ===
echo "=== 9. Generacija fstab ==="
genfstab -U /mnt >> /mnt/etc/fstab || error_exit "Oshibka genfstab"

# ==================== NASTROJKA V CHROOT ====================

echo "=== 10. Nastrojka sistemy (chroot) ==="
arch-chroot /mnt /bin/bash <<EOF || error_exit "Oshibka v chroot"

# Chasovoj pojas (Moskva)
ln -sf /usr/share/zoneinfo/Europe/Moscow /etc/localtime
hwclock --systohc

# Lokal'
sed -i 's/^#\(en_US.UTF-8\)/\1/' /etc/locale.gen
sed -i 's/^#\(ru_RU.UTF-8\)/\1/' /etc/locale.gen
locale-gen
echo "LANG=ru_RU.UTF-8" > /etc/locale.conf

# Imja komp'jutera
echo "myarch" > /etc/hostname

# hosts
cat > /etc/hosts <<HOSTS
127.0.0.1   localhost
::1         localhost
127.0.1.1   myarch.localdomain   myarch
HOSTS

# ========== VVOD PAROLEJ (s proverkoj) ==========
echo ""
echo "============================================================"
echo "⚠️  VNIMANIE: Sejchas nuzhno zadat' paroli!"
echo "============================================================"
echo ""

echo "➡️  Ustanovite parol' dlja ROOT (superpol'zovatel'):"
passwd || { echo "Oshibka: parol' root ne zadan. Vyhod."; exit 1; }
echo "✅ Parol' root zadan."
echo ""

echo "➡️  Sozdanie pol'zovatelja vgm..."
useradd -m -G wheel -s /bin/bash vgm || { echo "Oshibka sozdanija pol'zovatelja vgm"; exit 1; }

echo "➡️  Ustanovite parol' dlja pol'zovatelja vgm:"
passwd vgm || { echo "Oshibka: parol' dlja vgm ne zadan. Vyhod."; exit 1; }
echo "✅ Parol' dlja vgm zadan."
echo ""

# Sudo
echo "%wheel ALL=(ALL:ALL) ALL" >> /etc/sudoers

# ========== ZAGRUZCIK ==========
echo "=== Ustanovka zagruzchika GRUB ==="
pacman -S --noconfirm grub || { echo "Oshibka ustanovki GRUB"; exit 1; }
grub-install --target=i386-pc /dev/sda || { echo "Oshibka ustanovki GRUB v MBR"; exit 1; }
grub-mkconfig -o /boot/grub/grub.cfg || { echo "Oshibka sozdanija konfiga GRUB"; exit 1; }

# ========== SLUZBY ==========
echo "=== Vkljuchenie sluzhb ==="
systemctl enable iwd || echo "⚠️  Ne udalos' vkljuchit' iwd"
systemctl enable dhcpcd || echo "⚠️  Ne udalos' vkljuchit' dhcpcd"

echo "✅ Nastrojka v chroot zavershena"
EOF

# ==================== ZAVERSHENIE ====================

echo "=== 11. Ochistka i zavershenie ==="
umount -R /mnt || error_exit "Oshibka razmontirovanija"
swapoff /dev/sda2 || echo "⚠️  Swap uzhe otkljuchon"

echo "============================================================"
echo "✅ USTANOVKA USPESHNO ZAVERSHENA!"
echo "============================================================"
echo "📌 VAZHNO:"
echo "   - Perezagruzites' komandoj: reboot"
echo "   - Ne zabud'te izvlech' zagruzochnuju fleshku"
echo "   - Vhod: vgm / vash_parol'"
echo "   - Root: root / vash_parol'"
echo "============================================================"
echo "🔧 Skript vypolnen. Udachnoj raboty s Arch Linux!"