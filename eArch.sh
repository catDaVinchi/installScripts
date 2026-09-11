#!/usr/bin/env bash
# ============================================================================
#  easyarch.sh — установщик Arch Linux
#  Рефакторинг: исправлены критические баги, добавлен LUKS, Wayland для KDE,
#  trap, логирование. Единый скрипт.
#  Запуск: bash easyarch.sh (от root, на archiso)
# ============================================================================

set -euo pipefail

LOG_FILE="/tmp/easyarch.log"
UI_TITLE="eArch Установщик"
KEEP_MOUNTS=""

# ------------------------------ Логирование --------------------------------
log()  { printf '[%s] %s\n' "$(date +%T)" "$*" | tee -a "$LOG_FILE" >&2; }
info() { printf '\033[1;36m▶ %s\033[0m\n' "$*" | tee -a "$LOG_FILE"; }
ok()   { printf '\033[1;32m✓ %s\033[0m\n' "$*" | tee -a "$LOG_FILE"; }
warn() { printf '\033[1;33m⚠ %s\033[0m\n' "$*" | tee -a "$LOG_FILE"; }
err()  { printf '\033[1;31m✗ %s\033[0m\n' "$*" | tee -a "$LOG_FILE" >&2; }

# ------------------------------ Trap ---------------------------------------
on_error() { err "Ошибка (код $1) в строке $2. См. $LOG_FILE"; }
on_exit() {
    [[ -n "$KEEP_MOUNTS" ]] && return 0
    cleanup_mounts || true
}
trap 'on_error $? $LINENO' ERR
trap on_exit EXIT

# ------------------------------ Проверки -----------------------------------
require_root() {
    [[ $EUID -eq 0 ]] || { err "Скрипт должен запускаться от root."; exit 1; }
}

check_dependencies() {
    local deps=(whiptail parted lsblk blkid mkfs.ext4 mkfs.btrfs mkfs.fat mkfs.xfs \
                mkswap cryptsetup arch-chroot pacstrap genfstab grub-install efibootmgr)
    local missing=()
    for d in "${deps[@]}"; do
        command -v "$d" >/dev/null 2>&1 || missing+=("$d")
    done
    if ((${#missing[@]})); then
        warn "Отсутствуют: ${missing[*]}. Устанавливаю..."
        pacman -Sy --noconfirm --needed libnewt parted cryptsetup \
            btrfs-progs dosfstools xfsprogs arch-install-scripts grub efibootmgr \
            || { err "Не удалось установить зависимости"; exit 1; }
    fi
    if ! ping -c1 -W2 archlinux.org >/dev/null 2>&1; then
        warn "Нет доступа к archlinux.org — проверьте сеть."
    fi
}

setup_logging() { : > "$LOG_FILE"; }

configure_archiso_pacman() {
    local conf=/etc/pacman.conf
    [[ -f $conf ]] || return 0
    sed -i '/\[multilib\]/,/Include/ s/^#//' "$conf"
    grep -q '^ILoveCandy' "$conf" || sed -i '/^\[options\]/a ILoveCandy' "$conf"
    sed -i 's/^#Color/Color/' "$conf"
    sed -i 's/^#ParallelDownloads = 5/ParallelDownloads = 25/' "$conf"
}

cleanup_pacman_lock() {
    if [[ -f /var/lib/pacman/db.lck ]]; then
        if pgrep -x pacman >/dev/null; then
            warn "pacman работает — не удаляю db.lck"
        else
            rm -f /var/lib/pacman/db.lck
        fi
    fi
}

# ------------------------------ UI -----------------------------------------
ui_msg()      { whiptail --title "$UI_TITLE" --msgbox "$1" "${2:-10}" "${3:-60}"; }
ui_yesno()    { whiptail --title "$UI_TITLE" --yesno "$1" "${2:-15}" "${3:-60}" \
                --yes-button "Да" --no-button "Нет"; }
ui_input()    { whiptail --title "$UI_TITLE" --inputbox "$1" "${2:-10}" "${3:-60}" \
                "${4:-}" 3>&1 1>&2 2>&3; }
ui_password() { whiptail --title "$UI_TITLE" --passwordbox "$1" "${2:-10}" "${3:-60}" \
                3>&1 1>&2 2>&3; }
ui_menu() {
    local text=$1 height=$2 width=$3 listheight=$4; shift 4
    whiptail --title "$UI_TITLE" --menu "$text" "$height" "$width" "$listheight" \
             "$@" 3>&1 1>&2 2>&3
}
ui_pause() { read -rp "Нажмите Enter для продолжения..." _; }

# Универсальный выбор из массива "значение|описание"
ui_select_kv() {
    local prompt=$1 height=$2 width=$3 listheight=$4; shift 4
    local args=()
    for kv in "$@"; do args+=("${kv%%|*}" "${kv#*|}"); done
    ui_menu "$prompt" "$height" "$width" "$listheight" "${args[@]}"
}

ui_main_menu() {
    ui_menu "Выберите действие:" 16 70 5 \
        "1" "Авто установка с очисткой диска" \
        "2" "Авто установка рядом с другой OS" \
        "3" "Ручная установка" \
        "4" "Сортировать зеркала"
}

# ------------------------------ Диски --------------------------------------
list_disks() {
    local -a out=()
    while read -r name type; do
        [[ $type == disk ]] || continue
        case $name in loop*|sr*|ram*) continue ;; esac
        local size model dtype desc
        size=$(lsblk -dno SIZE "/dev/$name")
        model=$(lsblk -dno MODEL "/dev/$name" | xargs)
        if [[ -f /sys/block/$name/removable && $(<"/sys/block/$name/removable") == 1 ]]; then
            dtype="USB"
        elif [[ $name == vd* ]]; then dtype="VirtIO"
        elif [[ $name == sd* ]]; then dtype="SATA/SCSI"
        elif [[ $name == nvme* ]]; then dtype="NVMe"
        elif [[ $name == mmcblk* ]]; then dtype="MMC"
        else dtype="Disk"; fi
        desc="$size - $dtype${model:+ $model}"
        out+=("/dev/$name|$desc")
    done < <(lsblk -dno NAME,TYPE)
    ((${#out[@]})) && printf '%s\n' "${out[@]}"
}

list_partitions() {
    local disk=$1
    local base; base=$(basename "$disk")
    local pattern
    case $base in
        nvme*|mmcblk*) pattern="^${base}p[0-9]+$" ;;
        *)             pattern="^${base}[0-9]+$" ;;
    esac
    local -a out=()
    while read -r part; do
        [[ $part =~ $pattern ]] || continue
        local size fs
        size=$(lsblk -no SIZE "/dev/$part" | head -1)
        fs=$(lsblk -no FSTYPE "/dev/$part" | head -1)
        out+=("/dev/$part|$size${fs:+ ($fs)}")
    done < <(lsblk -lno NAME "$disk")
    ((${#out[@]})) && printf '%s\n' "${out[@]}"
}

list_all_partitions() {
    local -a out=()
    while read -r disk; do
        while IFS= read -r line; do out+=("$line"); done < <(list_partitions "$disk")
    done < <(lsblk -dno NAME,TYPE | awk '$2=="disk"{print "/dev/"$1}')
    ((${#out[@]})) && printf '%s\n' "${out[@]}"
}

get_disk_size_gb() {
    local bytes
    bytes=$(lsblk -bdno SIZE "$1" 2>/dev/null || echo 0)
    echo $((bytes / 1024 / 1024 / 1024))
}

get_efi_size_mib() {
    local gb=$1
    if   ((gb < 512));  then echo 300
    elif ((gb < 1024)); then echo 512
    else                     echo 1024
    fi
}

check_disk_type() {
    local disk=$1 base; base=$(basename "$disk")
    if [[ $base == vd* ]]; then echo virtio; return; fi
    if [[ -f /sys/block/$base/removable && $(<"/sys/block/$base/removable") == 1 ]]; then
        echo usb; return
    fi
    local rot=1
    [[ -f /sys/block/$base/queue/rotational ]] && rot=$(<"/sys/block/$base/queue/rotational")
    ((rot == 0)) && echo ssd || echo hdd
}

mount_options_for() {
    case $1 in
        ssd)    echo "rw,noatime,compress-force=zstd:3,ssd,space_cache=v2,discard=async" ;;
        virtio) echo "rw,noatime,compress-force=zstd:3,space_cache=v2,discard=async,ssd" ;;
        usb)    echo "rw,noatime,compress-force=zstd:3,ssd,space_cache=v2,discard=async" ;;
        hdd)    echo "rw,relatime,compress-force=zstd:3,space_cache=v2,autodefrag" ;;
        *)      echo "rw,noatime,compress-force=zstd:3,space_cache=v2" ;;
    esac
}

wipe_disk() {
    local disk=$1 base; base=$(basename "$disk")
    local pattern
    case $base in
        nvme*|mmcblk*) pattern="^${base}p[0-9]+$" ;;
        *)             pattern="^${base}[0-9]+$" ;;
    esac
    while read -r part; do
        [[ $part =~ $pattern ]] || continue
        wipefs -a "/dev/$part" 2>/dev/null || true
    done < <(lsblk -lno NAME "$disk")
    wipefs -a "$disk" 2>/dev/null || true
    sync; sleep 1
}

cleanup_mounts() {
    if swapon --show | grep -q '^/dev/'; then swapoff -a 2>/dev/null || true; fi
    while read -r name; do
        cryptsetup close "$name" 2>/dev/null || true
    done < <(dmsetup ls 2>/dev/null | awk '/^crypt/{print $1}')
    if mountpoint -q /mnt; then umount -R /mnt 2>/dev/null || true; fi
    for mp in /mnt/boot/efi /mnt/boot /mnt/home /mnt/var /mnt/.snapshots /mnt; do
        mountpoint -q "$mp" 2>/dev/null && umount -l "$mp" 2>/dev/null || true
    done
    [[ -d /mnt/os ]] && umount /mnt/os 2>/dev/null || true
    sync
}

create_partitions_auto() {
    local disk=$1 swap_gb=$2
    local -n _root=$3 _boot=$4 _swap=$5
    local disk_size efi_size
    disk_size=$(get_disk_size_gb "$disk")

    if [[ -d /sys/firmware/efi ]]; then
        efi_size=$(get_efi_size_mib "$disk_size")
        parted -s "$disk" mklabel gpt
        parted -s "$disk" mkpart primary fat32 1MiB "${efi_size}MiB"
        parted -s "$disk" set 1 esp on
        _boot="${disk}1"
        if ((swap_gb > 0)); then
            local swap_start=$((efi_size + 1)) swap_end=$((swap_start + swap_gb * 1024))
            parted -s "$disk" mkpart primary linux-swap "${swap_start}MiB" "${swap_end}MiB"
            parted -s "$disk" mkpart primary btrfs "${swap_end}MiB" 100%
            _swap="${disk}2"; _root="${disk}3"
        else
            parted -s "$disk" mkpart primary btrfs "${efi_size}MiB" 100%
            _swap=""; _root="${disk}2"
        fi
    else
        parted -s "$disk" mklabel msdos
        if ((swap_gb > 0)); then
            local swap_mb=$((swap_gb * 1024))
            parted -s "$disk" mkpart primary linux-swap 1MiB "${swap_mb}MiB"
            parted -s "$disk" mkpart primary btrfs "${swap_mb}MiB" 100%
            _swap="${disk}1"; _root="${disk}2"
        else
            parted -s "$disk" mkpart primary btrfs 1MiB 100%
            _swap=""; _root="${disk}1"
        fi
        parted -s "$disk" set 1 boot on
    fi
    partprobe "$disk" 2>/dev/null || blockdev --rereadpt "$disk" 2>/dev/null || true
    udevadm settle 2>/dev/null || sleep 2
}

# ------------------------------ ФС, LUKS -----------------------------------
format_partition() {
    local part=$1 fs=$2
    case $fs in
        ext4)  mkfs.ext4 -F "$part" ;;
        btrfs) mkfs.btrfs -f "$part" ;;
        xfs)   mkfs.xfs -f "$part" ;;
        f2fs)  mkfs.f2fs -f "$part" ;;
        ntfs)  mkfs.ntfs -f "$part" ;;
        fat32) mkfs.fat -F32 "$part" ;;
        swap)  mkswap "$part" ;;
        zfs)   return 1 ;;
        *)     return 1 ;;
    esac
}

