#!/data/data/xeffyr.alpine.term/files/environment/bin/libbash.so
##
##  QEMU Launcher.
##
##  Leonid Plyushch <leonid.plyushch@gmail.com> (C) 2018-2019
##
##  This program is free software: you can redistribute it and/or modify
##  it under the terms of the GNU General Public License as published by
##  the Free Software Foundation, either version 3 of the License, or
##  (at your option) any later version.
##
##  This program is distributed in the hope that it will be useful,
##  but WITHOUT ANY WARRANTY; without even the implied warranty of
##  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
##  GNU General Public License for more details.
##
##  You should have received a copy of the GNU General Public License
##  along with this program.  If not, see <http://www.gnu.org/licenses/>.
##

# All files that will be created by launcher or child processes should
# have private-only access.
umask 0077

# Ignore signals QUIT, INT, TERM.
trap '' QUIT INT TERM

# Exit with error on non-declared variable.
set -o nounset

##############################################################################
##
##  GLOBAL ENVIRONMENT VARIABLES
##
##  These variables should be read-only.
##
##############################################################################

# A path to root directory of the environment.
# Note: This variable can be overridden by client application.
: "${PREFIX:=/data/data/xeffyr.alpine.term/files/environment}"
readonly PREFIX
export PREFIX

# A path to home directory.
# Note: This variable can be overridden by client application.
: "${HOME:=/data/data/xeffyr.alpine.term/files}"
readonly HOME
export HOME

# Path to directory. where temporary files will be stored.
# Note: This variable can be overridden by client application.
: "${TMPDIR:=/data/data/xeffyr.alpine.term/files/environment/tmp}"
readonly TMPDIR
export TMPDIR

# A path to Android's shared storage.
# Note: This variable can be overridden by client application.
: "${EXTERNAL_STORAGE:=/storage/emulated/0}"
readonly EXTERNAL_STORAGE

# A path to OS image.
declare -r OS_IMAGE_PATH="${PREFIX}/os_image.qcow2"

# A SHA-256 checksum for the OS image.
declare -r OS_IMAGE_SHA256="e9bd8d310c2be55ced4c75e374cbe5ca9665ebd1a0b0547276bcbe74e71141b4"

# A path to the persistent CD-ROM image.
declare -r OS_CDROM_PATH="${PREFIX}/os_cdrom.iso"

# A SHA-256 checksum for the OS CD-ROM image.
declare -r OS_CDROM_SHA256="98e2eb7cfe74ede72d99cfd574a3c5e85a9aca5743d786abc9bbe7e0923f211b"

# A path to QEMU's pid file.
declare -r QEMU_PIDFILE_PATH="${TMPDIR}/qemu_running.pid"

##############################################################################
##
##  CONFIGURATION ENVIRONMENT VARIABLES
##
##  These variables should be set by client application. Default values
##  are the same, as configured in client application.
##
##############################################################################

# A maximal amount of RAM (in megabytes) that should be available for QEMU.
: "${CONFIG_QEMU_RAM:=256}"

# A path to snapshot image. All user changes will be written to it if
# persistent mode was used.
: "${CONFIG_QEMU_HDD1_PATH:=/storage/emulated/0/.alpine-term-snapshot.qcow2}"

# A path to secondary HDD image. Completely managed by user.
: "${CONFIG_QEMU_HDD2_PATH:=}"

# A path to the CD-ROM image. Completely managed by user.
: "${CONFIG_QEMU_CDROM_PATH:=}"

# An IP address of upstream DNS server. Actually this variable is used
# only for storing value. The value used by QEMU is stored in
# file ${PREFIX}/etc/resolv.conf.
: "${CONFIG_QEMU_DNS:=1.1.1.1}"

# A set of rules for port forwarding.
: "${CONFIG_QEMU_EXPOSED_PORTS:=}"

##############################################################################
##
##  COMMON FUNCTIONS
##
##############################################################################

