#!/usr/bin/env bats
# scripts/gpu-run.sh: 팀 단위 GPU 작업 락

load test_helper

setup() {
  common_setup
  export GPU_RUN_LOCK=$BATS_TEST_TMPDIR/gpu.lock
}

teardown() {
  [[ -n ${HOLDER:-} ]] && kill "$HOLDER" 2>/dev/null || true
}

hold_lock() {
  : >"$GPU_RUN_LOCK"
  flock "$GPU_RUN_LOCK" sleep 30 &
  HOLDER=$!
  # 락이 실제로 잡힐 때까지 기다린다
  for _ in $(seq 50); do flock -n "$GPU_RUN_LOCK" true || return 0; sleep 0.1; done
  return 1
}

@test "--status: 비어 있으면 비어 있음" {
  run "$SCRIPTS/gpu-run.sh" --status
  [ "$status" -eq 0 ]
  [[ $output == *"비어 있음"* ]]
}

@test "--status: 누가 쓰는 중이면 사용 중" {
  hold_lock
  run "$SCRIPTS/gpu-run.sh" --status
  [[ $output == *"사용 중"* ]]
}

@test "명령을 실행하고 종료 코드를 그대로 돌려준다" {
  run "$SCRIPTS/gpu-run.sh" -- sh -c 'echo hi; exit 3'
  [ "$status" -eq 3 ]
  [[ $output == *"hi"* ]]
}

@test "--wait-max: 락을 못 얻으면 75 로 끝난다" {
  hold_lock
  run "$SCRIPTS/gpu-run.sh" --wait-max 1 -- true
  [ "$status" -eq 75 ]
}