luks_format() {
    printf '%s' "$3" | cryptsetup luksFormat --type "$2" --key-file=- "$1"
}
luks_open() {
    printf '%s' "$3" | cryptsetup open --key-file=- "$1" "$2"
}

setup_btrfs_subvolumes() {
    local root_dev=$1 mount_opts=$2
    mount "$root_dev" /mnt
    local sv
    for sv in @ @home @var @log @pkg @.snapshots; do
        btrfs subvolume create "/mnt/$sv" >/dev/null
    done
    umount /mnt

    mount -o "${mount_opts},subvol=@" "$root_dev" /mnt
    mkdir -p /mnt/{home,var,.snapshots}
    mount -o "${mount_opts},subvol=@home" "$root_dev" /mnt/home
    mount -o "${mount_opts},subvol=@.snapshots" "$root_dev" /mnt/.snapshots
    mkdir -p /mnt/var/log /mnt/var/cache/pacman/pkg
    mount -o "${mount_opts},subvol=@var" "$root_dev" /mnt/var
    mount -o "${mount_opts},subvol=@log" "$root_dev" /mnt/var/log
    mount -o "${mount_opts},subvol=@pkg" "$root_dev" /mnt/var/cache/pacman/pkg
}

configure_luks_boot() {
    local target=$1 luks_uuid=$2 crypt_name=${3:-cryptroot}
    local hooks='HOOKS=(base udev autodetect modconf kms keyboard keymap consolefont block encrypt filesystems fsck)'
    if grep -q '^HOOKS=' "$target/etc/mkinitcpio.conf"; then
        sed -i "s|^HOOKS=.*|$hooks|" "$target/etc/mkinitcpio.conf"
    else
        echo "$hooks" >> "$target/etc/mkinitcpio.conf"
    fi
    local cmdline="cryptdevice=UUID=$luks_uuid:$crypt_name root=/dev/mapper/$crypt_name"
    if grep -q '^GRUB_CMDLINE_LINUX=' "$target/etc/default/grub"; then
        sed -i "s|^GRUB_CMDLINE_LINUX=.*|GRUB_CMDLINE_LINUX=\"$cmdline\"|" "$target/etc/default/grub"
    else
        echo "GRUB_CMDLINE_LINUX=\"$cmdline\"" >> "$target/etc/default/grub"
    fi
}

# ------------------------------ Система ------------------------------------
update_pacman_database() {
    info "Обновление базы pacman..."
    cleanup_pacman_lock
    pacman -Sy --noconfirm archlinux-keyring || warn "pacman -Sy вернул ошибку"
}

configure_pacman_target() {
    local conf="$1/etc/pacman.conf"
    [[ -f $conf ]] || { warn "$conf не найден"; return 1; }
    sed -i '/\[multilib\]/,/Include/ s/^#//' "$conf"
    grep -q '^ILoveCandy' "$conf" || sed -i '/^\[options\]/a ILoveCandy' "$conf"
    sed -i 's/^#Color/Color/' "$conf"
    sed -i 's/^#ParallelDownloads = 5/ParallelDownloads = 25/' "$conf"
    sed -i 's/^#VerbosePkgLists/VerbosePkgLists/' "$conf"
}

