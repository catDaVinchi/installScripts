#!/bin/bash
# ============================================================
#  USTANOVKA ARCH LINUX (BIOS/MBR + SWAP + Wi-Fi)
#  Versija: 5.0 (polnaja pererabotka)
#  Avtor: catDaVinchi
#  GitHub: https://github.com/catDaVinchi/installScripts
# ============================================================

set -e  # Ostanovka pri oshibke

# ==================== FUNKCII ====================

error_exit() {
    echo -e "\e[31m❌ OSHIBKA: $1\e[0m"
    echo "Skript ostanovlen."
    exit 1
}

confirm() {
    echo -e "\e[31m⚠️  $1 (y/N): \e[0m\c"
    read -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        error_exit "Dejstvie otmeneno polzovatelem."
    fi
}

prompt_user() {
    echo -e "\e[31m➡️  $1\e[0m"
}

# ==================== NACALO USTANOVKI ====================

echo "============================================================"
echo "  USTANOVKA ARCH LINUX"
echo "  Versija skripta: 5.0"
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
prompt_user "Vvedite razmer SWAP v GB (naprimer, 4): "
read SWAP_SIZE_GB

if ! [[ "$SWAP_SIZE_GB" =~ ^[0-9]+$ ]] || [ "$SWAP_SIZE_GB" -lt 1 ]; then
    error_exit "Nekorrektnyj razmer SWAP. Vvedite polozhitel'noe chislo."
fi

SWAP_SIZE_MIB=$((SWAP_SIZE_GB * 1024))
echo "✅ SWAP ustanovlen: ${SWAP_SIZE_GB} GB (${SWAP_SIZE_MIB} MiB)"
confirm "Prodolzhit' ustanovku s SWAP = ${SWAP_SIZE_GB} GB?"

# === 3. Sinhronizacija vremeni ===
echo "=== 3. Sinhronizacija vremeni ==="
timedatectl set-ntp true

# === 4. OBNOVLENIE ZERKAL (s vyborom) ===
echo "=== 4. Obnovlenie zerkal ==="
echo "Bystrye zerkala uskorjajut zagruzku paketov, no ih poisk mozhet zanjat' do 30 sekund."
confirm "Zapustit' poisk bystryh zerkal cherez reflector?"

if [[ $REPLY =~ ^[Yy]$ ]]; then
    pacman -Sy --noconfirm reflector || echo "⚠️  Reflector ne ustanovlen, propuskaju..."
    reflector --latest 10 --protocol https --sort rate --save /etc/pacman.d/mirrorlist && \
        echo "✅ Zerkala obnovleny" || echo "⚠️  Reflector ne srabotal, ispol'zujutsja standartnye zerkala"
else
    echo "ℹ️  Poisk zerkal propushchen. Ispol'zujutsja standartnye."
fi

# === 5. IZJMENENIE IMENI POL'ZOVATELJA ===
echo "=== 5. Sozdanie pol'zovatelja ==="
prompt_user "Vvedite imja pol'zovatelja (naprimer, vgm): "
read USER_NAME

# Proverka, chto imja ne pustoje
if [[ -z "$USER_NAME" ]]; then
    error_exit "Imja pol'zovatelja ne mozhet byt' pustym."
fi

echo "✅ Pol'zovatel' budet sozdan: $USER_NAME"
confirm "Prodolzhit' s imenem $USER_NAME?"

# === 6. RAZMETKA DISKA ===
echo "=== 6. Razmetka diska /dev/sda (MBR) ==="
confirm "Budut UDALENY VSE DANNYE na diske /dev/sda. Prodolzhit'?"

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

# === 7. FORMATIROVANIE ===
echo "=== 7. Formatirovanie razdelov ==="
mkfs.ext4 /dev/sda1 || error_exit "Oshibka formatirovanija boot"
mkswap /dev/sda2 || error_exit "Oshibka formatirovanija swap"
mkfs.ext4 /dev/sda3 || error_exit "Oshibka formatirovanija root"

# === 8. MONTIRovanie ===
echo "=== 8. Montirovanie razdelov ==="
mount /dev/sda3 /mnt || error_exit "Oshibka montirovanija root"
mkdir -p /mnt/boot
mount /dev/sda1 /mnt/boot || error_exit "Oshibka montirovanija boot"
swapon /dev/sda2 || error_exit "Oshibka vkljuchenija swap"

