# === kernel building ===

function set-build
    set -g BUILD_FOLDER "$argv"
    abbr -a mk make CC=\"ccache gcc -fdiagnostics-color\" -j(nproc) O=$BUILD_FOLDER
    abbr -a menu make menuconfig -j O=$BUILD_FOLDER

    function local-install
        default_set KNAME $argv[1] $BUILD_FOLDER
        echorun make CC=\"ccache gcc-11 -fdiagnostics-color\" -j(nproc) O=$BUILD_FOLDER
        echorun sudo make -j(nproc) O=$BUILD_FOLDER INSTALL_HDR_PATH=/usr headers_install modules_install
        if test ! (uname -r | grep -q aarch64)
            echorun sudo cp -v $BUILD_FOLDER/arch/x86_64/boot/bzImage /boot/vmlinuz-$KNAME
            echorun sudo mkinitcpio -P
            echorun sudo grub-mkconfig -o /boot/grub/grub.cfg
        end
    end

    function clean-output
        default_set INPUT_FILE $argv[1] 'modules1'
        default_set SEARCH $argv[2] 'gpu.*amd'
        default_set FILE $argv[3]/$INPUT_FILE $BUILD_FOLDER/$INPUT_FILE

        # clear possible CLI menuconfig output
        set LAST_LINE (grep -nm2 'GEN\s*Makefile' $FILE".log" | tail -n1 | cut -d: -f1)
        sed -e "1,"$LAST_LINE"d" $FILE".log" | grep -v '^\s\s[A-Z]' |\
            grep -B1 -A5 $SEARCH > $FILE".clean.log"
    end

    function error-count
        default_set INPUT_FILE $argv[1] 'modules1'
        default_set SEARCH $argv[2] 'gpu.*amd'
        default_set FILE $argv[3]/$INPUT_FILE $BUILD_FOLDER/$INPUT_FILE

        # clear possible CLI menuconfig output
        set LAST_LINE (grep -nm2 'GEN\s*Makefile' $FILE".log" | tail -n1 | cut -d: -f1)
        sed -e "1,"$LAST_LINE"d" $FILE".log" | grep -v '^\s\s[A-Z]' |\
            grep $SEARCH | wc -l
    end
end

function set-arch
    set -g ARCH "$argv"
    set-build "$argv-build"

    if test (uname -r | grep -q aarch64)
        abbr -a mcr COMPILER_INSTALL_PATH='$HOME'/x-tools/x86_64-unknown-linux-gnu/bin/x86_64-unknown-linux-gnu- make ARCH=x86_64 O=$BUILD_FOLDER -j(nproc)
    else
        abbr -a mcr COMPILER_INSTALL_PATH='$HOME'/0day COMPILER=gcc-11.2.0 make.cross ARCH=$ARCH O=$BUILD_FOLDER -j(nproc)
    end
end

# === vm management ===

function vm-install-mods
    set img_name "$argv[1].qcow2"
    set MNT_FOLDER "$VM_PATH/mnt"
    mountpoint "$MNT_FOLDER" || echorun sudo mount "$VM_PATH/$img_name" "$MNT_FOLDER"

    wait_for_mount "$MNT_FOLDER"

    pwd | grep -q 'linux$' || echo "entering directory '$HOME/shared/linux'" && pushd "$HOME"/shared/linux

    echorun sudo make -j8 O="$BUILD_FOLDER" \
        INSTALL_HDR_PATH="$MNT_FOLDER"/usr INSTALL_MOD_PATH="$MNT_FOLDER" \
        headers_install modules_install

    dirs > /dev/null && echo "leaving directory '"(pwd)"'" && popd

    echorun sudo umount $MNT_FOLDER
end

abbr -a qxa qemu_x86_64

function qemu_x86_64
    set img_name $argv[1]
    set extension ""
    set format ""
    echo "$img_name" | cut -d'.' -f 2 | grep -q img
    if test "$status"
        set format ,format=raw
    else
        set extension .qcow2
    end
    default_set mem_amount $argv[2] 4G
    if test $IS_MAC = true
        set cpuvar qemu64
    else
        set cpuvar host
    end

    if test -n "$BUILD_FOLDER"
        qemu-system-x86_64 \
            -boot order=a -drive file="$VM_PATH/$img_name$extension"$format,if=virtio \
            -kernel "$LINUX_SRC_PATH/$BUILD_FOLDER"/arch/x86_64/boot/bzImage \
            -append "root=/dev/vda rw console=ttyS0 nokaslr loglevel=7 raid=noautodetect audit=0 cpuidle_haltpoll.force=1" \
            # -fsdev local,id=fs1,path=$HOME/shared,security_model=none \
            # -device virtio-9p-pci,fsdev=fs1,mount_tag=$HOME/shared
            -m "$mem_amount" -smp 4 -cpu "$cpuvar" \
            -nic user,hostfwd=tcp::2222-:22,smb="$HOME"/shared -s \
            -nographic
    else
        qemu-system-x86_64 \
            -accel tcg -m "$mem_amount" -smp 4 -cpu "$cpuvar" \
            -nic user,hostfwd=tcp::2222-:22,smb="$HOME"/shared -s \
            -boot order=a -drive file="$VM_PATH/$img_name$extension"$format,if=virtio
    end

end

abbr -a qaa qemu_aarch64

function qemu_aarch64
    set img_name "$argv[1].qcow2"
    default_set mem_amount $argv[2] 4G

    if test $IS_MAC = true
        default_set cpuvar $argv[3] host
        set accelvar ",accel=hvf"
    else
        default_set cpuvar $argv[3] cortex-a72
    end

    eval qemu-system-aarch64 -L ~/bin/qemu/share/qemu \
         -machine virt"$accelvar" \
         -cpu "$cpuvar" -smp 8 -m "$mem_amount" \
         "-drive if=pflash,media=disk,file=$HOME/vms/setup/UEFI/flash"{"0.img,id=drive0","1.img,id=drive1"}",cache=writethrough,format=raw" \
         -drive if=none,file="$VM_PATH/$img_name",format=qcow2,id=hd0 \
         # -virtfs local,mount_tag=fs1,path=$HOME/shared,security_model=none \
         -device virtio-scsi-pci,id=scsi0 \
         -device scsi-hd,bus=scsi0.0,drive=hd0,bootindex=1 \
         -nic user,model=virtio-net-pci,hostfwd=tcp::2222-:22,smb="$HOME"/shared \
         '-device virtio-'{rng,balloon,keyboard,mouse,serial,tablet}-device \
         -object cryptodev-backend-builtin,id=cryptodev0 \
         -device virtio-crypto-pci,id=crypto0,cryptodev=cryptodev0 \
         -nographic
end

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

# TODO move this to proper script
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
