# shellcheck shell=bash
# 공통 헬퍼: 모든 스크립트가 source 해서 쓴다. 단독 실행용이 아니다.

if [[ -t 1 ]]; then
  C_RESET=$'\033[0m'; C_BLUE=$'\033[1;34m'; C_YELLOW=$'\033[1;33m'; C_RED=$'\033[1;31m'; C_GREEN=$'\033[1;32m'
else
  C_RESET=''; C_BLUE=''; C_YELLOW=''; C_RED=''; C_GREEN=''
fi

log()  { printf '%s==>%s %s\n' "$C_BLUE" "$C_RESET" "$*"; }
ok()   { printf '%s ✓ %s %s\n' "$C_GREEN" "$C_RESET" "$*"; }
warn() { printf '%s !! %s %s\n' "$C_YELLOW" "$C_RESET" "$*" >&2; }
die()  { printf '%s xx %s %s\n' "$C_RED" "$C_RESET" "$*" >&2; exit 1; }

require_root() {
  [[ $EUID -eq 0 ]] || die "root 권한이 필요합니다: sudo $0 ..."
}

is_jetson() { [[ -f /etc/nv_tegra_release ]]; }

require_jetson() {
  is_jetson || die "Jetson(L4T) 환경이 아닙니다 (/etc/nv_tegra_release 없음)."
}

# 예: "NVIDIA Jetson AGX Orin Developer Kit"
jetson_model() {
  if [[ -r /proc/device-tree/model ]]; then
    tr -d '\0' </proc/device-tree/model
  else
    echo "unknown"
  fi
}

# 예: "R36.4.3" (R35=JetPack 5, R36=JetPack 6, R38=JetPack 7)
l4t_release() {
  [[ -r /etc/nv_tegra_release ]] || { echo "unknown"; return; }
  sed -nE 's/^# (R[0-9]+) \(release\), REVISION: ([0-9.]+).*/\1.\2/p' /etc/nv_tegra_release
}

jetpack_version() {
  dpkg-query -W -f='${Version}' nvidia-jetpack 2>/dev/null || echo "not installed (meta-package)"
}

# 루트 파일시스템이 올라간 블록 장치 (nvme / mmcblk / sd)
root_device() { findmnt -n -o SOURCE / 2>/dev/null || echo "unknown"; }

# Ubuntu 버전 ID (예: 22.04)
ubuntu_version() { . /etc/os-release 2>/dev/null && echo "${VERSION_ID:-unknown}"; }

# 원본을 한 번만 백업해 두고 덮어쓴다 (재실행해도 최초 원본이 보존됨)
backup_once() {
  local f=$1
  [[ -e $f && ! -e $f.orig ]] && cp -a "$f" "$f.orig"
  return 0
}

# sudo 로 실행했을 때 실제 사람 계정
invoking_user() { echo "${SUDO_USER:-$USER}"; }
