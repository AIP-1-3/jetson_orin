#!/usr/bin/env bash
# Claude Code Remote Control 서버를 tmux 안에서 상시 실행 (sudo 불필요, 각자 자기 계정으로)
#
# Jetson 에서 `claude remote-control`(서버 모드)을 띄워 두면 claude.ai/code, Claude 앱,
# Claude 프로젝트 스레드에서 이 장비로 세션을 열어 빌드·테스트·벤치마크를 돌릴 수 있다.
# 연결은 Jetson → Anthropic 방향(아웃바운드 HTTPS)뿐이라 Tailscale 에 포트를 열 필요가 없다.
# tmux 안에서 돌기 때문에 SSH 가 끊겨도 유지되고, 프로세스가 죽으면 30초 뒤 다시 띄운다
# (같은 폴더에서 다시 띄우면 직전 세션들이 그대로 돌아온다).
#
# 사용법:
#   ./scripts/claude-rc.sh start [--dir DIR] [--detach]   서버 시작 (터미널이면 바로 화면에 붙는다)
#   ./scripts/claude-rc.sh attach                          서버 화면 보기 (빠져나오기: Ctrl-b d)
#   ./scripts/claude-rc.sh status                          실행 여부 + 최근 출력
#   ./scripts/claude-rc.sh stop                            서버 종료
# 환경 변수:
#   RC_NAME      claude.ai 에 보이는 이름 (기본: jetson-<리눅스아이디>)
#   RC_CAPACITY  동시 세션 수 상한 (기본: 3 — 세션마다 메모리를 쓰므로 통합 메모리 보호용)
#   RC_SPAWN     same-dir | worktree (기본: worktree — 스레드마다 git worktree 를 따로 써서 충돌 방지)
#   RC_PERMISSION_MODE  예: acceptEdits (기본: 지정 안 함 = 매번 앱에서 승인)
# 예:
#   ./scripts/claude-rc.sh start                 # 처음: 화면에 붙어서 신뢰/활성화 질문에 y
#   ./scripts/claude-rc.sh start --detach        # 이후: 백그라운드로만
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

SESSION="claude-rc"
RC_NAME=${RC_NAME:-jetson-${USER:-$(id -un)}}
RC_CAPACITY=${RC_CAPACITY:-3}
RC_SPAWN=${RC_SPAWN:-worktree}
RC_PERMISSION_MODE=${RC_PERMISSION_MODE:-}
DIR=$(cd "$SCRIPT_DIR/.." && pwd)
DETACH=0

usage() { sed -n '2,/^set -euo/p' "$0" | sed '$d; s/^# \{0,1\}//'; exit "${1:-0}"; }

running() { tmux has-session -t "=$SESSION" 2>/dev/null; }

# 이미 tmux 안이면 중첩 attach 대신 서버 세션으로 화면을 전환한다
show() {
  if [[ -n ${TMUX:-} ]]; then
    exec tmux switch-client -t "=$SESSION"
  fi
  exec tmux attach -t "=$SESSION"
}

find_claude() {
  command -v claude 2>/dev/null && return
  [[ -x $HOME/.local/bin/claude ]] && { echo "$HOME/.local/bin/claude"; return; }
  die "claude 가 없습니다. 먼저 설치: curl -fsSL https://claude.ai/install.sh | bash"
}

cmd_start() {
  command -v tmux >/dev/null || die "tmux 가 없습니다 (관리자에게 sudo apt install tmux 요청)."
  [[ -d $DIR ]] || die "폴더가 없습니다: $DIR"
  case $RC_SPAWN in same-dir|worktree) ;; *) die "RC_SPAWN 은 same-dir 또는 worktree: $RC_SPAWN" ;; esac
  if [[ $RC_SPAWN == worktree ]] && ! git -C "$DIR" rev-parse --git-dir >/dev/null 2>&1; then
    warn "$DIR 은 git 저장소가 아니라 RC_SPAWN=same-dir 로 실행합니다."
    RC_SPAWN=same-dir
  fi

  local claude
  claude=$(find_claude)

  if running; then
    ok "이미 실행 중입니다 (tmux 세션 '$SESSION'). 화면 보기: $0 attach"
  else
    # API 키가 잡혀 있으면 Remote Control 이 거부된다 (claude.ai 로그인만 지원).
    local args=(remote-control --name "$RC_NAME" --spawn "$RC_SPAWN" --capacity "$RC_CAPACITY")
    [[ -n $RC_PERMISSION_MODE ]] && args+=(--permission-mode "$RC_PERMISSION_MODE")
    local inner
    inner="unset ANTHROPIC_API_KEY ANTHROPIC_AUTH_TOKEN CLAUDE_CODE_OAUTH_TOKEN
while true; do
  $(printf '%q ' "$claude" "${args[@]}")
  rc=\$?
  echo \"[claude-rc] \$(date '+%F %T') 종료됨 (코드 \$rc). 30초 뒤 다시 시작합니다. 멈추려면: $0 stop\"
  sleep 30
done"
    tmux new-session -d -s "$SESSION" -c "$DIR" bash -c "$inner"
    ok "시작했습니다: $RC_NAME  (폴더 $DIR, spawn=$RC_SPAWN, 최대 $RC_CAPACITY 세션)"
  fi

  if [[ $DETACH -eq 0 && -t 0 && -t 1 ]]; then
    log "서버 화면에 붙습니다. 처음이면 'Trust …?' / 'Enable Remote Control?' 에 y. 빠져나오기: Ctrl-b d"
    show
  fi
  log "화면 보기: $0 attach   상태: $0 status"
}

cmd_status() {
  if running; then
    ok "실행 중 (tmux 세션 '$SESSION')"
    tmux capture-pane -p -t "=$SESSION:" | sed '/^[[:space:]]*$/d' | tail -n 15
  else
    warn "실행 중이 아닙니다. 시작: $0 start"
    return 1
  fi
}

cmd_stop() {
  if running; then
    tmux kill-session -t "=$SESSION"
    ok "종료했습니다. 다시 시작하면(같은 폴더, 약 4시간 이내) 직전 세션들이 돌아옵니다."
  else
    ok "이미 꺼져 있습니다."
  fi
}

sub=${1:-}
[[ -n $sub ]] || usage 1
shift
while [[ $# -gt 0 ]]; do
  case $1 in
    --dir) DIR=$(cd "${2:?--dir 뒤에 폴더}" && pwd); shift 2 ;;
    --detach) DETACH=1; shift ;;
    -h|--help) usage 0 ;;
    *) die "알 수 없는 옵션: $1 (도움말: $0 --help)" ;;
  esac
done

case $sub in
  start) cmd_start ;;
  attach) running || die "실행 중이 아닙니다. 시작: $0 start"; show ;;
  status) cmd_status ;;
  stop) cmd_stop ;;
  -h|--help|help) usage 0 ;;
  *) die "알 수 없는 명령: $sub (start | attach | status | stop)" ;;
esac