configure_locales_target() {
    local target=$1 lang=$2
    local lgen="$target/etc/locale.gen"
    sed -i 's/^\([^#].*UTF-8\)/#\1/' "$lgen" 2>/dev/null || true
    sed -i 's/^#\?en_US.UTF-8/en_US.UTF-8/' "$lgen"
    case $lang in
        ru_RU.UTF-8) sed -i 's/^#\?ru_RU.UTF-8/ru_RU.UTF-8/' "$lgen" ;;
        uk_UA.UTF-8) sed -i 's/^#\?uk_UA.UTF-8/uk_UA.UTF-8/' "$lgen" ;;
        be_BY.UTF-8) sed -i 's/^#\?be_BY.UTF-8/be_BY.UTF-8/' "$lgen" ;;
        de_DE.UTF-8) sed -i 's/^#\?de_DE.UTF-8/de_DE.UTF-8/' "$lgen" ;;
        pl_PL.UTF-8) sed -i 's/^#\?pl_PL.UTF-8/pl_PL.UTF-8/' "$lgen" ;;
    esac
    echo "LANG=$lang" > "$target/etc/locale.conf"
    arch-chroot "$target" locale-gen
}

configure_vconsole_target() {
    local target=$1 lang=$2
    case $lang in
        ru_RU.UTF-8) printf 'KEYMAP=ru\nFONT=cyr-sun16\n' > "$target/etc/vconsole.conf" ;;
        uk_UA.UTF-8) printf 'KEYMAP=uk\nFONT=cyr-sun16\n' > "$target/etc/vconsole.conf" ;;
        be_BY.UTF-8) printf 'KEYMAP=by\nFONT=cyr-sun16\n' > "$target/etc/vconsole.conf" ;;
        de_DE.UTF-8) printf 'KEYMAP=de-latin1\nFONT=Lat2-Terminus16\n' > "$target/etc/vconsole.conf" ;;
        pl_PL.UTF-8) printf 'KEYMAP=pl\nFONT=Lat2-Terminus16\n' > "$target/etc/vconsole.conf" ;;
        *)           printf 'KEYMAP=us\n' > "$target/etc/vconsole.conf" ;;
    esac
}

create_user() {
    local target=$1 user=$2 pass=$3 rootpass=$4
    printf 'root:%s\n' "$rootpass" | arch-chroot "$target" chpasswd
    arch-chroot "$target" useradd -m -G wheel -s /bin/bash "$user"
    printf '%s:%s\n' "$user" "$pass" | arch-chroot "$target" chpasswd
    grep -q '^%wheel' "$target/etc/sudoers" || echo '%wheel ALL=(ALL:ALL) ALL' >> "$target/etc/sudoers"
}

install_grub() {
    local target=$1 disk=$2
    info "Установка GRUB..."
    if [[ -d /sys/firmware/efi ]]; then
        arch-chroot "$target" grub-install \
            --target=x86_64-efi --efi-directory=/boot/efi \
            --bootloader-id=Arch --removable
        arch-chroot "$target" grub-install \
            --target=x86_64-efi --efi-directory=/boot/efi \
            --bootloader-id=Arch
    else
        arch-chroot "$target" grub-install --target=i386-pc "$disk"
    fi
}

generate_grub_config() { arch-chroot "$1" grub-mkconfig -o /boot/grub/grub.cfg; }

find_existing_os() {
    local disk=$1 exclude_part=$2
    local -n _part=$3 _fs=$4 _subvol=$5 _name=$6
    _part=""; _fs=""; _subvol=""; _name=""

    mkdir -p /mnt/os
    while read -r line; do
        local part fs
        part="/dev/$(echo "$line" | awk '{print $1}')"
        fs=$(echo "$line" | awk '{print $2}')
        [[ $part == "$exclude_part" ]] && continue
        [[ $fs =~ ^(btrfs|ext4|xfs|ext3|ext2|ntfs)$ ]] || continue

        if [[ $fs == btrfs ]]; then
            for sv in @ @root root ""; do
                if [[ -n $sv ]]; then
                    mount -o "ro,subvol=$sv" "$part" /mnt/os 2>/dev/null || continue
                else
                    mount -o ro "$part" /mnt/os 2>/dev/null || continue
                fi
                if [[ -d /mnt/os/etc && -d /mnt/os/usr ]]; then
                    _part=$part; _fs=btrfs; _subvol=$sv; _name=Linux
                    umount /mnt/os; rmdir /mnt/os 2>/dev/null || true
                    return 0
                fi
                umount /mnt/os 2>/dev/null || true
            done
        elif [[ $fs == ntfs ]]; then
            command -v ntfs-3g >/dev/null || pacman -S --noconfirm ntfs-3g >/dev/null
            if mount -t ntfs3 -o ro "$part" /mnt/os 2>/dev/null || \
               mount -t ntfs-3g -o ro "$part" /mnt/os 2>/dev/null; then
                if [[ -d /mnt/os/Windows/System32 ]]; then
                    _part=$part; _fs=ntfs; _subvol=""; _name=Windows
                    umount /mnt/os; rmdir /mnt/os 2>/dev/null || true
                    return 0
                fi
                umount /mnt/os
            fi
        else
            if mount -o ro "$part" /mnt/os 2>/dev/null; then
                if [[ -d /mnt/os/etc && -d /mnt/os/usr ]]; then
                    _part=$part; _fs=$fs; _subvol=""; _name=Linux
                    umount /mnt/os; rmdir /mnt/os 2>/dev/null || true
                    return 0
                fi
                umount /mnt/os
            fi
        fi
    done < <(lsblk -lno NAME,FSTYPE "$disk" | grep -v '^$')
    rmdir /mnt/os 2>/dev/null || true
    return 1
}

add_other_os_to_grub() {
    local target=$1 os_part=$2 os_subvol=$3
    info "Добавление существующей ОС в GRUB..."
    mkdir -p "$target/os"
    if [[ -n $os_subvol ]]; then
        mount -o "rw,subvol=$os_subvol" "$os_part" "$target/os" || return 1
    else
        mount "$os_part" "$target/os" || return 1
    fi

    if ! command -v os-prober >/dev/null; then
        arch-chroot "$target" pacman -S --noconfirm os-prober ntfs-3g || true
    fi

    local grubfile="$target/etc/default/grub"
    if grep -q '^GRUB_DISABLE_OS_PROBER' "$grubfile"; then
        sed -i 's/^GRUB_DISABLE_OS_PROBER=.*/GRUB_DISABLE_OS_PROBER=false/' "$grubfile"
    elif grep -q '^#GRUB_DISABLE_OS_PROBER' "$grubfile"; then
        sed -i 's/^#GRUB_DISABLE_OS_PROBER=.*/GRUB_DISABLE_OS_PROBER=false/' "$grubfile"
    else
        echo 'GRUB_DISABLE_OS_PROBER=false' >> "$grubfile"
    fi

    mount --bind /dev "$target/os/dev"
    mount --bind /proc "$target/os/proc"
    mount --bind /sys "$target/os/sys"
    arch-chroot "$target" os-prober 2>&1 | tee -a "$LOG_FILE" || true
    umount "$target/os/sys" "$target/os/proc" "$target/os/dev" 2>/dev/null || true

    generate_grub_config "$target"
    umount "$target/os" 2>/dev/null || true
    rmdir "$target/os" 2>/dev/null || true
}