# Blocks user input. Use this when progress/information message
# should be displayed. Terminal can be unblocked by either
# 'unblock_terminal' function or by command 'tput reset'.
block_terminal() {
    libbusybox.so stty -echo -icanon time 0 min 0
}

# Consume all unwanted input captured and unblock terminal. Use this
# after 'block_terminal'.
unblock_terminal() {
    while read -r; do
        true;
    done
    libbusybox.so stty sane
}

# Same as 'echo' but text will be wrapped according to current terminal
# width. Slower than 'echo'.
msg() {
    local text_width

    if [[ $(libtput.so cols) -gt 70 ]]; then
        text_width="70"
    else
        text_width=$(libtput.so cols)
    fi

    echo "${@}" | libbusybox.so fold -s -w "${text_width}"
}

gen_hostfwd_rules() {
    local hostfwd_rules=""
    local used_tcp_external_ports=""
    local used_udp_external_ports=""
    local proto internal external

    if [ -n "${CONFIG_QEMU_EXPOSED_PORTS}" ]; then
        for rule in ${CONFIG_QEMU_EXPOSED_PORTS//,/ }; do
            proto=$(echo "${rule}" | libbusybox.so cut -d: -f1)
            external=$(echo "${rule}" | libbusybox.so cut -d: -f2)
            internal=$(echo "${rule}" | libbusybox.so cut -d: -f3)

            if [ "${proto}" = "tcp" ]; then
                if ! libbusybox.so grep -q "${external}" <(echo "${used_tcp_external_ports}"); then
                    used_tcp_external_ports+=" ${external}"

                    if ! (echo >"/dev/tcp/127.0.0.1/${external}") &>/dev/null; then
                        hostfwd_rules+="hostfwd=tcp::${external}-:${internal},"
                    else
                        echo "[!] Port forwarding: external TCP port '${external}' already in use." 1>&2
                    fi
                fi
            elif [ "${proto}" = "udp" ]; then
                if ! libbusybox.so grep -q "${external}" <(echo "${used_udp_external_ports}"); then
                    used_udp_external_ports+=" ${external}"
                    hostfwd_rules+="hostfwd=udp::${external}-:${internal},"
                fi
            else
                ## Invalid proto. This shouldn't happen.
                echo "[!] Rule error: invalid proto '${proto}' specified in '${rule}'." 1>&2
            fi
        done

        echo "${hostfwd_rules%%,}"
    else
        echo
    fi
}

##############################################################################
##
##  SESSION FUNCTIONS
##
##############################################################################

# Starts QEMU (main) session. Kills other sessions on exit.
qemu_session() {
    local QEMU_SANDBOX_MODE=false
    block_terminal

    if [ "${#}" -ge 1 ]; then
        if [ "${1}" = "sandbox-mode" ]; then
            QEMU_SANDBOX_MODE=true
        else
            msg
            msg "[BUG]: qemu_session() received unknown argument '${1}'."
            msg
            unblock_terminal

            libbusybox.so stty sane
            read -rs -p "Press enter to exit..."
            exec libbash.so -c "libbusybox.so killall -9 libbash.so; exit 1" > /dev/null 2>&1
        fi
    fi

    # Verify integrity of the OS images before QEMU will start.
    msg
    msg -n "Verifying OS CD-ROM image... "
    CURRENT_SHA256=$(libopenssl.so dgst -sha256 "${OS_CDROM_PATH}" | libbusybox.so cut -d' ' -f2)
    if [ "${CURRENT_SHA256}" = "${OS_CDROM_SHA256}" ]; then
        msg "OK"
        unset CURRENT_SHA256
    else
        msg "FAIL"
        msg
        msg "[BUG]: OS CD-ROM image is corrupted."
        msg
        msg "You need to erase application's data via Android settings to be able to re-install a sane environment."
        msg
        unblock_terminal

        libbusybox.so stty sane
        read -rs -p "Press enter to exit..."
        exec libbash.so -c "libbusybox.so killall -9 libsocat.so; libbusybox.so killall -9 libbash.so; exit 1" > /dev/null 2>&1
    fi
    msg -n "Verifying OS HDD image... "
    CURRENT_SHA256=$(libopenssl.so dgst -sha256 "${OS_IMAGE_PATH}" | libbusybox.so cut -d' ' -f2)
    if [ "${CURRENT_SHA256}" = "${OS_IMAGE_SHA256}" ]; then
        msg "OK"
        unset CURRENT_SHA256
    else
        msg "FAIL"
        msg
        msg "[BUG]: Base OS image is corrupted."
        msg
        msg "You need to erase application's data via Android settings to be able to re-install a sane environment."
        msg
        unblock_terminal

        libbusybox.so stty sane
        read -rs -p "Press enter to exit..."
        exec libbash.so -c "libbusybox.so killall -9 libsocat.so; libbusybox.so killall -9 libbash.so; exit 1" > /dev/null 2>&1
    fi

    # Create snapshot image if needed. Use in-memory snapshot
    # if failed to create persistent image.
    if [ ! -s "${CONFIG_QEMU_HDD1_PATH}" ]; then
        msg -n "Creating snapshot image... "
        if libqemu-img.so create -f qcow2 -b "${OS_IMAGE_PATH}" "${CONFIG_QEMU_HDD1_PATH}" > /dev/null 2>&1; then
            msg "OK"
        else
            msg "FAIL"
            msg
            msg "Cannot create snapshot image. Your changes won't be persistent !"
            msg
            CONFIG_QEMU_HDD1_PATH="${OS_IMAGE_PATH}"
            QEMU_SANDBOX_MODE=true
        fi
    fi

    # Set pid file path.
    set -- "-pidfile" "${QEMU_PIDFILE_PATH}"

    # Set bigger than default buffer size for TCG.
    set -- "${@}" "-tb-size" "128"

    # Emulate CPU with all supported extensions.
    set -- "${@}" "-cpu" "max"

    # Set amount of RAM.
    set -- "${@}" "-m" "${CONFIG_QEMU_RAM}M"

    # Do not create default devices.
    set -- "${@}" "-nodefaults"

    # Setup primary CD-ROM (with OS live image).
    set -- "${@}" "-drive" "file=${OS_CDROM_PATH},index=0,media=cdrom,if=ide"

    # Setup secondary CD-ROM if requested.
    if [ -n "${CONFIG_QEMU_CDROM_PATH}" ]; then
        set -- "${@}" "-drive" "file=${CONFIG_QEMU_CDROM_PATH},index=1,media=cdrom,if=ide"
    fi

    # Setup primary hard drive image (with the main OS installation).
    set -- "${@}" "-device" "virtio-scsi-pci"
    set -- "${@}" "-drive" "file=${CONFIG_QEMU_HDD1_PATH},if=none,discard=unmap,cache=none,id=hd0"
    set -- "${@}" "-device" "scsi-hd,drive=hd0"

    # Setup secondary hard drive image if requested.
    if [ -n "${CONFIG_QEMU_HDD2_PATH}" ]; then
        set -- "${@}" "-drive" "file=${CONFIG_QEMU_HDD2_PATH},if=none,discard=unmap,cache=none,id=hd1"
        set -- "${@}" "-device" "scsi-hd,drive=hd1"
    fi

    # Allow to select boot device.
    set -- "${@}" "-boot" "c,menu=on"

    # If sandbox mode is used, then QEMU will not write user's
    # changes to disk image.
    if ${QEMU_SANDBOX_MODE}; then
        set -- "${@}" "-snapshot"
        echo -ne "\\e]0;Sandbox/snapshot mode activated\\a"
    fi

    # Use virtio RNG. Provides a faster RNG for the guest OS.
    set -- "${@}" "-object" "rng-random,filename=/dev/urandom,id=rng0"
    set -- "${@}" "-device" "virtio-rng-pci,rng=rng0"

    # Setup networking.
    set -- "${@}" "-netdev" "user,id=vmnic,$(gen_hostfwd_rules)"
    set -- "${@}" "-device" "virtio-net,netdev=vmnic"

    # Make Android's rootfs available over 9P if possible.
    if [ -r "/" ]; then
        set -- "${@}" "-fsdev" "local,security_model=none,id=fsdev0,path=/"
        set -- "${@}" "-device" "virtio-9p-pci,id=fs0,fsdev=fsdev0,mount_tag=android_root"
    else
        msg "Warning: root directory is not readable. 9P device 'android_root' will be unavailable in the VM."
    fi

    # Make Android's shared storage available over 9P if possible.
    if [ -w "${EXTERNAL_STORAGE}" ]; then
        set -- "${@}" "-fsdev" "local,security_model=none,id=fsdev1,path=${EXTERNAL_STORAGE}"
        set -- "${@}" "-device" "virtio-9p-pci,id=fs1,fsdev=fsdev1,mount_tag=android_storage"
    else
        msg "Warning: external storage directory is not writable. 9P device 'android_storage' will be unavailable in the VM."
    fi

    # Disable graphical output.
    set -- "${@}" "-vga" "none"
    set -- "${@}" "-nographic"

    # Monitor.
    set -- "${@}" "-chardev" "tty,id=monitor0,mux=off,path=$(libbusybox.so tty)"
    set -- "${@}" "-monitor" "chardev:monitor0"

    # Setup serial console output.
    for i in {0..3}; do
        set -- "${@}" "-chardev" "socket,id=console${i},path=${TMPDIR}/serial${i}.sock"
        set -- "${@}" "-serial" "chardev:console${i}"
    done
    unset i

    # Disable parallel port.
    set -- "${@}" "-parallel" "none"

    msg
    echo -ne "\\a"
    unblock_terminal

    libqemu.so "${@}"
    qemu_ret="${?}"

    if [ ${qemu_ret} -ne 0 ]; then
        msg
        libbusybox.so stty sane
        read -rs -p "Press enter to exit..."
    fi

    exec libbash.so -c "libbusybox.so killall -9 libsocat.so; libbusybox.so killall -9 libbash.so; exit ${qemu_ret}" > /dev/null 2>&1
}

# Handle connections to serial consoles (ttyS0-3).
serial_console_session() {
    if [ "${#}" -lt 1 ]; then
        msg
        msg "[BUG] Session number is not specified."
        msg
        libbusybox.so stty sane
        read -rs -p "Press enter to exit..."
        exec libbash.so -c "libbusybox.so killall -9 libsocat.so; libbusybox.so killall -9 libbash.so; exit 1" > /dev/null 2>&1
    fi

    exec libbusybox.so flock -n "${TMPDIR}/serial${1}.lck" libsocat.so "$(libbusybox.so tty)",rawer "UNIX-LISTEN:${TMPDIR}/serial${1}.sock,unlink-early"
}

##############################################################################

# Ensure that following files and directories are read-writable.
libbusybox.so chmod 600 "${PREFIX}/etc/resolv.conf" || true
libbusybox.so chmod 700 "${PREFIX}/tmp" > /dev/null 2>&1 || true

# Update DNS in resolv.conf file.
echo "nameserver ${CONFIG_QEMU_DNS}" > "${PREFIX}/etc/resolv.conf"

if [ "${#}" -gt 0 ]; then
    # $1 specifies session type. For available values, see client
    # application sources.
    if [ "${1}" = 0 ]; then
        qemu_session
    elif [ "${1}" = 1 ]; then
        qemu_session sandbox-mode
    elif [ "${1}" = 2 ]; then
        serial_console_session "${SERIAL_CONSOLE_NUMBER}"
    else
        # This should never happen.
        msg
        msg "[BUG]: Got unknown session type '${1}'."
        msg
        libbusybox.so stty sane
        read -rs -p "Press enter to exit..."
        exit 1
    fi
else
    # This should never happen.
    msg
    msg "[BUG]: No session type specified."
    msg
    libbusybox.so stty sane
    read -rs -p "Press enter to exit..."
    exit 1
fi
