#!/usr/bin/env bash
# reproduce-all.sh — host-side driver: build the auto-os/starry docker image
# (if needed), then run the in-container reproduction script.
#
# After this script the user has:
#   - tgoskits/target/.../release/starryos      (kernel ELF, freshly built)
#   - tests/selfhost/rootfs-selfhost-rust-riscv64.img  (M5 demo rootfs)
#   - .guest-runs/riscv64-m5/results.txt        (M5 demo guest serial log)
#   - if --m6 is passed: tests/selfhost/rootfs-selfbuild-riscv64.img and a
#     guest log for the in-guest selfbuild attempt as well.
#
# Host requirements: docker only. Everything else is in the image.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$ROOT"

IMAGE="${IMAGE:-auto-os/starry}"
WITH_M6=0
SKIP_BUILD=0
for arg in "$@"; do
    case "$arg" in
        --m6)         WITH_M6=1 ;;
        --skip-build) SKIP_BUILD=1 ;;
        --image=*)    IMAGE="${arg#--image=}" ;;
        --help|-h)
            sed -n '1,18p' "$0" ; exit 0 ;;
        *) echo "unknown arg: $arg" >&2; exit 2 ;;
    esac
done

log() { printf '\n\033[1;36m[%s]\033[0m %s\n' "$(date +%H:%M:%S)" "$*"; }
fatal() { printf '\033[1;31mFATAL:\033[0m %s\n' "$*" >&2; exit 1; }

# Pick `docker` or `sudo docker`
DOCKER="docker"
if ! docker info >/dev/null 2>&1; then
    if sudo -n docker info >/dev/null 2>&1; then
        DOCKER="sudo docker"
    else
        fatal "cannot reach docker daemon. Run 'sudo bash scripts/setup-env.sh' first."
    fi
fi

# ---------------------------------------------- step 1: image
if (( ! SKIP_BUILD )); then
    log "step 1/3  build docker image '$IMAGE' (skips if already built; ~3-5 min first time)"
    $DOCKER build --network host -t "$IMAGE" -f "$ROOT/Dockerfile" "$ROOT"
fi
log "image ready: $($DOCKER images "$IMAGE" --format '{{.ID}} {{.Size}}')"

# ---------------------------------------------- step 2: submodule
log "step 2/3  init tgoskits submodule (yks23/tgoskits selfhost-m5 + F-eps)"
git submodule update --init tgoskits

# ---------------------------------------------- step 3: run inside container
log "step 3/3  enter container, run reproduce-in-container.sh"
EXTRA=""
(( WITH_M6 )) && EXTRA="--m6"

$DOCKER run --rm --privileged --network host \
    -v "$ROOT:/work" -w /work \
    "$IMAGE" \
    bash scripts/reproduce-in-container.sh $EXTRA

log "done. See:"
echo "    .guest-runs/riscv64-m5/results.txt   (M5: cargo build hello world inside starry)"
if (( WITH_M6 )); then
    echo "    .guest-runs/riscv64-m6/results.txt   (M6: starry sources + nightly toolchain inside starry guest)"
fi
exit 0
