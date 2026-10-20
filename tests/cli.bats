#!/usr/bin/env bats
# 모든 스크립트의 공통 CLI 동작: --help, 알 수 없는 옵션

load test_helper

setup() { common_setup; }

ROOT_SCRIPTS=(setup-performance.sh setup-remote-desktop.sh secure-ssh.sh add-team-member.sh)

@test "--help 는 사용법을 보여 주고 0 으로 끝난다" {
  for s in "${ROOT_SCRIPTS[@]}" gpu-run.sh; do
    run "$SCRIPTS/$s" --help
    [ "$status" -eq 0 ] || { echo "$s: $status"; return 1; }
    [[ $output == *"사용법"* ]] || { echo "$s: 사용법 없음"; return 1; }
  done
}

@test "알 수 없는 옵션은 아무것도 하지 않고 실패한다" {
  for s in setup-performance.sh setup-remote-desktop.sh secure-ssh.sh; do
    run "$SCRIPTS/$s" --no-such-option
    [ "$status" -ne 0 ] || { echo "$s 가 성공함"; return 1; }
  done
  run "$SCRIPTS/add-team-member.sh" someone --no-such-option
  [ "$status" -ne 0 ]
}

@test "root 가 아니면 위험한 스크립트는 바로 멈춘다" {
  for s in setup-performance.sh setup-remote-desktop.sh secure-ssh.sh; do
    JT_EUID=1000 run "$SCRIPTS/$s" --yes
    [ "$status" -ne 0 ] || { echo "$s 가 성공함"; return 1; }
    [[ $output == *"root 권한"* ]] || { echo "$s: $output"; return 1; }
  done
}

@test "healthcheck 는 Jetson 이 아닌 곳에서도 끝까지 돈다" {
  run "$SCRIPTS/healthcheck.sh"
  [ "$status" -eq 0 ]
  [[ $output == *"꺼짐 방지"* ]]
}
