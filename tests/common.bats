#!/usr/bin/env bats
# scripts/lib/common.sh 의 안전장치 헬퍼

load test_helper

setup() { common_setup; }

@test "run: dry-run 이면 실행하지 않고 보여 주기만 한다" {
  run in_common "DRY_RUN=1; run touch '$BATS_TEST_TMPDIR/x'"
  [ "$status" -eq 0 ]
  [[ $output == *"[dry-run] touch"* ]]
  [ ! -e "$BATS_TEST_TMPDIR/x" ]
}

@test "run: dry-run 안내는 호출부가 출력을 버려도 보인다" {
  run in_common "DRY_RUN=1; run systemctl restart docker >/dev/null 2>&1"
  [[ $output == *"[dry-run] systemctl restart docker"* ]]
}

@test "run: 평소에는 그대로 실행하고 종료 코드를 돌려준다" {
  run in_common "run touch '$BATS_TEST_TMPDIR/x'; run false"
  [ "$status" -ne 0 ]
  [ -e "$BATS_TEST_TMPDIR/x" ]
}

@test "write_file: dry-run 이면 내용만 보여 주고 파일을 만들지 않는다" {
  run in_common "DRY_RUN=1; echo hello | write_file '$BATS_TEST_TMPDIR/f'"
  [[ $output == *"write $BATS_TEST_TMPDIR/f"* ]]
  [[ $output == *"| hello"* ]]
  [ ! -e "$BATS_TEST_TMPDIR/f" ]
}

@test "write_file: 덮어쓰기와 --append" {
  run in_common "echo a | write_file '$BATS_TEST_TMPDIR/f'; echo b | write_file --append '$BATS_TEST_TMPDIR/f'"
  [ "$status" -eq 0 ]
  [ "$(cat "$BATS_TEST_TMPDIR/f")" = $'a\nb' ]
}

@test "confirm: 터미널이 아니고 --yes 도 없으면 진행하지 않는다" {
  run in_common "confirm '바꿀까요?' </dev/null; echo 진행됨"
  [ "$status" -ne 0 ]
  [[ $output == *"--yes"* ]]
  [[ $output != *"진행됨"* ]]
}

@test "confirm: --yes 또는 dry-run 이면 묻지 않는다" {
  run in_common "ASSUME_YES=1 confirm q </dev/null && DRY_RUN=1 confirm q </dev/null"
  [ "$status" -eq 0 ]
}

@test "backup_once: 두 번 불러도 최초 원본을 지킨다" {
  f=$BATS_TEST_TMPDIR/conf
  echo original >"$f"
  in_common "backup_once '$f'"
  echo changed >"$f"
  in_common "backup_once '$f'"
  [ "$(cat "$f.orig")" = original ]
}

@test "backup_once: dry-run 이면 백업도 만들지 않는다" {
  f=$BATS_TEST_TMPDIR/conf
  echo original >"$f"
  in_common "DRY_RUN=1; backup_once '$f'"
  [ ! -e "$f.orig" ]
}

@test "require_root: root 가 아니면 중단, dry-run 이면 경고만" {
  run in_common "JT_EUID=1000 require_root"
  [ "$status" -ne 0 ]
  run in_common "JT_EUID=1000 DRY_RUN=1 require_root; echo 계속"
  [ "$status" -eq 0 ]
  [[ $output == *"계속"* ]]
}

@test "print_rollback_notes: 되돌리기 명령을 출력하고 로그에 남긴다 (dry-run 은 로그 없음)" {
  log=$BATS_TEST_TMPDIR/rollback.log
  run in_common "rollback_note 'GUI 복귀' 'sudo systemctl set-default graphical.target'; print_rollback_notes '$log'"
  [[ $output == *"sudo systemctl set-default graphical.target"* ]]
  grep -q 'graphical.target' "$log"

  rm -f "$log"
  run in_common "DRY_RUN=1; rollback_note a b; print_rollback_notes '$log'"
  [ ! -e "$log" ]
}

@test "print_rollback_notes: 로그 디렉터리가 없으면 만들어서 남긴다" {
  log=$BATS_TEST_TMPDIR/state/rollback.log
  run in_common "rollback_note a b; print_rollback_notes '$log'"
  [ "$status" -eq 0 ]
  grep -q '^- a' "$log"
}

@test "print_rollback_notes: 로그를 못 남겨도 오류를 내지 않는다" {
  : >"$BATS_TEST_TMPDIR/not-a-dir"
  log=$BATS_TEST_TMPDIR/not-a-dir/rollback.log
  run in_common "rollback_note a b; print_rollback_notes '$log'"
  [ "$status" -eq 0 ]
  [[ $output != *"No such file"* && $output != *"Not a directory"* ]]
}
