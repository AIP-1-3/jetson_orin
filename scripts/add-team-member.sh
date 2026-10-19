#!/usr/bin/env bash
# 팀원 리눅스 계정 생성 + SSH 키 등록 + GPU/Docker 권한 부여
#
# 계정을 공유하지 않고 사람마다 따로 만든다:
#  - 각자 홈 디렉터리/깃 설정/Claude Code 로그인이 섞이지 않는다
#  - 누가 어떤 프로세스로 메모리·GPU를 쓰는지 jtop/ps 로 바로 보인다
#
# 사용법:
#   sudo ./scripts/add-team-member.sh <리눅스아이디> [옵션]
#     --github USER     github.com/USER.keys 의 공개키를 등록 (가장 간편)
#     --key-file PATH   공개키 파일을 등록 (여러 번 지정 가능)
#     --sudo            sudo 권한 부여 (관리 담당자에게만)
#     --no-password     비밀번호를 설정하지 않음 (이 경우 원격 데스크톱 로그인 불가)
#
# 예:
#   sudo ./scripts/add-team-member.sh minji --github minji-dev
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_DIR=$(cd "$SCRIPT_DIR/.." && pwd)
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

usage() { sed -n '2,/^set -euo/p' "$0" | sed '$d; s/^# \{0,1\}//'; exit "${1:-0}"; }

[[ $# -ge 1 ]] || usage 1
[[ $1 =~ ^(-h|--help)$ ]] && usage 0

NEW_USER=$1; shift
GITHUB_USER=""
KEY_FILES=()
GRANT_SUDO=0
SET_PASSWORD=1

while [[ $# -gt 0 ]]; do
  case $1 in
    --github)      GITHUB_USER=${2:?--github 값이 필요합니다}; shift ;;
    --key-file)    KEY_FILES+=("${2:?--key-file 값이 필요합니다}"); shift ;;
    --sudo)        GRANT_SUDO=1 ;;
    --no-password) SET_PASSWORD=0 ;;
    -h|--help)     usage 0 ;;
    *)             warn "알 수 없는 옵션: $1"; usage 1 ;;
  esac
  shift
done

require_root
[[ $NEW_USER =~ ^[a-z_][a-z0-9_-]{0,31}$ ]] || die "리눅스 아이디 형식 오류: '$NEW_USER' (소문자/숫자/-/_)"

# 키 입력은 계정을 건드리기 전에 먼저 모은다 — 중간 실패로 반쯤 만들어진 계정이 남지 않게
new_keys=""
if [[ -n $GITHUB_USER ]]; then
  new_keys+=$(curl -fsSL --max-time 15 "https://github.com/${GITHUB_USER}.keys") \
    || die "GitHub 키를 가져오지 못했습니다: https://github.com/${GITHUB_USER}.keys"
  new_keys+=$'\n'
fi
for kf in "${KEY_FILES[@]}"; do
  [[ -r $kf ]] || die "키 파일을 읽을 수 없습니다: $kf"
  new_keys+=$(cat "$kf")$'\n'
done

# ---------------------------------------------------------------------------
# 1) 계정
# ---------------------------------------------------------------------------
if id "$NEW_USER" >/dev/null 2>&1; then
  ok "계정 이미 존재: $NEW_USER (권한/키만 갱신)"
else
  adduser --disabled-password --gecos "" "$NEW_USER" >/dev/null
  ok "계정 생성: $NEW_USER"
fi
HOME_DIR=$(getent passwd "$NEW_USER" | cut -d: -f6)

# ---------------------------------------------------------------------------
# 2) 그룹: video/render = GPU(CUDA) 장치 접근, docker = 컨테이너, jtop = 모니터링
#    주의: docker 그룹은 사실상 root 권한이다. 신뢰하는 팀원에게만.
# ---------------------------------------------------------------------------
groups_added=()
for g in video render docker jtop i2c gpio; do
  if getent group "$g" >/dev/null; then
    usermod -aG "$g" "$NEW_USER"
    groups_added+=("$g")
  fi
