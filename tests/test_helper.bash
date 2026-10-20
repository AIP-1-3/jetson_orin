# shellcheck shell=bash
# bats 공용 헬퍼. 실제 장비 명령(systemctl, nvpmodel 등)은 모두 가짜(stub)로 바꿔서
# 일반 리눅스(CI, 각자 맥의 Docker)에서도 스크립트 흐름을 검증한다.

REPO_DIR=$(cd "$BATS_TEST_DIRNAME/.." && pwd)
SCRIPTS=$REPO_DIR/scripts

common_setup() {
  STUB_DIR=$BATS_TEST_TMPDIR/bin
  CALLS=$BATS_TEST_TMPDIR/calls.log
  mkdir -p "$STUB_DIR"
  : >"$CALLS"
  export PATH="$STUB_DIR:$PATH" CALLS BATS_TEST_TMPDIR
  # 테스트가 실행 환경(SSH 접속 여부, sudo)에 흔들리지 않게
  unset SUDO_USER SSH_CONNECTION DRY_RUN ASSUME_YES
}

# stub NAME [BODY]: NAME 명령을 가짜로 바꾼다. 호출은 $CALLS 에 "NAME 인자..." 한 줄로 남는다.
# BODY 는 그대로 스크립트 본문에 들어간다 ("$1" 등 사용 가능).
stub() {
  local name=$1 body=${2:-}
  {
    echo '#!/usr/bin/env bash'
    echo "echo \"$name \$*\" >>\"\$CALLS\""
    printf '%s\n' "$body"
  } >"$STUB_DIR/$name"
  chmod +x "$STUB_DIR/$name"
}

# 기록된 호출 중 PATTERN(확장 정규식)에 맞는 것이 없어야 한다
refute_called() {
  if grep -E "$1" "$CALLS"; then
    echo "호출되면 안 되는 명령이 실행됨: $1" >&2
    return 1
  fi
}

assert_called() {
  grep -qE "$1" "$CALLS" || { echo "호출 기록 없음: $1"; cat "$CALLS"; return 1; }
}

# common.sh 의 run() 이 bats 의 run 과 이름이 같아 별도 bash 에서 source 한다
in_common() {
  bash -c "set -euo pipefail; source '$SCRIPTS/lib/common.sh'; $1"
}

# 상태를 바꾸는 명령 패턴 (dry-run 에서 하나도 호출되면 안 된다)
# shellcheck disable=SC2034  # 각 .bats 에서 사용
MUTATING='^(systemctl (enable|disable|restart|reload|stop|start|set-default|daemon-reload|reset-failed)|systemd-run|apt-get|pip3|fallocate|mkswap|swapon /|sysctl (-q )?-p|sysctl -w|nvpmodel -m|jetson_clocks( |$)|adduser|chown|sshd)'
