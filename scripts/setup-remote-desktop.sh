#!/usr/bin/env bash
# Jetson 원격 데스크톱 서버(xrdp + XFCE) 설치
#
# Thincast 는 RDP "클라이언트"라서 Jetson 쪽에는 RDP 서버가 필요하다.
#  - xrdp: 모니터 없이(헤드리스) 사용자마다 독립된 가상 세션을 만들어 준다.
#  - XFCE: GNOME 보다 메모리를 훨씬 적게 쓰고 xrdp 와 궁합이 좋다.
# GUI 는 필요할 때만 쓰고, 평소 개발은 SSH(터미널/VS Code/Claude Code)로 하는 것을 전제로 한다.
#
# 사용법:
#   sudo ./scripts/setup-remote-desktop.sh [옵션]
#     --dry-run   바꿀 내용만 보여 주고 아무것도 바꾸지 않음 (sudo 없이도 가능)
#     --yes       확인 질문 생략 (비대화형 실행용)
#
# SSH·Tailscale 은 건드리지 않는다. 다만 마지막에 xrdp 를 재시작하므로
# 지금 원격 데스크톱으로 접속 중인 사람은 연결이 끊긴다 (실행 전 확인).
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

usage() { sed -n '2,/^set -euo/p' "$0" | sed '$d; s/^# \{0,1\}//'; exit "${1:-0}"; }

while [[ $# -gt 0 ]]; do
  case $1 in
    --dry-run) DRY_RUN=1 ;;
    --yes|-y)  ASSUME_YES=1 ;;
    -h|--help) usage 0 ;;
    *)         warn "알 수 없는 옵션: $1"; usage 1 ;;
  esac
  shift
done

require_root
require_jetson

INI=${XRDP_INI:-/etc/xrdp/xrdp.ini}
SYSCTL_CONF=/etc/sysctl.d/90-jetson-team-xrdp.conf

# 원격 데스크톱 접속 수 (xrdp 재시작 시 끊기는 연결)
rdp_sessions=$(ss -Htn state established '( sport = :3389 )' 2>/dev/null | wc -l || echo 0)
log "할 일: xrdp/XFCE 설치, 사용자 세션을 XFCE 로, polkit 팝업 제거, xrdp 대역폭 튜닝, xrdp 재시작"
if (( rdp_sessions > 0 )); then
  warn "지금 원격 데스크톱 연결 ${rdp_sessions}개가 있습니다. xrdp 재시작 시 끊깁니다 (저장 안 한 작업 주의)."
fi
[[ $DRY_RUN == 1 ]] && log "dry-run: 실제로는 아무것도 바꾸지 않습니다."
confirm "진행할까요? (SSH 연결은 끊기지 않습니다)" || die "취소했습니다. 아무것도 바꾸지 않았습니다."

log "xrdp + XFCE 설치 (수 분 소요)"
run apt-get update -qq
run env DEBIAN_FRONTEND=noninteractive apt-get install -y \
  xrdp xorgxrdp xfce4 xfce4-terminal dbus-x11 >/dev/null
ok "패키지 설치 완료"

# xrdp 가 TLS 인증서(/etc/ssl/private)를 읽을 수 있어야 한다
run adduser xrdp ssl-cert >/dev/null 2>&1 || true

# ---------------------------------------------------------------------------
# 세션을 XFCE 로: 기존 사람 계정 + 앞으로 만들 계정(/etc/skel)
# ---------------------------------------------------------------------------
write_xsession() {
  local home=$1 owner=$2
  [[ -e $home/.xsession ]] && return 0
  printf 'xfce4-session\n' | write_file "$home/.xsession"
  [[ -n $owner ]] && run chown "$owner:" "$home/.xsession"
  return 0
}
write_xsession /etc/skel ""
while IFS=: read -r name _ uid _ _ home _; do
  if (( uid >= 1000 && uid < 60000 )) && [[ -d $home ]]; then
    write_xsession "$home" "$name"
  fi
done </etc/passwd
ok "XFCE 세션 설정 (~/.xsession)"

# ---------------------------------------------------------------------------
# 원격 접속 시 반복해서 뜨는 "color managed device" 인증 팝업 제거
# Ubuntu 22.04(polkit 0.105)는 .pkla, 24.04(polkit 12x)는 .rules 를 읽는다
# ---------------------------------------------------------------------------
if [[ -d /etc/polkit-1/localauthority/50-local.d ]]; then
  write_file /etc/polkit-1/localauthority/50-local.d/45-allow-colord.pkla <<'EOF'
[Allow colord for all users]
Identity=unix-user:*
Action=org.freedesktop.color-manager.create-device;org.freedesktop.color-manager.create-profile;org.freedesktop.color-manager.delete-device;org.freedesktop.color-manager.delete-profile;org.freedesktop.color-manager.modify-device;org.freedesktop.color-manager.modify-profile
ResultAny=no
ResultInactive=no
ResultActive=yes
EOF
fi
if [[ -d /etc/polkit-1/rules.d ]]; then
  write_file /etc/polkit-1/rules.d/45-allow-colord.rules <<'EOF'
polkit.addRule(function(action, subject) {
  if (action.id.indexOf("org.freedesktop.color-manager.") === 0) {
    return polkit.Result.YES;
  }
});
EOF
fi

# ---------------------------------------------------------------------------
# 대역폭/지연 튜닝: 색 깊이 24bit, 송신 버퍼 확대 (원격 Wi-Fi/LTE 환경 체감 개선)
# ---------------------------------------------------------------------------
prev_wmem=$(sysctl -n net.core.wmem_max 2>/dev/null || true)
backup_once "$INI"
run sed -i -E 's/^max_bpp=32$/max_bpp=24/' "$INI"
run sed -i -E 's/^#?tcp_send_buffer_bytes=.*/tcp_send_buffer_bytes=4194304/' "$INI"
write_file "$SYSCTL_CONF" <<'EOF'
# xrdp tcp_send_buffer_bytes(4MB)가 실제로 적용되도록 커널 상한을 올린다
net.core.wmem_max = 8388608
EOF
run sysctl -q -p "$SYSCTL_CONF"
rollback_note "xrdp 튜닝 원복" "sudo cp -a $INI.orig $INI && sudo systemctl restart xrdp"
[[ -n $prev_wmem ]] && rollback_note "송신 버퍼 상한 원복" "sudo rm $SYSCTL_CONF && sudo sysctl -w net.core.wmem_max=$prev_wmem"
ok "xrdp 튜닝 (max_bpp=24, send buffer 4MB)"

run systemctl enable xrdp >/dev/null 2>&1
run systemctl restart xrdp
rollback_note "원격 데스크톱 끄기 (SSH 는 영향 없음)" "sudo systemctl disable --now xrdp"
ok "xrdp 실행 중 (포트 3389)"

if [[ $(systemctl get-default) == graphical.target ]]; then
  warn "현재 GUI 부팅 상태입니다. 같은 계정으로 모니터 로그인과 xrdp 로그인을 동시에 하면 검은 화면이 뜹니다."
  warn "원격 전용이라면 헤드리스 전환을 권장합니다: sudo ./scripts/setup-performance.sh --headless"
fi

host=$(tailscale status --self --json 2>/dev/null \
  | python3 -c 'import json,sys; print(json.load(sys.stdin)["Self"]["DNSName"].rstrip("."))' 2>/dev/null \
  || hostname)
echo
ok "Thincast(또는 Windows App)에서 접속: ${host}:3389  (아이디/비밀번호 = Jetson 리눅스 계정)"
print_rollback_notes "${JT_STATE_DIR:-/var/lib/jetson-team}/rollback.log"
