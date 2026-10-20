#!/usr/bin/env bash
# SSH 보안 강화: 비밀번호 로그인 차단(키만 허용), root 로그인 차단
#
# 잠금 사고 방지 장치 (장비가 원격에 있어 잠기면 직접 가서 풀어야 한다):
#  - 실행한 사람의 authorized_keys 가 비어 있으면 중단
#  - 적용 전에 바뀔 내용을 보여 주고 확인을 받는다
#  - sshd -t 로 문법 검사 실패 시 이전 설정으로 되돌리고 중단
#  - 적용과 동시에 "자동 되돌리기" 타이머를 건다 (기본 10분).
#    새 터미널에서 접속이 되는 걸 확인한 뒤 --keep 으로 타이머를 꺼야 설정이 유지된다.
#    접속이 안 되면 아무것도 하지 않아도 시간이 지나면 원래대로 돌아간다.
#  - 이미 열린 SSH 세션은 끊기지 않는다 (reload). 확인이 끝날 때까지 기존 창을 닫지 말 것
#
# 사용법:
#   sudo ./scripts/secure-ssh.sh [옵션]
#     --dry-run              바꿀 내용만 보여 주고 아무것도 바꾸지 않음 (sudo 없이도 가능)
#     --yes                  확인 질문 생략 (비대화형 실행용)
#     --rollback-after MIN   MIN 분 뒤 자동으로 되돌림 (기본 10, 0 이면 타이머 없음 — 권장하지 않음)
#     --keep                 새 창 접속 확인 후 실행: 자동 되돌리기 취소, 설정 유지
#     --rollback             지금 바로 이전 설정으로 되돌림
#     --force                SSH 키 등록 검사 생략 (위험)
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

usage() { sed -n '2,/^set -euo/p' "$0" | sed '$d; s/^# \{0,1\}//'; exit "${1:-0}"; }

FORCE=0
ACTION=apply
ROLLBACK_MIN=10

while [[ $# -gt 0 ]]; do
  case $1 in
    --dry-run)        DRY_RUN=1 ;;
    --yes|-y)         ASSUME_YES=1 ;;
    --rollback-after) ROLLBACK_MIN=${2:?--rollback-after 값이 필요합니다}; shift ;;
    --keep)           ACTION=keep ;;
    --rollback)       ACTION=rollback ;;
    --force)          FORCE=1 ;;
    -h|--help)        usage 0 ;;
    *)                warn "알 수 없는 옵션: $1"; usage 1 ;;
  esac
  shift
done
[[ $ROLLBACK_MIN =~ ^[0-9]+$ ]] || die "--rollback-after 는 분 단위 정수입니다: $ROLLBACK_MIN"

# 경로는 테스트에서 임시 디렉터리로 바꿀 수 있다
SSHD_CONFIG=${SSHD_CONFIG:-/etc/ssh/sshd_config}
SSHD_CONF_DIR=${SSHD_CONF_DIR:-/etc/ssh/sshd_config.d}
# sshd 는 같은 옵션이 여러 번 나오면 "처음 값"을 쓴다.
# 10- 접두사로 cloud-init 등 다른 파일(50-*)보다 먼저 읽히게 한다.
CONF=$SSHD_CONF_DIR/10-jetson-team.conf
# 적용 직전 상태. *.conf 와 이름이 겹치지 않아 sshd 가 읽지 않는다.
PREV=$CONF.prev
ROLLBACK_UNIT=jetson-ssh-rollback

reload_sshd() {
  # Ubuntu 22.04 는 ssh.service, 24.04 는 소켓 활성화(ssh.socket)라 다음 접속부터 새 설정을 읽는다
  if systemctl is-active --quiet ssh; then
    run systemctl reload ssh
  fi
}

# 적용 전 상태로 파일을 되돌린다 (PREV 가 있으면 복원, 없으면 우리 파일 삭제)
restore_files() {
  if [[ -e $PREV ]]; then
    run mv -f "$PREV" "$CONF"
  else
    run rm -f "$CONF"
  fi
}

cancel_timer() {
  run systemctl stop "$ROLLBACK_UNIT.timer" 2>/dev/null || true
  run systemctl reset-failed "$ROLLBACK_UNIT.service" 2>/dev/null || true
}

timer_pending() { systemctl is-active --quiet "$ROLLBACK_UNIT.timer" 2>/dev/null; }

case $ACTION in
  keep)
    require_root
    if timer_pending; then
      cancel_timer
      ok "자동 되돌리기를 취소했습니다. 키 전용 SSH 설정이 유지됩니다 ($CONF)"
    else
      warn "예약된 자동 되돌리기가 없습니다 (이미 되돌려졌거나 --rollback-after 0 으로 적용)."
      if [[ -e $CONF ]]; then
        ok "현재 적용된 설정: $CONF"
      else
        warn "$CONF 가 없습니다 — 되돌려진 상태입니다."
      fi
    fi
    exit 0 ;;
  rollback)
    require_root
    cancel_timer
    restore_files
    reload_sshd
    ok "SSH 설정을 적용 전 상태로 되돌렸습니다."
    exit 0 ;;