done
if [[ $GRANT_SUDO == 1 ]]; then
  usermod -aG sudo "$NEW_USER"
  groups_added+=(sudo)
fi
ok "그룹: ${groups_added[*]:-(없음)}"

# ---------------------------------------------------------------------------
# 3) SSH 공개키 (비밀번호 SSH 는 secure-ssh.sh 로 막는다)
# ---------------------------------------------------------------------------
SSH_DIR=$HOME_DIR/.ssh
AUTH_KEYS=$SSH_DIR/authorized_keys
install -d -m 700 -o "$NEW_USER" -g "$NEW_USER" "$SSH_DIR"
[[ -e $AUTH_KEYS ]] || install -m 600 -o "$NEW_USER" -g "$NEW_USER" /dev/null "$AUTH_KEYS"

added=0
while IFS= read -r key; do
  [[ -z $key ]] && continue
  # 공개키 형식만 허용 (실수로 개인키를 붙여넣는 사고 방지)
  if [[ ! $key =~ ^(ssh-(ed25519|rsa)|ecdsa-sha2-nistp(256|384|521)|sk-(ssh-ed25519|ecdsa-sha2-nistp256)@openssh\.com)[[:space:]] ]]; then
    warn "공개키 형식이 아니어서 건너뜀: ${key:0:30}..."
    continue
  fi
  if ! grep -qxF "$key" "$AUTH_KEYS"; then
    printf '%s\n' "$key" >>"$AUTH_KEYS"
    added=$((added + 1))
  fi
done <<<"$new_keys"
chown "$NEW_USER:$NEW_USER" "$AUTH_KEYS"
chmod 600 "$AUTH_KEYS"
total=$(grep -c . "$AUTH_KEYS" || true)
ok "SSH 키: ${added}개 추가 (총 ${total}개)"
(( total > 0 )) || warn "등록된 SSH 키가 없습니다. --github 또는 --key-file 로 다시 실행하세요."

# ---------------------------------------------------------------------------
# 4) 기본 환경: tmux 설정, XFCE 세션
# ---------------------------------------------------------------------------
if [[ ! -e $HOME_DIR/.tmux.conf && -r $REPO_DIR/config/tmux.conf ]]; then
  install -m 644 -o "$NEW_USER" -g "$NEW_USER" "$REPO_DIR/config/tmux.conf" "$HOME_DIR/.tmux.conf"
  ok "tmux 설정 복사"
fi
if command -v xfce4-session >/dev/null && [[ ! -e $HOME_DIR/.xsession ]]; then
  printf 'xfce4-session\n' >"$HOME_DIR/.xsession"
  chown "$NEW_USER:$NEW_USER" "$HOME_DIR/.xsession"
fi

# ---------------------------------------------------------------------------
# 5) 비밀번호: 원격 데스크톱(xrdp) 로그인과 sudo 에만 쓰인다
# ---------------------------------------------------------------------------
if [[ $SET_PASSWORD == 1 ]]; then
  if passwd -S "$NEW_USER" 2>/dev/null | awk '{exit ($2=="P") ? 0 : 1}'; then
    ok "비밀번호 이미 설정됨 (변경: sudo passwd $NEW_USER)"
  else
    log "$NEW_USER 의 비밀번호를 설정하세요 (원격 데스크톱 로그인용)"
    passwd "$NEW_USER"
  fi
fi

host=$(tailscale status --self --json 2>/dev/null \
  | python3 -c 'import json,sys; print(json.load(sys.stdin)["Self"]["DNSName"].rstrip("."))' 2>/dev/null \
  || hostname)
cat <<EOF

$(ok "완료. 팀원에게 전달할 내용:")
  1. Tailscale 앱 설치 후 초대 수락 (docs/01-team-access.md)
  2. ~/.ssh/config 에 추가 (config/ssh_config.example 참고)
       Host jetson
         HostName ${host}
         User ${NEW_USER}
  3. 접속 확인: ssh jetson
  4. Claude Code 설치/로그인은 각자 본인 계정으로 (docs/04-team-workflow.md)
EOF