# ------------------------------ GPU / Desktop ------------------------------
install_gpu_intel() {
    arch-chroot "$1" pacman -S --noconfirm --needed \
        mesa mesa-utils lib32-mesa \
        libva lib32-libva libva-utils libva-mesa-driver lib32-libva-mesa-driver \
        vulkan-intel lib32-vulkan-intel vulkan-icd-loader lib32-vulkan-icd-loader \
        vulkan-tools vulkan-mesa-layers lib32-vulkan-mesa-layers \
        intel-media-driver intel-gpu-tools vpl-gpu-rt \
        libgl lib32-libgl
}

install_gpu_amd() {
    arch-chroot "$1" pacman -S --noconfirm --needed \
        mesa mesa-utils lib32-mesa \
        libva lib32-libva libva-utils libva-mesa-driver lib32-libva-mesa-driver \
        vulkan-radeon lib32-vulkan-radeon vulkan-icd-loader lib32-vulkan-icd-loader \
        vulkan-tools vulkan-mesa-layers lib32-vulkan-mesa-layers \
        xf86-video-amdgpu libgl lib32-libgl
}

install_gpu_nvidia() {
    local t=$1 type=$2
    if [[ $type == open ]]; then
        arch-chroot "$t" pacman -S --noconfirm --needed \
            nvidia-open nvidia-utils lib32-nvidia-utils nvidia-settings \
            opencl-nvidia lib32-opencl-nvidia \
            vulkan-icd-loader lib32-vulkan-icd-loader
    else
        arch-chroot "$t" pacman -S --noconfirm --needed \
            nvidia-dkms nvidia-utils lib32-nvidia-utils nvidia-settings \
            opencl-nvidia lib32-opencl-nvidia \
            vulkan-icd-loader lib32-vulkan-icd-loader
    fi
}

# NVIDIA: DRM KMS для Wayland
configure_nvidia_wayland() {
    local t=$1
    local grubfile="$t/etc/default/grub"
    local modfile="$t/etc/mkinitcpio.conf"
    if grep -q '^GRUB_CMDLINE_LINUX_DEFAULT=' "$grubfile"; then
        if ! grep -q 'nvidia_drm.modeset=1' "$grubfile"; then
            sed -i 's|^GRUB_CMDLINE_LINUX_DEFAULT="\(.*\)"|GRUB_CMDLINE_LINUX_DEFAULT="\1 nvidia_drm.modeset=1"|' "$grubfile"
        fi
    fi
    if grep -q '^MODULES=' "$modfile"; then
        sed -i 's/^MODULES=.*/MODULES=(nvidia nvidia_modeset nvidia_uvm nvidia_drm)/' "$modfile"
    else
        echo 'MODULES=(nvidia nvidia_modeset nvidia_uvm nvidia_drm)' >> "$modfile"
    fi
}

install_desktop_kde() {
    local t=$1 variant=$2
    if [[ $variant == full ]]; then
        arch-chroot "$t" pacman -S --noconfirm --needed \
            xorg plasma plasma-wayland-session plasma-wayland-protocols \
            kde-applications sddm sddm-kcm firefox
    else
        arch-chroot "$t" pacman -S --noconfirm --needed \
            xorg plasma plasma-wayland-session plasma-wayland-protocols \
            konsole dolphin sddm sddm-kcm firefox
    fi
    arch-chroot "$t" systemctl enable sddm

    # SDDM: Wayland-сессия
    local sddm_conf="$t/etc/sddm.conf.d/10-wayland.conf"
    mkdir -p "$(dirname "$sddm_conf")"
    cat > "$sddm_conf" <<EOF
[General]
DisplayServer=wayland
EOF
}

install_desktop_gnome() {
    local t=$1 variant=$2
    if [[ $variant == full ]]; then
        arch-chroot "$t" pacman -S --noconfirm --needed \
            xorg gnome gnome-extra firefox gdm
    else
        arch-chroot "$t" pacman -S --noconfirm --needed \
            xorg gnome-shell gnome-terminal nautilus firefox gdm
    fi
    arch-chroot "$t" systemctl enable gdm
}

install_desktop_xfce() {
    local t=$1
    arch-chroot "$t" pacman -S --noconfirm --needed \
        xorg xfce4 xfce4-goodies lightdm lightdm-gtk-greeter firefox
    arch-chroot "$t" systemctl enable lightdm
}

install_desktop_cinnamon() {
    local t=$1
    arch-chroot "$t" pacman -S --noconfirm --needed \
        xorg cinnamon lightdm lightdm-slick-greeter firefox
    arch-chroot "$t" systemctl enable lightdm
}

install_desktop_mate() {
    local t=$1
    arch-chroot "$t" pacman -S --noconfirm --needed \
        xorg mate mate-extra lightdm lightdm-slick-greeter firefox
    arch-chroot "$t" systemctl enable lightdm
}

install_desktop_lxqt() {
    local t=$1
    arch-chroot "$t" pacman -S --noconfirm --needed \
        xorg lxqt breeze-icons sddm sddm-kcm firefox
    arch-chroot "$t" systemctl enable sddm
}

install_desktop_i3() {
    local t=$1 user=$2
    arch-chroot "$t" pacman -S --noconfirm --needed \
        xorg xorg-xinit i3-wm i3status i3lock dmenu alacritty rofi picom \
        nitrogen feh network-manager-applet volumeicon xss-lock polkit-gnome \
        ttf-dejavu ttf-droid ttf-font-awesome

    cat > "$t/home/$user/.xinitrc" <<EOF
#!/bin/sh
exec i3
EOF
    cat >> "$t/home/$user/.bash_profile" <<EOF

if [ -z "\$DISPLAY" ] && [ "\$(tty)" = "/dev/tty1" ]; then
    startx
fi
EOF
    arch-chroot "$t" chown "$user:$user" "/home/$user/.xinitrc" "/home/$user/.bash_profile"
    arch-chroot "$t" chmod +x "/home/$user/.xinitrc"
}

install_desktop() {
    local t=$1 choice=$2 user=$3
    case $choice in
        1) install_desktop_kde "$t" full ;;
        2) install_desktop_kde "$t" light ;;
        3) install_desktop_gnome "$t" full ;;
        4) install_desktop_gnome "$t" light ;;
        5) install_desktop_xfce "$t" ;;
        6) install_desktop_cinnamon "$t" ;;
        7) install_desktop_mate "$t" ;;
        8) install_desktop_lxqt "$t" ;;
        9) install_desktop_i3 "$t" "$user" ;;
        0) info "Рабочий стол не устанавливается" ;;
    esac
}

# ------------------------------ Зеркала ------------------------------------
sort_mirrors() {
    clear
    echo -e "\033[1;36m"
    echo "╔═══════════════════════════════════════════════════════════════════════╗"
    echo "║                       eArch — Сортировка зеркал                       ║"
    echo "╚═══════════════════════════════════════════════════════════════════════╝"
    echo -e "\033[0m"

    if ! command -v reflector >/dev/null; then
        info "Установка reflector..."
        pacman -Sy --noconfirm reflector
    fi

    [[ -f /etc/pacman.d/mirrorlist ]] && \
        cp /etc/pacman.d/mirrorlist /etc/pacman.d/mirrorlist.backup

    info "Сортировка зеркал..."
    if reflector --latest 20 --protocol https --sort rate \
                 --save /etc/pacman.d/mirrorlist; then
        ok "Зеркала отсортированы"
    else
        err "Ошибка сортировки"
        [[ -f /etc/pacman.d/mirrorlist.backup ]] && \
            cp /etc/pacman.d/mirrorlist.backup /etc/pacman.d/mirrorlist
    fi
    update_pacman_database
    ok "Готово"
}