esac

# ---------------------------------------------------------------------------
# 적용
# ---------------------------------------------------------------------------
require_root

ME=$(invoking_user)
if [[ -n ${SUDO_USER:-} ]]; then
  ME_HOME=$(getent passwd "$SUDO_USER" | cut -d: -f6)
else
  ME_HOME=$HOME
fi
if [[ $FORCE == 0 ]] && ! grep -qE '^(ssh-|ecdsa-|sk-)' "$ME_HOME/.ssh/authorized_keys" 2>/dev/null; then
  die "$ME 계정에 등록된 SSH 키가 없습니다. 이대로 적용하면 잠길 수 있습니다.
     먼저 맥에서: ssh-copy-id ${ME}@<jetson>  (또는 add-team-member.sh $ME --github <id>)"
fi

grep -qE '^[[:space:]]*Include[[:space:]]+/etc/ssh/sshd_config\.d/\*\.conf' "$SSHD_CONFIG" \
  || die "$SSHD_CONFIG 에 sshd_config.d Include 가 없습니다. 수동 설정이 필요합니다."

NEW_CONF=$(cat <<'EOF'
# managed by jetson_orin/scripts/secure-ssh.sh
PasswordAuthentication no
KbdInteractiveAuthentication no
PermitRootLogin no
PubkeyAuthentication yes
MaxAuthTries 3
# 끊긴 세션(와이파이 전환 등)을 정리해 좀비 세션이 남지 않게 한다
ClientAliveInterval 60
ClientAliveCountMax 3
EOF
)

if [[ -e $CONF && $(<"$CONF") == "$NEW_CONF" ]]; then
  ok "이미 적용되어 있습니다 ($CONF). 바꿀 것이 없습니다."
  exit 0
fi

log "적용할 설정: $CONF"
printf '%s\n' "$NEW_CONF" | sed 's/^/    | /'
if [[ -n ${SSH_CONNECTION:-} ]]; then
  warn "지금 SSH 로 접속 중입니다 (${SSH_CONNECTION%% *} → 이 장비). 적용 후에도 이 창은 유지됩니다."
fi
if (( ROLLBACK_MIN > 0 )); then
  log "적용 후 ${ROLLBACK_MIN}분 안에 --keep 을 실행하지 않으면 자동으로 되돌립니다."
else
  warn "--rollback-after 0: 자동 되돌리기 없이 적용합니다. 잠기면 장비 앞에서 복구해야 합니다."
fi
confirm "비밀번호 SSH 로그인을 막을까요?" || die "취소했습니다. 아무것도 바꾸지 않았습니다."

# 1) 현재 상태 보관 → 2) 새 설정 → 3) 문법 검사
if [[ -e $CONF ]]; then
  run cp -a "$CONF" "$PREV"
else
  run rm -f "$PREV"
fi
printf '%s\n' "$NEW_CONF" | write_file "$CONF"

# 소켓 활성화 환경에서는 sshd 가 아직 안 떠 있어 -t 검사에 필요한 디렉터리가 없을 수 있다
run mkdir -p /run/sshd 2>/dev/null || true
if ! run sshd -t; then
  restore_files
  die "sshd 설정 검사 실패 — 변경을 되돌렸습니다."
fi

# 4) reload 보다 먼저 되돌리기 타이머를 건다. 타이머는 이 저장소 위치와 무관하게 동작하도록 명령을 직접 담는다.
if (( ROLLBACK_MIN > 0 )); then
  revert_cmd="if [ -e $(printf '%q' "$PREV") ]; then mv -f $(printf '%q' "$PREV") $(printf '%q' "$CONF"); else rm -f $(printf '%q' "$CONF"); fi; systemctl is-active --quiet ssh && systemctl reload ssh; true"
  cancel_timer
  if ! run systemd-run --quiet --unit="$ROLLBACK_UNIT" --on-active="${ROLLBACK_MIN}m" \
        --timer-property=AccuracySec=1s /bin/sh -c "$revert_cmd"; then
    restore_files
    die "자동 되돌리기 타이머를 만들지 못해 적용을 취소했습니다. (위험을 감수한다면 --rollback-after 0)"
  fi
fi

# 5) 적용
reload_sshd

ok "SSH 키 전용 로그인 적용 ($CONF)"
warn "지금 창은 닫지 말고, 새 터미널에서 'ssh jetson' 이 되는지 먼저 확인하세요."
if (( ROLLBACK_MIN > 0 )); then
  cat <<EOF
  접속 성공 → sudo $0 --keep        (자동 되돌리기 취소, 설정 유지)
  접속 실패 → sudo $0 --rollback    (지금 바로 되돌림)
              또는 아무것도 하지 않으면 ${ROLLBACK_MIN}분 뒤 자동으로 되돌아갑니다.
EOF
else
  warn "되돌리기: sudo $0 --rollback"
fi
