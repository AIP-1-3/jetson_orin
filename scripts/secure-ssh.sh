#!/usr/bin/env bash
# SSH 보안 강화: 비밀번호 로그인 차단(키만 허용), root 로그인 차단
#
# 잠금 사고 방지 장치:
#  - 실행한 사람의 authorized_keys 가 비어 있으면 중단
#  - sshd -t 로 문법 검사 실패 시 설정 파일을 지우고 중단
#  - 이미 열린 SSH 세션은 끊기지 않는다 (reload). 반드시 "새 터미널"로 접속 테스트 후 기존 창을 닫을 것
#
# 사용법:
#   sudo ./scripts/secure-ssh.sh [--force]
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

FORCE=0
case ${1:-} in
  --force)   FORCE=1 ;;
  -h|--help) sed -n '2,/^set -euo/p' "$0" | sed '$d; s/^# \{0,1\}//'; exit 0 ;;
  "")        ;;
  *)         die "알 수 없는 옵션: $1" ;;
esac

require_root

ME=$(invoking_user)
ME_HOME=$(getent passwd "$ME" | cut -d: -f6)
if [[ $FORCE == 0 ]] && ! grep -qE '^(ssh-|ecdsa-|sk-)' "$ME_HOME/.ssh/authorized_keys" 2>/dev/null; then
  die "$ME 계정에 등록된 SSH 키가 없습니다. 이대로 적용하면 잠길 수 있습니다.
     먼저 맥에서: ssh-copy-id ${ME}@<jetson>  (또는 add-team-member.sh $ME --github <id>)"
fi

grep -qE '^[[:space:]]*Include[[:space:]]+/etc/ssh/sshd_config\.d/\*\.conf' /etc/ssh/sshd_config \
  || die "/etc/ssh/sshd_config 에 sshd_config.d Include 가 없습니다. 수동 설정이 필요합니다."

# sshd 는 같은 옵션이 여러 번 나오면 "처음 값"을 쓴다.
# 10- 접두사로 cloud-init 등 다른 파일(50-*)보다 먼저 읽히게 한다.
CONF=/etc/ssh/sshd_config.d/10-jetson-team.conf
cat >"$CONF" <<'EOF'
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

# 소켓 활성화 환경에서는 sshd 가 아직 안 떠 있어 -t 검사에 필요한 디렉터리가 없을 수 있다
mkdir -p /run/sshd
if ! sshd -t; then
  rm -f "$CONF"
  die "sshd 설정 검사 실패 — 변경을 되돌렸습니다."
fi

# Ubuntu 22.04 는 ssh.service, 24.04 는 소켓 활성화(ssh.socket)라 다음 접속부터 새 설정을 읽는다
if systemctl is-active --quiet ssh; then
  systemctl reload ssh
fi
ok "SSH 키 전용 로그인 적용 ($CONF)"
warn "지금 창은 닫지 말고, 새 터미널에서 'ssh jetson' 이 되는지 먼저 확인하세요."
warn "되돌리기: sudo rm $CONF && sudo systemctl reload ssh"