# === 9. USTANOVKA SISTEMY ===
echo "=== 9. Ustanovka bazovoj sistemy ==="
echo "Eto zajmet neskol'ko minut. Pozhalujsta, podozhdite..."
pacstrap -K /mnt base linux linux-firmware btop fastfetch nano sudo iwd dhcpcd openssh networkmanager || error_exit "Oshibka pacstrap"

# === 10. GENERACIJA FSTAB ===
echo "=== 10. Generacija fstab ==="
genfstab -U /mnt >> /mnt/etc/fstab || error_exit "Oshibka genfstab"

# ==================== NASTROJKA V CHROOT ====================

echo "=== 11. Nastrojka sistemy (chroot) ==="

# Kopiruem skript v chroot
cat > /mnt/setup.sh <<'INNERSCRIPT'
#!/bin/bash
# Vnutrennij skript dlja vypolnenija v chroot

# Chasovoj pojas
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

# ========== VVOD PAROLEJ ==========
echo ""
echo "============================================================"
echo -e "\e[31m⚠️  VNIMANIE: Sejchas nuzhno zadat' paroli!\e[0m"
echo "============================================================"
echo ""

echo -e "\e[31m➡️  Ustanovite parol' dlja ROOT:\e[0m"
passwd
echo -e "\e[32m✅ Parol' root zadan.\e[0m"
echo ""

echo -e "\e[31m➡️  Sozdanie pol'zovatelja $USER_NAME...\e[0m"
useradd -m -G wheel -s /bin/bash $USER_NAME

echo -e "\e[31m➡️  Ustanovite parol' dlja pol'zovatelja $USER_NAME:\e[0m"
passwd $USER_NAME
echo -e "\e[32m✅ Parol' dlja $USER_NAME zadan.\e[0m"
echo ""

# Sudo
echo "%wheel ALL=(ALL:ALL) ALL" >> /etc/sudoers

# ========== ZAGRUZCIK ==========
echo "=== Ustanovka zagruzchika GRUB ==="
pacman -S --noconfirm grub
grub-install --target=i386-pc /dev/sda
grub-mkconfig -o /boot/grub/grub.cfg

# ========== SLUZBY ==========
echo "=== Vkljuchenie sluzhb ==="
systemctl enable iwd
systemctl enable dhcpcd
systemctl enable sshd
systemctl enable NetworkManager

echo -e "\e[32m✅ Nastrojka v chroot zavershena\e[0m"
INNERSCRIPT

# Delaem vnutrennij skript ispolnjaemym
chmod +x /mnt/setup.sh

# ZApuskaem ego v chroot s interaktivnym vvodom
# Peredaem USER_NAME kak peremennuju okruzhenija
arch-chroot /mnt /bin/bash -c "USER_NAME='$USER_NAME' ./setup.sh" || error_exit "Oshibka vypolnenija nastrojki v chroot"

# Udaljaem vremennyj skript
rm -f /mnt/setup.sh

# ==================== ZAVERSHENIE I OCHISTKA ====================

echo "=== 12. Ochistka i zavershenie ==="

# 1. Razmontirovanie
umount -R /mnt || error_exit "Oshibka razmontirovanija"
swapoff /dev/sda2 || echo "⚠️  Swap uzhe otkljuchon"

# 2. OCHISTKA (udaljaem vremennye fily v Live)
echo "=== Ochistka vremennyh fajlov ==="
rm -rf /var/cache/pacman/pkg/* || echo "⚠️  Ne udalos' ochistit' keshi"
rm -f /root/installArch.sh || echo "⚠️  Skript ne najden v /root"
rm -f /root/.bash_history || echo "⚠️  Istorija ne najdena"

echo "✅ Vremennye fajly udaleny."

echo "============================================================"
echo -e "\e[32m✅ USTANOVKA USPESHNO ZAVERSHENA!\e[0m"
echo "============================================================"
echo "📌 VAZHNO:"
echo "   - Perezagruzites' komandoj: reboot"
echo "   - Ne zabud'te izvlech' zagruzochnuju fleshku"
echo "   - Vhod: $USER_NAME / vash_parol'"
echo "   - Root: root / vash_parol'"
echo "============================================================"
echo "🔧 Skript vypolnen. Udachnoj raboty s Arch Linux!"