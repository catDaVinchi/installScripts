#!/bin/bash
# ============================================================
#  УСТАНОВКА ARCH LINUX (BIOS/MBR + SWAP + Wi-Fi)
#  Версия: 3.3 (скачивается с GitHub)
# ============================================================

set -e

echo "=== 1. Проверка интернета ==="
ping -c 3 archlinux.org || { echo "Нет интернета! Подключи Wi-Fi через iwctl"; exit 1; }

echo "=== 2. Синхронизация времени ==="
timedatectl set-ntp true

echo "=== 3. Обновление зеркал ==="
pacman -Sy --noconfirm reflector
reflector --latest 20 --protocol https --sort rate --save /etc/pacman.d/mirrorlist

echo "=== 4. Разметка диска (MBR) ==="
parted /dev/sda mklabel msdos

parted /dev/sda mkpart primary ext4 1MiB 513MiB
parted /dev/sda mkpart primary linux-swap 513MiB 4617MiB
parted /dev/sda mkpart primary ext4 4617MiB 100%

parted /dev/sda set 1 boot on

echo "=== 5. Форматирование ==="
mkfs.ext4 /dev/sda1
mkswap /dev/sda2
mkfs.ext4 /dev/sda3

echo "=== 6. Монтирование ==="
mount /dev/sda3 /mnt
mkdir -p /mnt/boot
mount /dev/sda1 /mnt/boot
swapon /dev/sda2

echo "=== 7. Установка системы ==="
pacstrap -K /mnt base linux linux-firmware nano sudo iwd dhcpcd btop mc fastfetch

echo "=== 8. fstab ==="
genfstab -U /mnt >> /mnt/etc/fstab

arch-chroot /mnt /bin/bash <<EOF
ln -sf /usr/share/zoneinfo/Europe/Moscow /etc/localtime
hwclock --systohc

sed -i 's/^#\(en_US.UTF-8\)/\1/' /etc/locale.gen
sed -i 's/^#\(ru_RU.UTF-8\)/\1/' /etc/locale.gen
locale-gen
echo "LANG=ru_RU.UTF-8" > /etc/locale.conf

echo "myarchlinux" > /etc/hostname

cat > /etc/hosts <<HOSTS
127.0.0.1   localhost
::1         localhost
127.0.1.1   myarchlinux.localdomain   myarchlinux
HOSTS

echo "Установи пароль root:"
passwd

useradd -m -G wheel -s /bin/bash linuxuser
echo "Установи пароль для linuxuser:"
passwd linuxuser

echo "%wheel ALL=(ALL:ALL) ALL" >> /etc/sudoers

pacman -S --noconfirm grub
grub-install --target=i386-pc /dev/sda
grub-mkconfig -o /boot/grub/grub.cfg

systemctl enable iwd
systemctl enable dhcpcd
EOF

umount -R /mnt
swapoff /dev/sda2

echo "============================================================"
echo "✅ УСТАНОВКА ЗАВЕРШЕНА"
echo "============================================================"
echo "📌 Перезагрузитесь: reboot"
echo "📌 Вход: linuxuser / твой пароль"
echo "============================================================"