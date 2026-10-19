#!/usr/bin/env bash
# Jetson 원격 데스크톱 서버(xrdp + XFCE) 설치
#
# Thincast 는 RDP "클라이언트"라서 Jetson 쪽에는 RDP 서버가 필요하다.
#  - xrdp: 모니터 없이(헤드리스) 사용자마다 독립된 가상 세션을 만들어 준다.
#  - XFCE: GNOME 보다 메모리를 훨씬 적게 쓰고 xrdp 와 궁합이 좋다.
# GUI 는 필요할 때만 쓰고, 평소 개발은 SSH(터미널/VS Code/Claude Code)로 하는 것을 전제로 한다.
#
# 사용법:
#   sudo ./scripts/setup-remote-desktop.sh
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

[[ ${1:-} =~ ^(-h|--help)$ ]] && { sed -n '2,/^set -euo/p' "$0" | sed '$d; s/^# \{0,1\}//'; exit 0; }

require_root
require_jetson

log "xrdp + XFCE 설치 (수 분 소요)"
apt-get update -qq
DEBIAN_FRONTEND=noninteractive apt-get install -y \
  xrdp xorgxrdp xfce4 xfce4-terminal dbus-x11 >/dev/null
ok "패키지 설치 완료"

# xrdp 가 TLS 인증서(/etc/ssl/private)를 읽을 수 있어야 한다
adduser xrdp ssl-cert >/dev/null 2>&1 || true

# ---------------------------------------------------------------------------
# 세션을 XFCE 로: 기존 사람 계정 + 앞으로 만들 계정(/etc/skel)
# ---------------------------------------------------------------------------
write_xsession() {
  local home=$1 owner=$2
  [[ -e $home/.xsession ]] && return 0
  printf 'xfce4-session\n' >"$home/.xsession"
  [[ -n $owner ]] && chown "$owner:" "$home/.xsession"
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
  cat >/etc/polkit-1/localauthority/50-local.d/45-allow-colord.pkla <<'EOF'
[Allow colord for all users]
Identity=unix-user:*
Action=org.freedesktop.color-manager.create-device;org.freedesktop.color-manager.create-profile;org.freedesktop.color-manager.delete-device;org.freedesktop.color-manager.delete-profile;org.freedesktop.color-manager.modify-device;org.freedesktop.color-manager.modify-profile
ResultAny=no
ResultInactive=no
ResultActive=yes
EOF
fi
if [[ -d /etc/polkit-1/rules.d ]]; then
  cat >/etc/polkit-1/rules.d/45-allow-colord.rules <<'EOF'
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
INI=/etc/xrdp/xrdp.ini
backup_once "$INI"
sed -i -E 's/^max_bpp=32$/max_bpp=24/' "$INI"
sed -i -E 's/^#?tcp_send_buffer_bytes=.*/tcp_send_buffer_bytes=4194304/' "$INI"
cat >/etc/sysctl.d/90-jetson-team-xrdp.conf <<'EOF'
# xrdp tcp_send_buffer_bytes(4MB)가 실제로 적용되도록 커널 상한을 올린다
net.core.wmem_max = 8388608
EOF
sysctl -q -p /etc/sysctl.d/90-jetson-team-xrdp.conf
ok "xrdp 튜닝 (max_bpp=24, send buffer 4MB)"

systemctl enable xrdp >/dev/null 2>&1
systemctl restart xrdp
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
