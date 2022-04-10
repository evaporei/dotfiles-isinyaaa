#!/usr/bin/fish
# === kernel building ===

function set-build
    set -g BUILD_FOLDER "$argv"
end

#find $LINUX_SRC_PATH/*_build -maxdepth 0 | head -n1

abbr -a mk 'make CC="ccache gcc -fdiagnostics-color" -j8 O=$BUILD_FOLDER'
#abbr -a mmd 'make modules CC="ccache gcc -fdiagnostics-color" -j8 O=$BUILD_FOLDER'
abbr -a gg 'git grep'
abbr -a glg 'git log --grep='
alias gitline='git log --oneline --graph'

function ggb -d "git grep + git blame"
    command git grep -En $argv[1] | while read --delimiter=: -l file line code
        git blame -f -L $line,$line $file | grep -E --color "$argv[1]|\$"
    end
end

function clean-output
    default_set INPUT_FILE $argv[1] 'modules1'
    default_set SEARCH $argv[2] 'gpu.*amd'

    if not set -q BUILD_FOLDER; and not set -q argv[3]
        return 2
    end

    default_set IO_PATH $argv[3] "$BUILD_FOLDER"

    set FILE $IO_PATH/$INPUT_FILE

    # clear possible CLI menuconfig output
    set LAST_LINE (grep -nm2 'GEN\s*Makefile' $FILE".log" | tail -n1 | cut -d: -f1)
    sed -e "1,"$LAST_LINE"d" $FILE".log" | grep -v '^\s\s[A-Z]' |\
        grep -B1 -A5 $SEARCH > $FILE".clean.log"
end

function error-count
    default_set INPUT_FILE $argv[1] 'modules1'
    default_set SEARCH $argv[2] 'gpu.*amd'

    if not set -q BUILD_FOLDER; and not set -q argv[3]
        return 2
    end

    default_set IO_PATH $argv[3] "$BUILD_FOLDER"

    set FILE $IO_PATH/$INPUT_FILE

    # clear possible CLI menuconfig output
    set LAST_LINE (grep -nm2 'GEN\s*Makefile' $FILE".log" | tail -n1 | cut -d: -f1)
    sed -e "1,"$LAST_LINE"d" $FILE".log" | grep -v '^\s\s[A-Z]' |\
        grep $SEARCH | wc -l
end

function set-arch
    set -g ARCH "$argv"
    set -g ARCH_BUILD "$argv-build"
end

abbr -a mcr 'COMPILER_INSTALL_PATH=$HOME/0day COMPILER=gcc-11.2.0 make.cross -j4 ARCH=$ARCH O=$ARCH_BUILD'
abbr -a menu 'make menuconfig -j O=$BUILD_FOLDER'

# === vm management ===

function install-mods
    set img_name $argv[1]
    set MNT_FOLDER "$IMG_PATH/mnt"
    mountpoint "$MNT_FOLDER" || echorun sudo mount "$img_name" "$MNT_FOLDER"

    wait_for_mount "$MNT_FOLDER"

    pwd | grep -q 'linux$' || echo "entering directory '$HOME/shared/linux'" && pushd "$HOME"/shared/linux

    echorun sudo make -j8 O="$BUILD_FOLDER" \
        INSTALL_HDR_PATH="$MNT_FOLDER"/usr INSTALL_MOD_PATH="$MNT_FOLDER" \
        headers_install modules_install

    dirs > /dev/null && echo "leaving directory '"(pwd)"'" && popd

    echorun sudo umount $MNT_FOLDER
end

abbr -a qx86a qemu_x86_64

function qemu_x86_64
    set img_name $argv[1]

    qemu-system-x86_64 \
        -boot order=a -drive file=$img_name,format=qcow2,if=virtio \
        -kernel "$LINUX_SRC_PATH/$BUILD_FOLDER"/arch/x86_64/boot/bzImage \
        -append 'root=/dev/vda rw console=ttyS0 nokaslr loglevel=7 raid=noautodetect audit=0 cpuidle_haltpoll.force=1' \
        -enable-kvm -m 4G -smp 4 -cpu host \
        -nic user,hostfwd=tcp::2222-:22,smb=$HOME/shared -s \
        -nographic
