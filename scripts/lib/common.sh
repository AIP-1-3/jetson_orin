# shellcheck shell=bash
# 공통 헬퍼: 모든 스크립트가 source 해서 쓴다. 단독 실행용이 아니다.

if [[ -t 1 ]]; then
  C_RESET=$'\033[0m'; C_BLUE=$'\033[1;34m'; C_YELLOW=$'\033[1;33m'; C_RED=$'\033[1;31m'; C_GREEN=$'\033[1;32m'
else
  C_RESET=''; C_BLUE=''; C_YELLOW=''; C_RED=''; C_GREEN=''
fi

log()  { printf '%s==>%s %s\n' "$C_BLUE" "$C_RESET" "$*"; }
# dry-run 중에는 "적용했다"로 읽히지 않게 표시를 붙인다
ok()   { printf '%s ✓ %s %s%s\n' "$C_GREEN" "$C_RESET" "$( [[ ${DRY_RUN:-0} == 1 ]] && echo '(dry-run) ')" "$*"; }
warn() { printf '%s !! %s %s\n' "$C_YELLOW" "$C_RESET" "$*" >&2; }
die()  { printf '%s xx %s %s\n' "$C_RED" "$C_RESET" "$*" >&2; exit 1; }

# JT_EUID 는 테스트용 재정의다. 실제 권한을 주지 않으므로 확인 메시지만 건너뛴다.
require_root() {
  [[ ${JT_EUID:-$EUID} -eq 0 ]] && return 0
  if [[ $DRY_RUN == 1 ]]; then
    warn "dry-run: root 가 아니어서 일부 확인은 건너뜁니다."
    return 0
  fi
  die "root 권한이 필요합니다: sudo $0 ..."
}

# 경로는 테스트에서 가짜 파일로 바꿀 수 있게 환경변수로 재정의 가능하게 둔다
NV_TEGRA_RELEASE=${NV_TEGRA_RELEASE:-/etc/nv_tegra_release}

is_jetson() { [[ -f $NV_TEGRA_RELEASE ]]; }

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
  [[ -r $NV_TEGRA_RELEASE ]] || { echo "unknown"; return; }
  sed -nE 's/^# (R[0-9]+) \(release\), REVISION: ([0-9.]+).*/\1.\2/p' "$NV_TEGRA_RELEASE"
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
  [[ -e $f && ! -e $f.orig ]] && run cp -a "$f" "$f.orig"
  return 0
}

# sudo 로 실행했을 때 실제 사람 계정
invoking_user() { echo "${SUDO_USER:-${USER:-$(id -un)}}"; }

# ---------------------------------------------------------------------------
# 안전장치: --dry-run, 실행 전 확인, 되돌리기 안내
# 장비는 원격에 있어 손으로 복구할 수 없다. 상태를 바꾸는 명령은 모두 run/write_file 을 거친다.
# ---------------------------------------------------------------------------
DRY_RUN=${DRY_RUN:-0}
ASSUME_YES=${ASSUME_YES:-0}
ROLLBACK_NOTES=()

# 호출하는 쪽이 ">/dev/null" 로 출력을 버려도 dry-run 안내는 보이도록 원래 stdout 을 fd 8 에 잡아 둔다
exec 8>&1

# 상태를 바꾸는 명령. --dry-run 이면 실행하지 않고 무엇을 할지만 보여 준다.
run() {
  if [[ $DRY_RUN == 1 ]]; then
    printf '%s[dry-run]%s %s\n' "$C_YELLOW" "$C_RESET" "$*" >&8
    return 0
  fi
  "$@"
}

# 표준입력을 파일에 쓴다 (heredoc 용). --append 면 덧붙인다. --dry-run 이면 내용만 보여 준다.
write_file() {
  local append=0
  [[ ${1:-} == --append ]] && { append=1; shift; }
  local f=$1
  if [[ $DRY_RUN == 1 ]]; then
    printf '%s[dry-run]%s %s %s:\n' "$C_YELLOW" "$C_RESET" "$( ((append)) && echo append || echo write)" "$f" >&8
    sed 's/^/    | /' >&8
    return 0
  fi
  if ((append)); then cat >>"$f"; else cat >"$f"; fi
}

# 원격 접속이 끊길 수 있는 단계 앞에서 묻는다.
# --yes 면 묻지 않고, 터미널이 아니면(파이프·cron) 실수로 진행하지 않도록 실패한다.
confirm() {
  local prompt=$1 answer
  [[ $DRY_RUN == 1 || $ASSUME_YES == 1 ]] && return 0
  [[ -t 0 ]] || die "확인이 필요한 단계입니다: ${prompt} (비대화형 실행이면 --yes, 미리 보기는 --dry-run)"
  read -r -p "${C_YELLOW}??${C_RESET} ${prompt} [y/N] " answer
  [[ $answer =~ ^[Yy]([Ee][Ss])?$ ]]
}

# 되돌리는 방법을 모아 두었다가 마지막에 한 번에 보여 준다
rollback_note() { ROLLBACK_NOTES+=("$1"$'\n'"      $2"); }

print_rollback_notes() {
  local log_file=${1:-} n
  (( ${#ROLLBACK_NOTES[@]} > 0 )) || return 0
  echo
  log "되돌리는 방법 (문제가 생기면 그대로 복사해 실행)"
  for n in "${ROLLBACK_NOTES[@]}"; do printf '  - %s\n' "$n"; done
  # SSH 출력은 창을 닫으면 사라지므로 장비에도 남긴다
  if [[ -n $log_file && $DRY_RUN != 1 ]]; then
    {
      printf '## %s %s (by %s)\n' "$(date '+%F %T')" "$(basename "$0")" "$(invoking_user)"
      for n in "${ROLLBACK_NOTES[@]}"; do printf -- '- %s\n' "$n"; done
      echo
    } >>"$log_file" 2>/dev/null && log "같은 내용을 $log_file 에도 남겼습니다."
  fi
  return 0
}