# ------------------------------ Меню выбора --------------------------------
select_disk() {
    local -a items=()
    while IFS= read -r line; do items+=("$line"); done < <(list_disks)
    ((${#items[@]})) || { ui_msg "Не найдено дисков!"; return 1; }
    ui_select_kv "Выберите диск:" 18 70 10 "${items[@]}"
}

select_language() {
    local c
    c=$(ui_menu "Выберите язык:" 14 60 6 \
        "1" "Русский (ru_RU.UTF-8)" \
        "2" "Українська (uk_UA.UTF-8)" \
        "3" "Беларуская (be_BY.UTF-8)" \
        "4" "Deutsch (de_DE.UTF-8)" \
        "5" "Polski (pl_PL.UTF-8)" \
        "6" "English (en_US.UTF-8)") || return 1
    case $c in
        1) echo ru_RU.UTF-8 ;; 2) echo uk_UA.UTF-8 ;;
        3) echo be_BY.UTF-8 ;; 4) echo de_DE.UTF-8 ;;
        5) echo pl_PL.UTF-8 ;; 6) echo en_US.UTF-8 ;;
    esac
}

select_region() {
    local -a regions=()
    while IFS= read -r r; do
        r=$(basename "$r")
        case $r in
            posix|right|SystemV|Etc|GMT*|US|Canada|Mexico|Brazil|Chile|Cuba|Jamaica) continue ;;
        esac
        regions+=("$r" "")
    done < <(find /usr/share/zoneinfo -mindepth 1 -maxdepth 1 -type d | sort)

    local region
    region=$(ui_menu "Выберите регион:" 20 60 15 "${regions[@]}") || return 1

    local -a cities=()
    while IFS= read -r c; do
        c=$(basename "$c")
        cities+=("$c" "")
    done < <(find "/usr/share/zoneinfo/$region" -maxdepth 1 -type f | sort)

    local city
    city=$(ui_menu "Выберите город:" 20 60 15 "${cities[@]}") || return 1
    echo "$region/$city"
}

select_encryption() {
    local c
    c=$(ui_menu "Шифрование диска:" 10 60 3 \
        "1" "Без шифрования" \
        "2" "LUKS1" \
        "3" "LUKS2 (рекомендуется)") || return 1
    case $c in 1) echo none ;; 2) echo luks1 ;; 3) echo luks2 ;; esac
}

select_swap() {
    local c
    c=$(ui_menu "Размер swap:" 13 60 7 \
        "1" "Без swap" "2" "1 GB" "3" "2 GB" "4" "4 GB" \
        "5" "8 GB" "6" "16 GB" "7" "32 GB") || return 1
    case $c in
        1) echo 0 ;; 2) echo 1 ;; 3) echo 2 ;; 4) echo 4 ;;
        5) echo 8 ;; 6) echo 16 ;; 7) echo 32 ;;
    esac
}

select_desktop() {
    local c
    c=$(ui_menu "Рабочий стол:" 18 70 11 \
        "1" "KDE Plasma (полная, Wayland)" \
        "2" "KDE Plasma (облегчённая, Wayland)" \
        "3" "GNOME (полная)" \
        "4" "GNOME (облегчённая)" \
        "5" "XFCE" \
        "6" "Cinnamon" \
        "7" "MATE" \
        "8" "LXQt" \
        "9" "i3" \
        "0" "Не устанавливать") || return 1
    echo "$c"
}

select_kernel() {
    local c
    c=$(ui_menu "Ядро:" 10 60 3 \
        "1" "Linux (обычное)" \
        "2" "Linux-zen (производительное)" \
        "3" "Linux-lts (стабильное)") || return 1
    echo "$c"
}

select_gpu() {
    local c
    c=$(ui_menu "Драйверы видеокарты:" 12 60 5 \
        "1" "Intel" \
        "2" "AMD" \
        "3" "Nvidia dkms (рекомендуемый)" \
        "4" "Nvidia open" \
        "0" "Не устанавливать") || return 1
    echo "$c"
}

create_user_interactive() {
    local user pass pass2
    user=$(ui_input "Имя пользователя:") || return 1
    [[ -n $user ]] || { ui_msg "Имя не может быть пустым"; return 1; }
    while true; do
        pass=$(ui_password "Пароль для $user:") || return 1
        pass2=$(ui_password "Подтвердите пароль:") || return 1
        if [[ -n $pass && $pass == "$pass2" ]]; then break; fi
        ui_msg "Пароли не совпадают или пусты!"
    done
    printf '%s:%s\n' "$user" "$pass"
}

# ------------------------------ Автоустановка ------------------------------
show_settings_menu() {
    local -n _out=$1
    _out[DISK]=""
    _out[LANGUAGE]=""
    _out[REGION]=""
    _out[ENCRYPTION]="none"
    _out[DESKTOP]="0"
    _out[SWAP]="2"
    _out[USER]=""
    _out[PASS]=""
    _out[ROOTPASS]=""
    _out[KERNEL]="1"
    _out[GPU]="0"

    while true; do
        local disk_v="${_out[DISK]:-Не выбран}"
        local lang_v="${_out[LANGUAGE]:-Не выбран}"
        local region_v="${_out[REGION]:-Не выбран}"
        local enc_v="${_out[ENCRYPTION]}"
        local desk_v="${_out[DESKTOP]}"
        local swap_v="${_out[SWAP]}"
        local user_v="${_out[USER]:-Не создан}"
        local kernel_v="${_out[KERNEL]}"
        local gpu_v="${_out[GPU]}"

        local choice
        choice=$(ui_menu "\n\n\n" 22 85 11 \
            "1"  "Диск ($disk_v)" \
            "2"  "Язык ($lang_v)" \
            "3"  "Регион ($region_v)" \
            "4"  "Шифрование ($enc_v)" \
            "5"  "Рабочий стол ($desk_v)" \
            "6"  "Swap (${swap_v} GB)" \
            "7"  "Пользователь ($user_v)" \
            "8"  "Ядро ($kernel_v)" \
            "9"  "Драйверы GPU ($gpu_v)" \
            "10" "Начать установку") || return 1

        case $choice in
            1) local d; d=$(select_disk) && _out[DISK]="$d" ;;
            2) local l; l=$(select_language) && _out[LANGUAGE]="$l" ;;
            3) local r; r=$(select_region) && _out[REGION]="$r" ;;
            4) local e; e=$(select_encryption) && _out[ENCRYPTION]="$e" ;;
            5) local de; de=$(select_desktop) && _out[DESKTOP]="$de" ;;
            6) local sw; sw=$(select_swap) && _out[SWAP]="$sw" ;;
            7) local u; if u=$(create_user_interactive); then
                   _out[USER]="${u%%:*}"; _out[PASS]="${u#*:}"; _out[ROOTPASS]="${u#*:}"
               fi ;;
            8) local k; k=$(select_kernel) && _out[KERNEL]="$k" ;;
            9) local g; g=$(select_gpu) && _out[GPU]="$g" ;;
            10)
                if [[ -z ${_out[DISK]} || -z ${_out[LANGUAGE]} || -z ${_out[REGION]} || -z ${_out[USER]} ]]; then
                    ui_msg "Заполните все обязательные параметры!"
                    continue
                fi
                return 0 ;;
        esac
    done
}

confirm_settings() {
    local -n _s=$1
    local msg
    msg=$(printf 'Проверьте параметры:\n\nДиск: %s\nЯзык: %s\nРегион: %s\nШифрование: %s\nSwap: %s GB\nПользователь: %s\nЯдро: %s\nРабочий стол: %s\nДрайверы GPU: %s\n\nНачать установку?' \
        "${_s[DISK]}" "${_s[LANGUAGE]}" "${_s[REGION]}" "${_s[ENCRYPTION]}" \
        "${_s[SWAP]}" "${_s[USER]}" "${_s[KERNEL]}" "${_s[DESKTOP]}" "${_s[GPU]}")
    ui_yesno "$msg" 26 70
}

