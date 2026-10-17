#!/bin/bash
set -Eeuo pipefail

export PATH=/usr/sbin:/usr/bin:/sbin:/bin
SELF=$(readlink -f -- "$0")

# Processus enfant : rejoint le cgroup avant de créer les namespaces.
if [[ "${1:-}" == "--child" ]]; then
    ROOTFS=$2
    CG=$3
    STATE=$4

    echo "$$" > "$CG/cgroup.procs"

    exec unshare \
        --mount --propagation private \
        --pid --fork --kill-child \
        --net --uts --ipc \
        /bin/bash "$SELF" --inside "$ROOTFS" "$STATE"
fi

# Cette branche s'exécute dans les nouveaux namespaces.
if [[ "${1:-}" == "--inside" ]]; then
    ROOTFS=$2
    STATE=$3

    read -r HOST_PID _ < /proc/self/stat
    printf '%s\n' "$HOST_PID" > "$STATE/child.pid"

    for ((i = 0; i < 100; i++)); do
        [[ -e "$STATE/net.ready" ]] && break
        sleep 0.1
    done

    if [[ ! -e "$STATE/net.ready" ]]; then
        echo "Délai dépassé : réseau non configuré." >&2
        exit 1
    fi

    hostname mini-conteneur

    mount -t proc -o nosuid,nodev,noexec proc "$ROOTFS/proc"

    mount -t tmpfs \
        -o nosuid,noexec,mode=755,size=4m \
        tmpfs "$ROOTFS/dev"

    mknod -m 666 "$ROOTFS/dev/null"    c 1 3
    mknod -m 666 "$ROOTFS/dev/zero"    c 1 5
    mknod -m 666 "$ROOTFS/dev/random"  c 1 8
    mknod -m 666 "$ROOTFS/dev/urandom" c 1 9
    mknod -m 666 "$ROOTFS/dev/tty"     c 5 0

    mount -t tmpfs \
        -o nosuid,nodev,mode=1777,size=32m \
        tmpfs "$ROOTFS/tmp"

    exec env -i \
        PATH=/usr/sbin:/usr/bin:/sbin:/bin \
        HOME=/ \
        TERM="${TERM:-xterm}" \
        PS1='mini-conteneur:\w# ' \
        chroot "$ROOTFS" /bin/bash --noprofile --norc -i
fi

# À partir d'ici : superviseur côté hôte.
STATE=""
MERGED=""
CG=""
CG_CREATED=0
HELPER=""
NET_CREATED=0
VETH_HOST=""
VETH_PEER=""

cleanup() {
    local i
    set +e

    echo
    echo "[cleanup] Nettoyage..."

    if [[ -n "$HELPER" ]]; then
        kill "$HELPER" 2>/dev/null
        wait "$HELPER" 2>/dev/null
    fi

    if (( CG_CREATED )); then
        echo "[cleanup] Événements mémoire avant nettoyage :"
        cat "$CG/memory.events"

        echo 1 > "$CG/cgroup.kill"

        for ((i = 0; i < 50; i++)); do
            if rmdir "$CG" 2>/dev/null; then
                CG_CREATED=0
                break
            fi
            sleep 0.1
        done
    fi

    if (( NET_CREATED )) && ip link show "$VETH_HOST" &>/dev/null; then
        if ! ip link delete "$VETH_HOST"; then
            echo "[cleanup] Interface non supprimée : $VETH_HOST" >&2
            echo "[cleanup] Dossier conservé : $STATE" >&2
            return
        fi
    fi

    if [[ -n "$MERGED" ]] && mountpoint -q "$MERGED"; then
        if ! umount "$MERGED"; then
            echo "[cleanup] Échec du démontage : $MERGED" >&2
            echo "[cleanup] Dossier conservé : $STATE" >&2
            return
        fi
    fi

    if (( CG_CREATED )); then
        echo "[cleanup] Cgroup non supprimé : $CG" >&2
        echo "[cleanup] Dossier conservé : $STATE" >&2
        return
    fi

    if [[ -n "$STATE" ]]; then
        rm -rf -- "$STATE"
    fi

    echo "[cleanup] Terminé."
}

trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP

if (( EUID != 0 )); then
    echo "Utilisation : sudo $0 /chemin/vers/mini-root" >&2
    exit 1
fi

if [[ $# -ne 1 ]]; then
    echo "Utilisation : sudo $0 /chemin/vers/mini-root" >&2
    exit 1
fi

BASE=$(realpath -- "$1")

if [[ ! -x "$BASE/bin/bash" ]]; then
    echo "Bash absent de la racine : $BASE/bin/bash" >&2
    exit 1
fi

for dossier in proc dev tmp; do
    if [[ ! -d "$BASE/$dossier" ]]; then
        echo "Dossier manquant : $BASE/$dossier" >&2
        exit 1
    fi
done

STATE=$(mktemp -d /var/tmp/mini-docker.XXXXXX)
MERGED="$STATE/merged"
CG="/sys/fs/cgroup/mini-docker-$$"

mkdir "$STATE/upper" "$STATE/work" "$MERGED"

mkdir "$CG"
CG_CREATED=1

echo 104857600 > "$CG/memory.max"
echo 0 > "$CG/memory.swap.max"
echo 1 > "$CG/memory.oom.group"

mount -t overlay overlay \
    -o "lowerdir=$BASE,upperdir=$STATE/upper,workdir=$STATE/work" \
    "$MERGED"

VETH_HOST="mdh$$"
VETH_PEER="mdc$$"

ip link add "$VETH_HOST" type veth peer name "$VETH_PEER"
NET_CREATED=1

ip addr add 192.168.250.1/30 dev "$VETH_HOST"
ip link set "$VETH_HOST" up

configure_network() {
    local host_pid
    local i

    for ((i = 0; i < 100; i++)); do
        [[ -s "$STATE/child.pid" ]] && break
        sleep 0.1
    done

    [[ -s "$STATE/child.pid" ]] || return 1
    read -r host_pid < "$STATE/child.pid" || return 1

    ip link set "$VETH_PEER" netns "$host_pid" || return 1

    nsenter -t "$host_pid" -n \
        ip addr add 192.168.250.2/30 dev "$VETH_PEER" || return 1

    nsenter -t "$host_pid" -n \
        ip link set "$VETH_PEER" up || return 1

    nsenter -t "$host_pid" -n \
        ip link set lo up || return 1

    : > "$STATE/net.ready"
}

(
    trap - EXIT INT TERM HUP

    if ! configure_network; then
        echo "[host] Échec de la configuration réseau." >&2
        echo 1 > "$CG/cgroup.kill"
        exit 1
    fi
) &
HELPER=$!

echo "[host] Cgroup : $CG"
echo "[host] Racine fusionnée : $MERGED"
echo "[host] Interface hôte : $VETH_HOST"
echo "[host] Réseau : 192.168.250.1 <-> 192.168.250.2"
echo "[host] Tape exit pour arrêter le conteneur."

/bin/bash "$SELF" --child "$MERGED" "$CG" "$STATE"

wait "$HELPER"
HELPER=""