end

abbr -a qaa qemu_aarch64

function qemu_aarch64
    set img_name $argv[1]

    qemu-system-aarch64 -L ~/bin/qemu/share/qemu \
         -smp 8 \
         -machine virt,accel=hvf,highmem=off \
         -cpu cortex-a72 -m 4096 \
         -drive "if=pflash,media=disk,id=drive0,file=$HOME/vms/setup/UEFI/flash0.img,cache=writethrough,format=raw" \
         -drive "if=pflash,media=disk,id=drive1,file=$HOME/vms/setup/UEFI/flash1.img,cache=writethrough,format=raw" \
         -drive if=none,file="$HOME/vms/$img_name.qcow2",format=qcow2,id=hd0 \
         -device virtio-scsi-pci,id=scsi0 \
         -device scsi-hd,bus=scsi0.0,drive=hd0,bootindex=1 \
         -nic user,model=virtio-net-pci,hostfwd=tcp::2222-:22,smb="$HOME"/shared \
         -device virtio-rng-device -device virtio-balloon-device -device virtio-keyboard-device \
         -device virtio-mouse-device -device virtio-serial-device -device virtio-tablet-device \
         -object cryptodev-backend-builtin,id=cryptodev0 \
         -device virtio-crypto-pci,id=crypto0,cryptodev=cryptodev0 \
         -nographic
end

#-fsdev local,id=fs1,path=/home/tonyk/codes,security_model=none \
#-device virtio-9p-pci,fsdev=fs1,mount_tag=$HOME/shared \

function default_set --no-scope-shadowing
    if set -q argv[2]
        set $argv[1] $argv[2]
    else
        set $argv[1] $argv[3]
    end
end

function echorun
    if test $argv[1] = '-e'
        echo "\$ $argv[2..-1]" >&2
        eval $argv[2..-1]
    else
        echo "\$ $argv"
        eval $argv
    end
end

function wait_for_mount
    default_set MNT_FOLDER $argv[1] 'mnt'

    for i in (seq 100)
        sleep 1
        mountpoint $MNT_FOLDER > /dev/null && break
    end
end

function create-vm
    default_set disk_space $argv[1] '8G'
    default_set disk_name $argv[2] 'arch_disk'

    set extra_packs "vim fish git rustup strace gdb dhcpcd openssh cifs-utils samba"
    #set xforwarding_packs 'xorg-xauth xorg-xclock xorg-fonts-type1'

    set all_packs "$extra_packs"

    echorun truncate -s "$disk_space" "$disk_name.img"
    test $status != 0 && return 1
    echorun mkfs.ext4 $disk_name
    test $status != 0 && return 1

    test -d mnt || echorun mkdir mnt
    echorun sudo mount "$disk_name" mnt
    test $status != 0 && echorun sudo umount mnt && return 1

    wait_for_mount

    echorun sudo pacstrap -c mnt base base-devel "$all_packs"
    test $status != 0 && echorun sudo umount mnt && return 1

    # configure ssh
    echorun sudo cp ~/.ssh/id_rsa.pub mnt/root/
    test $status != 0 && echorun sudo umount mnt && return 1

    # copy bootstrap script
    echorun sudo cp "$HOME"/scripts/start.sh mnt/root/
    echorun sudo cp "$HOME"/scripts/smb.conf mnt/root/
    test $status != 0 && echorun sudo umount mnt && return 1

    # remove root passwd
    sudo arch-chroot mnt/ sh -c "echo 'root:xx' | chpasswd"

    echorun sudo umount mnt

    echorun qemu-convert -O qcow2 "$disk_name.img" "$disk_name.qcow2"
end