# Подготовка LUKS-раздела: format + open + mkfs
prepare_luks_root() {
    local part=$1 enc_type=$2 pass=$3
    info "LUKS: форматирование $part ($enc_type)"
    luks_format "$part" "$enc_type" "$pass"
    luks_open "$part" cryptroot "$pass"
    local luks_uuid
    luks_uuid=$(blkid -s UUID -o value "$part")
    echo "$luks_uuid"
}

run_auto_installation() {
    local -n s=$1
    local mode=$2   # clean | side

    clear
    echo -e "\033[1;36m"
    echo "╔═══════════════════════════════════════════════════════════════════════╗"
    echo "║                       eArch — Автоустановка                           ║"
    echo "╚═══════════════════════════════════════════════════════════════════════╝"
    echo -e "\033[0m"

    update_pacman_database
    cleanup_mounts

    local disk="${s[DISK]}" swap_gb="${s[SWAP]}" enc="${s[ENCRYPTION]}"
    local disk_type mount_opts
    disk_type=$(check_disk_type "$disk")
    mount_opts=$(mount_options_for "$disk_type")
    info "Тип диска: $disk_type"

    local ROOT_PART="" BOOT_PART="" SWAP_PART=""
    local EXISTING_ROOT_PART="" EXISTING_SUBVOL=""

    if [[ $mode == clean ]]; then
        wipe_disk "$disk"
        create_partitions_auto "$disk" "$swap_gb" ROOT_PART BOOT_PART SWAP_PART
    else
        # side-режим: ищем свободное место
        local free_info free_start free_size
        free_info=$(parted -s "$disk" unit MiB print free | awk '/Free Space/ {print $1, $3}' | tail -1)
        free_start=$(echo "$free_info" | awk '{print $1}' | cut -d. -f1)
        free_size=$(echo "$free_info" | awk '{print $2}' | cut -d. -f1)
        [[ -n $free_size && $free_size -ge 10240 ]] || {
            err "Недостаточно свободного места (нужно ≥10 ГБ)"
            return 1
        }
        info "Свободно: ${free_size}MiB с ${free_start}MiB"

        local efi_part=""
        if [[ -d /sys/firmware/efi ]]; then
            efi_part=$(lsblk -lno NAME,PARTTYPE | awk -v d="$(basename "$disk")" \
                '$2=="c12a7328-f81f-11d2-ba4b-00a0c93ec93b"{print "/dev/"$1}' | head -1)
            [[ -z $efi_part ]] && efi_part=$(lsblk -lno NAME,FSTYPE | \
                awk '$2=="vfat"{print "/dev/"$1}' | head -1)
            if [[ -n $efi_part ]]; then
                BOOT_PART="$efi_part"
                info "Используем существующий EFI: $efi_part"
            fi
        fi

        local cur=$free_start
        if [[ -z $BOOT_PART && -d /sys/firmware/efi ]]; then
            parted -s "$disk" mkpart primary fat32 "${cur}MiB" "$((cur + 300))MiB"
            local last
            last=$(parted -s "$disk" print | awk '/^ [0-9]+/ {n=$1} END{print n}')
            parted -s "$disk" set "$last" esp on
            BOOT_PART="${disk}${last}"
            mkfs.fat -F32 "$BOOT_PART"
            cur=$((cur + 300)); free_size=$((free_size - 300))
        fi

        if ((swap_gb > 0)); then
            parted -s "$disk" mkpart primary linux-swap "${cur}MiB" "$((cur + swap_gb * 1024))MiB"
            local last
            last=$(parted -s "$disk" print | awk '/^ [0-9]+/ {n=$1} END{print n}')
            SWAP_PART="${disk}${last}"
            mkswap "$SWAP_PART"; swapon "$SWAP_PART"
            cur=$((cur + swap_gb * 1024))
        fi

        parted -s "$disk" mkpart primary btrfs "${cur}MiB" 100%
        local last
        last=$(parted -s "$disk" print | awk '/^ [0-9]+/ {n=$1} END{print n}')
        ROOT_PART="${disk}${last}"
        partprobe "$disk" 2>/dev/null || true
        udevadm settle 2>/dev/null || sleep 2

        find_existing_os "$disk" "$ROOT_PART" \
            EXISTING_ROOT_PART EXISTING_SUBVOL _ _ || true
    fi

    # swap
    if [[ -n $SWAP_PART ]]; then
        mkswap "$SWAP_PART"; swapon "$SWAP_PART"
    fi

    # LUKS
    local LUKS_UUID=""
    if [[ $enc != none ]]; then
        LUKS_UUID=$(prepare_luks_root "$ROOT_PART" "$enc" "${s[ROOTPASS]}")
        ROOT_PART="/dev/mapper/cryptroot"
    fi

    # Форматирование корня
    mkfs.btrfs -f "$ROOT_PART"

    # subvolumes
    setup_btrfs_subvolumes "$ROOT_PART" "$mount_opts"

    # EFI
    if [[ -d /sys/firmware/efi && -n $BOOT_PART ]]; then
        mkdir -p /mnt/boot/efi
        mount "$BOOT_PART" /mnt/boot/efi
    fi

    # Ядро
    local kernel_pkgs
    case ${s[KERNEL]} in
        1) kernel_pkgs="linux linux-headers" ;;
        2) kernel_pkgs="linux-zen linux-zen-headers" ;;
        3) kernel_pkgs="linux-lts linux-lts-headers" ;;
        *) kernel_pkgs="linux linux-headers" ;;
    esac

    info "pacstrap..."
    pacstrap /mnt base base-devel $kernel_pkgs linux-firmware iucode-tool \
        btrfs-progs dosfstools efibootmgr grub grub-btrfs os-prober ntfs-3g \
        amd-ucode intel-ucode networkmanager dhcpcd nano vim archlinux-keyring \
        --noconfirm

    genfstab -U /mnt > /mnt/etc/fstab

    # ВАЖНО: конфиги target — после pacstrap
    configure_pacman_target /mnt
    configure_locales_target /mnt "${s[LANGUAGE]}"
    configure_vconsole_target /mnt "${s[LANGUAGE]}"

    arch-chroot /mnt ln -sf "/usr/share/zoneinfo/${s[REGION]}" /etc/localtime
    arch-chroot /mnt hwclock --systohc

    echo arch > /mnt/etc/hostname
    cat > /mnt/etc/hosts <<EOF
127.0.0.1   localhost
::1         localhost
127.0.1.1   arch.localdomain arch
EOF

    create_user /mnt "${s[USER]}" "${s[PASS]}" "${s[ROOTPASS]}"

    # LUKS boot config
    if [[ -n $LUKS_UUID ]]; then
        configure_luks_boot /mnt "$LUKS_UUID"
    fi

    # GPU
    case ${s[GPU]} in
        1) install_gpu_intel /mnt ;;
        2) install_gpu_amd /mnt ;;
        3) install_gpu_nvidia /mnt dkms; configure_nvidia_wayland /mnt ;;
        4) install_gpu_nvidia /mnt open; configure_nvidia_wayland /mnt ;;
    esac

    # Desktop
    install_desktop /mnt "${s[DESKTOP]}" "${s[USER]}"

    # Сервисы
    arch-chroot /mnt systemctl enable NetworkManager
    arch-chroot /mnt systemctl enable bluetooth 2>/dev/null || true
    arch-chroot /mnt systemctl enable cups 2>/dev/null || true

    # GRUB
    install_grub /mnt "$disk"

    arch-chroot /mnt mkinitcpio -P

    if [[ $mode == side && -n $EXISTING_ROOT_PART ]]; then
        add_other_os_to_grub /mnt "$EXISTING_ROOT_PART" "$EXISTING_SUBVOL"
    else
        generate_grub_config /mnt
    fi

    ok "Установка завершена!"
}

