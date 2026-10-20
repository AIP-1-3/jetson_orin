#!/usr/bin/env bats
# scripts/secure-ssh.sh: 원격 잠금 사고 방지 장치

load test_helper

setup() {
  common_setup
  export JT_EUID=0
  export HOME=$BATS_TEST_TMPDIR/home
  mkdir -p "$HOME/.ssh"
  echo 'ssh-ed25519 AAAAC3NzaTEST tester@mac' >"$HOME/.ssh/authorized_keys"

  export SSHD_CONFIG=$BATS_TEST_TMPDIR/sshd_config
  export SSHD_CONF_DIR=$BATS_TEST_TMPDIR/sshd_config.d
  mkdir -p "$SSHD_CONF_DIR"
  echo 'Include /etc/ssh/sshd_config.d/*.conf' >"$SSHD_CONFIG"
  CONF=$SSHD_CONF_DIR/10-jetson-team.conf

  stub sshd
  # ssh.service 는 실행 중, 되돌리기 타이머 상태는 $TIMER_ACTIVE 로 정한다
  stub systemctl '
case "$*" in
  "is-active --quiet ssh") exit 0 ;;
  "is-active --quiet jetson-ssh-rollback.timer") [[ ${TIMER_ACTIVE:-0} == 1 ]] ;;
esac
exit 0'
  # 타이머에 넘긴 되돌리기 명령(마지막 인자)을 따로 저장해 두고 나중에 실행해 본다
  stub systemd-run 'printf "%s" "${@: -1}" >"$BATS_TEST_TMPDIR/revert_cmd"'
}

@test "--dry-run: 설정을 보여 주기만 하고 아무것도 바꾸지 않는다" {
  run "$SCRIPTS/secure-ssh.sh" --dry-run
  [ "$status" -eq 0 ]
  [[ $output == *"PasswordAuthentication no"* ]]
  [[ $output == *"[dry-run] systemd-run"* ]]
  [ ! -e "$CONF" ]
  refute_called "$MUTATING"
}

@test "SSH 키가 없으면 잠길 수 있으므로 중단" {
  : >"$HOME/.ssh/authorized_keys"
  run "$SCRIPTS/secure-ssh.sh" --yes
  [ "$status" -ne 0 ]
  [[ $output == *"SSH 키가 없습니다"* ]]
  [ ! -e "$CONF" ]
}

@test "터미널이 아니면 --yes 없이 진행하지 않는다" {
  run "$SCRIPTS/secure-ssh.sh" </dev/null
  [ "$status" -ne 0 ]
  [ ! -e "$CONF" ]
  refute_called "$MUTATING"
}

@test "적용: 설정을 쓰고, reload 전에 10분 자동 되돌리기 타이머를 건다" {
  run "$SCRIPTS/secure-ssh.sh" --yes
  [ "$status" -eq 0 ]
  grep -qx 'PasswordAuthentication no' "$CONF"
  assert_called '^systemd-run .*--on-active=10m'
  assert_called '^systemctl reload ssh'
  timer_line=$(grep -n '^systemd-run' "$CALLS" | cut -d: -f1)
  reload_line=$(grep -n '^systemctl reload ssh' "$CALLS" | cut -d: -f1)
  (( timer_line < reload_line ))
  [[ $output == *"--keep"* ]]
}

@test "자동 되돌리기 명령이 실제로 원래 상태(파일 없음)로 돌린다" {
  "$SCRIPTS/secure-ssh.sh" --yes
  [ -e "$CONF" ]
  sh -c "$(cat "$BATS_TEST_TMPDIR/revert_cmd")"
  [ ! -e "$CONF" ]
  assert_called '^systemctl reload ssh'
}

@test "자동 되돌리기 명령이 기존 설정을 그대로 복원한다" {
  echo '# 예전 설정' >"$CONF"
  "$SCRIPTS/secure-ssh.sh" --yes
  grep -qx 'PasswordAuthentication no' "$CONF"
  sh -c "$(cat "$BATS_TEST_TMPDIR/revert_cmd")"
  [ "$(cat "$CONF")" = '# 예전 설정' ]
}

@test "sshd -t 실패: 적용 전 상태로 되돌리고 reload 하지 않는다" {
  echo '# 예전 설정' >"$CONF"
  stub sshd 'exit 1'
  run "$SCRIPTS/secure-ssh.sh" --yes
  [ "$status" -ne 0 ]
  [[ $output == *"되돌렸습니다"* ]]
  [ "$(cat "$CONF")" = '# 예전 설정' ]
  refute_called '^systemctl reload'
  refute_called '^systemd-run'
}

@test "타이머를 못 만들면 적용하지 않는다" {
  stub systemd-run 'exit 1'
  run "$SCRIPTS/secure-ssh.sh" --yes
  [ "$status" -ne 0 ]
  [ ! -e "$CONF" ]
  refute_called '^systemctl reload'
}

@test "--rollback-after 0: 타이머 없이 적용 (경고 출력)" {
  run "$SCRIPTS/secure-ssh.sh" --yes --rollback-after 0
  [ "$status" -eq 0 ]
  [ -e "$CONF" ]
  refute_called '^systemd-run'
  [[ $output == *"자동 되돌리기 없이"* ]]
}

@test "--rollback-after 는 정수만 받는다" {
  run "$SCRIPTS/secure-ssh.sh" --yes --rollback-after soon
  [ "$status" -ne 0 ]
  [ ! -e "$CONF" ]
}

@test "이미 같은 설정이면 아무것도 하지 않는다" {
  "$SCRIPTS/secure-ssh.sh" --yes --rollback-after 0
  : >"$CALLS"
  run "$SCRIPTS/secure-ssh.sh" --yes
  [ "$status" -eq 0 ]
  [[ $output == *"이미 적용"* ]]
  refute_called "$MUTATING"
}

@test "--keep: 예약된 타이머를 멈추고 설정은 유지" {
  "$SCRIPTS/secure-ssh.sh" --yes
  TIMER_ACTIVE=1 run "$SCRIPTS/secure-ssh.sh" --keep
  [ "$status" -eq 0 ]
  assert_called '^systemctl stop jetson-ssh-rollback.timer'
  [ -e "$CONF" ]
}

@test "--rollback: 즉시 이전 상태로 되돌린다" {
  "$SCRIPTS/secure-ssh.sh" --yes
  run "$SCRIPTS/secure-ssh.sh" --rollback
  [ "$status" -eq 0 ]
  [ ! -e "$CONF" ]
  assert_called '^systemctl stop jetson-ssh-rollback.timer'
}
