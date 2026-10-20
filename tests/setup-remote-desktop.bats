#!/usr/bin/env bats
# scripts/setup-remote-desktop.sh: dry-run 과 접속 중인 원격 데스크톱 경고

load test_helper

setup() {
  common_setup
  export JT_EUID=0
  export NV_TEGRA_RELEASE=$BATS_TEST_TMPDIR/nv_tegra_release
  export XRDP_INI=$BATS_TEST_TMPDIR/xrdp.ini
  echo '# R36 (release), REVISION: 4.3' >"$NV_TEGRA_RELEASE"
  printf 'max_bpp=32\n#tcp_send_buffer_bytes=32768\n' >"$XRDP_INI"
  stub sysctl '[[ $1 == -n ]] && echo 212992; exit 0'
  stub ss
  for c in apt-get adduser systemctl chown; do stub "$c"; done
}

@test "--dry-run: 아무것도 바꾸지 않는다" {
  run "$SCRIPTS/setup-remote-desktop.sh" --dry-run
  [ "$status" -eq 0 ]
  [[ $output == *"[dry-run] systemctl restart xrdp"* ]]
  [[ $output == *"net.core.wmem_max=212992"* ]]
  refute_called "$MUTATING"
  [ "$(cat "$XRDP_INI")" = $'max_bpp=32\n#tcp_send_buffer_bytes=32768' ]
  [ ! -e "$XRDP_INI.orig" ]
}

@test "원격 데스크톱 접속이 있으면 끊긴다고 경고한다" {
  stub ss 'echo "ESTAB 0 0 100.64.0.1:3389 100.64.0.2:50000"'
  run "$SCRIPTS/setup-remote-desktop.sh" --dry-run
  [[ $output == *"원격 데스크톱 연결 1개"* ]]
}

@test "터미널이 아니면 --yes 없이 진행하지 않는다" {
  run "$SCRIPTS/setup-remote-desktop.sh" </dev/null
  [ "$status" -ne 0 ]
  refute_called "$MUTATING"
}