auto_install_flow() {
    local -A s
    show_settings_menu s || return 0
    confirm_settings s || return 0
    if run_auto_installation s clean; then
        KEEP_MOUNTS=1
        umount -R /mnt 2>/dev/null || true
        read -rp "Нажмите Enter для перезагрузки..." _
        reboot
    fi
}

auto_install_side_flow() {
    local -A s
    show_settings_menu s || return 0
    confirm_settings s || return 0
    if run_auto_installation s side; then
        KEEP_MOUNTS=1
        umount -R /mnt 2>/dev/null || true
        read -rp "Нажмите Enter для перезагрузки..." _
        reboot
    fi
}

# ------------------------------ Ручная установка ---------------------------
manual_select_disk() {
    local -a items=()
    while IFS= read -r line; do items+=("$line"); done < <(list_disks)
    ((${#items[@]})) || { ui_msg "Не найдено дисков!"; return 1; }
    ui_select_kv "Выберите диск:" 18 70 10 "${items[@]}"
}

manual_partitions() {
    local disk=$1
    clear
    echo -e "\033[1;33mДиск: $disk\033[0m"
    echo "cfdisk: стрелки — навигация, Enter — изменить, Delete — удалить, Ctrl+C — выход"
    read -rp "Нажмите Enter для запуска cfdisk..." _
    cfdisk "$disk"
}

manual_filesystem() {
    local -n _fs=$1
    while true; do
        local -a items=()
        while IFS= read -r line; do items+=("$line"); done < <(list_all_partitions)
        ((${#items[@]})) || { ui_msg "Нет разделов!"; return 1; }
        local part
        part=$(ui_select_kv "Раздел для настройки ФС:" 20 90 12 "${items[@]}") || return 0
        local choice
        choice=$(ui_menu "ФС для $part:" 16 60 9 \
            "1" "btrfs" "2" "ext4" "3" "fat32" "4" "xfs" \
            "5" "f2fs" "6" "ntfs" "0" "Не форматировать") || continue
        case $choice in
            1) _fs["$part"]=btrfs ;; 2) _fs["$part"]=ext4 ;;
            3) _fs["$part"]=fat32 ;; 4) _fs["$part"]=xfs ;;
            5) _fs["$part"]=f2fs ;; 6) _fs["$part"]=ntfs ;;
            0) _fs["$part"]=none ;;
        esac
    done
}

manual_encryption() {
    local -n _enc=$1
    while true; do
        local -a items=()
        while IFS= read -r line; do items+=("$line"); done < <(list_all_partitions)
        ((${#items[@]})) || { ui_msg "Нет разделов!"; return 1; }
        local part
        part=$(ui_select_kv "Раздел для шифрования:" 20 90 12 "${items[@]}") || return 0
        local choice
        choice=$(ui_menu "Шифрование $part:" 12 60 4 \
            "1" "LUKS2" "2" "LUKS1" "0" "Без шифрования") || continue
        case $choice in
            1) _enc["$part"]=luks2 ;; 2) _enc["$part"]=luks1 ;;
            0) _enc["$part"]=none ;;
        esac
    done
}

manual_mountpoints() {
    local -n _mnt=$1 _fs=$2
    while true; do
        local -a items=()
        while IFS= read -r line; do items+=("$line"); done < <(list_all_partitions)
        ((${#items[@]})) || { ui_msg "Нет разделов!"; return 1; }
        local part
        part=$(ui_select_kv "Раздел для монтирования:" 20 90 12 "${items[@]}") || return 0
        local choice
        choice=$(ui_menu "Точка для $part:" 14 60 6 \
            "1" "/ (Root)" "2" "/boot/efi" "3" "/boot" \
            "4" "/home" "5" "swap" "0" "Не монтировать") || continue
        case $choice in
            1) _mnt["$part"]="/" ;;
            2) _mnt["$part"]="/boot/efi" ;;
            3) _mnt["$part"]="/boot" ;;
            4) _mnt["$part"]="/home" ;;
            5) _mnt["$part"]="swap"; _fs["$part"]=swap; _enc["$part"]=none ;;
            0) _mnt["$part"]="none" ;;
        esac
    done
}

manual_apply_partitioning() {
    local -n _fs=$1 _enc=$2 _mnt=$3
    local -A _mapper=()

    # 1. Проверка корня
    local root_part=""
    for p in "${!_mnt[@]}"; do
        [[ ${_mnt[$p]} == "/" ]] && { root_part=$p; break; }
    done
    [[ -n $root_part ]] || { err "Не выбран корневой раздел (/)"; return 1; }

    # 2. LUKS + mkfs (сначала LUKS, потом mkfs)
    for p in "${!_fs[@]}"; do
        local fs="${_fs[$p]}" enc="${_enc[$p]:-none}"
        [[ -b $p ]] || continue
        [[ $fs == none || -z $fs ]] && continue

        if [[ $enc != none ]]; then
            local pass="${MANUAL_ROOTPASS}"
            luks_format "$p" "$enc" "$pass"
            local name="crypt_$(basename "$p")"
            luks_open "$p" "$name" "$pass"
            _mapper["$p"]="/dev/mapper/$name"
            format_partition "/dev/mapper/$name" "$fs"
        else
            format_partition "$p" "$fs"
        fi
        _mapper["$p"]="${_mapper[$p]:-$p}"
    done

    # 3. Монтирование: / → /boot → /boot/efi → остальные
    local root_dev="${_mapper[$root_part]:-$root_part}"
    mount "$root_dev" /mnt
    mkdir -p /mnt/{boot,home,var,.snapshots}

    # /boot
    for p in "${!_mnt[@]}"; do
        [[ ${_mnt[$p]} == "/boot" ]] || continue
        mkdir -p /mnt/boot
        mount "${_mapper[$p]:-$p}" /mnt/boot
    done

    # /boot/efi
    for p in "${!_mnt[@]}"; do
        [[ ${_mnt[$p]} == "/boot/efi" ]] || continue
        mkdir -p /mnt/boot/efi
        mount "${_mapper[$p]:-$p}" /mnt/boot/efi
    done

    # swap
    for p in "${!_mnt[@]}"; do
        [[ ${_mnt[$p]} == "swap" ]] || continue
        swapon "${_mapper[$p]:-$p}" 2>/dev/null || true
    done

    # остальные
    for p in "${!_mnt[@]}"; do
        local mp="${_mnt[$p]}"
        [[ $mp == "/" || $mp == "/boot" || $mp == "/boot/efi" || $mp == "swap" || $mp == "none" ]] && continue
        mkdir -p "/mnt$mp"
        mount "${_mapper[$p]:-$p}" "/mnt$mp"
    done

    # Экспорт mapper для дальнейшего использования
    declare -gA MANUAL_MAPPER=()
    for k in "${!_mapper[@]}"; do MANUAL_MAPPER[$k]="${_mapper[$k]}"; done
}

run_manual_installation() {
    local -n s=$1
    clear
    echo -e "\033[1;36m"
    echo "╔═══════════════════════════════════════════════════════════════════════╗"
    echo "║                      eArch — Ручная установка                         ║"
    echo "╚═══════════════════════════════════════════════════════════════════════╝"
    echo -e "\033[0m"

    update_pacman_database

    # Применяем разметку
    manual_apply_partitioning PARTITION_FS PARTITION_ENCRYPTION PARTITION_MOUNT

    # Корневой раздел
    local root_part="" root_dev="" root_fs=""
    for p in "${!PARTITION_MOUNT[@]}"; do
        if [[ ${PARTITION_MOUNT[$p]} == "/" ]]; then
            root_part=$p
            root_dev="${MANUAL_MAPPER[$p]:-$p}"
            root_fs="${PARTITION_FS[$p]}"
            break
        fi
    done

    local disk_type mount_opts
    disk_type=$(check_disk_type "${s[DISK]}")
    mount_opts=$(mount_options_for "$disk_type")

    # Если корень btrfs — пересоздаём subvolumes
    if [[ $root_fs == btrfs ]]; then
        umount -R /mnt 2>/dev/null || true
        setup_btrfs_subvolumes "$root_dev" "$mount_opts"
        # Возвращаем дополнительные монтирования
        for p in "${!PARTITION_MOUNT[@]}"; do
            local mp="${PARTITION_MOUNT[$p]}"
            [[ $mp == "/" || $mp == "none" || $mp == "swap" ]] && continue
            mkdir -p "/mnt$mp"
            mount "${MANUAL_MAPPER[$p]:-$p}" "/mnt$mp"
        done
    fi

    # Ядро
    local kernel_pkgs
    case ${s[KERNEL]} in
        1) kernel_pkgs="linux linux-headers" ;;
        2) kernel_pkgs="linux-zen linux-zen-headers" ;;
        3) kernel_pkgs="linux-lts linux-lts-headers" ;;
    esac

    info "pacstrap..."
    pacstrap /mnt base base-devel $kernel_pkgs linux-firmware iucode-tool \
        btrfs-progs dosfstools efibootmgr grub grub-btrfs os-prober ntfs-3g \
        amd-ucode intel-ucode networkmanager dhcpcd nano vim archlinux-keyring \
        --noconfirm

    genfstab -U /mnt > /mnt/etc/fstab

    configure_pacman_target /mnt
    configure_locales_target /mnt "${s[LANGUAGE]}"
    configure_vconsole_target /mnt "${s[LANGUAGE]}"

    arch-chroot /mnt ln -sf "/usr/share/zoneinfo/${s[REGION]}" /etc/localtime
    arch-chroot /mnt hwclock --systohc

    echo arch > /mnt/etc/hostname
    cat > /mnt/etc/hosts <<EOF
127.0.0.1   localhost
::1         localhost
127.0.1.1   arch.localdomain arch
EOF

    create_user /mnt "${s[USER]}" "${s[PASS]}" "${s[ROOTPASS]}"

    # LUKS boot config
    for p in "${!PARTITION_ENCRYPTION[@]}"; do
        if [[ ${PARTITION_ENCRYPTION[$p]} != none && ${PARTITION_MOUNT[$p]:-} == "/" ]]; then
            local luks_uuid
            luks_uuid=$(blkid -s UUID -o value "$p")
            configure_luks_boot /mnt "$luks_uuid"
            break
        fi
    done

    case ${s[GPU]} in
        1) install_gpu_intel /mnt ;;
        2) install_gpu_amd /mnt ;;
        3) install_gpu_nvidia /mnt dkms; configure_nvidia_wayland /mnt ;;
        4) install_gpu_nvidia /mnt open; configure_nvidia_wayland /mnt ;;
    esac

    install_desktop /mnt "${s[DESKTOP]}" "${s[USER]}"

    arch-chroot /mnt systemctl enable NetworkManager
    arch-chroot /mnt systemctl enable bluetooth 2>/dev/null || true
    arch-chroot /mnt systemctl enable cups 2>/dev/null || true

    install_grub /mnt "${s[DISK]}"
    arch-chroot /mnt mkinitcpio -P
    generate_grub_config /mnt

    ok "Установка завершена!"
}

manual_install_flow() {
    local -A s
    s[DISK]=""; s[LANGUAGE]=""; s[REGION]=""; s[USER]=""; s[PASS]=""; s[ROOTPASS]=""
    s[KERNEL]="1"; s[DESKTOP]="0"; s[GPU]="0"

    declare -gA PARTITION_FS=()
    declare -gA PARTITION_ENCRYPTION=()
    declare -gA PARTITION_MOUNT=()
    declare -gA MANUAL_MAPPER=()

    while true; do
        local fs_count=${#PARTITION_FS[@]}
        local mnt_count=${#PARTITION_MOUNT[@]}
        local choice
        choice=$(ui_menu "\n\n\n" 26 85 13 \
            "1"  "Диск (${s[DISK]:-Не выбран})" \
            "2"  "Разметка (cfdisk)" \
            "3"  "ФС ($fs_count разделов)" \
            "4"  "Шифрование" \
            "5"  "Монтирование ($mnt_count разделов)" \
            "6"  "Язык (${s[LANGUAGE]:-Не выбран})" \
            "7"  "Регион (${s[REGION]:-Не выбран})" \
            "8"  "Пользователь (${s[USER]:-Не создан})" \
            "9"  "Рабочий стол (${s[DESKTOP]})" \
            "10" "Ядро (${s[KERNEL]})" \
            "11" "Драйверы GPU (${s[GPU]})" \
            "12" "Начать установку") || return 0

        case $choice in
            1) local d; d=$(manual_select_disk) && s[DISK]="$d" ;;
            2) [[ -n ${s[DISK]} ]] && manual_partitions "${s[DISK]}" ;;
            3) manual_filesystem PARTITION_FS ;;
            4) manual_encryption PARTITION_ENCRYPTION ;;
            5) manual_mountpoints PARTITION_MOUNT PARTITION_FS ;;
            6) local l; l=$(select_language) && s[LANGUAGE]="$l" ;;
            7) local r; r=$(select_region) && s[REGION]="$r" ;;
            8) local u; if u=$(create_user_interactive); then
                   s[USER]="${u%%:*}"; s[PASS]="${u#*:}"; s[ROOTPASS]="${u#*:}"
               fi ;;
            9) local de; de=$(select_desktop) && s[DESKTOP]="$de" ;;
            10) local k; k=$(select_kernel) && s[KERNEL]="$k" ;;
            11) local g; g=$(select_gpu) && s[GPU]="$g" ;;
            12)
                if [[ -z ${s[DISK]} || -z ${s[LANGUAGE]} || -z ${s[REGION]} || -z ${s[USER]} ]]; then
                    ui_msg "Заполните обязательные параметры!"; continue
                fi
                if ((${#PARTITION_MOUNT[@]} == 0)); then
                    ui_msg "Настройте монтирование разделов!"; continue
                fi
                local has_root=0
                for mp in "${PARTITION_MOUNT[@]}"; do
                    [[ $mp == "/" ]] && has_root=1
                done
                ((has_root)) || { ui_msg "Не выбран корневой раздел (/)!"; continue; }
                if run_manual_installation s; then
                    KEEP_MOUNTS=1
                    umount -R /mnt 2>/dev/null || true
                    read -rp "Нажмите Enter для перезагрузки..." _
                    reboot
                fi
                return 0 ;;
        esac
    done
}

# ------------------------------ Main ---------------------------------------
main() {
    require_root
    setup_logging
    check_dependencies
    cleanup_mounts || true
    configure_archiso_pacman || true

    while true; do
        local choice
        choice=$(ui_main_menu) || { ui_msg "Выход из установщика."; exit 0; }
        case $choice in
            1) auto_install_flow ;;
            2) auto_install_side_flow ;;
            3) manual_install_flow ;;
            4) sort_mirrors; ui_pause ;;
        esac
    done
}

main "$@"