#!/usr/bin/env bats
# scripts/setup-performance.sh: dry-run 이 아무것도 바꾸지 않는지, 실제 실행이 되돌리기 정보를 남기는지

load test_helper

setup() {
  common_setup
  export JT_EUID=0
  export JT_STATE_DIR=$BATS_TEST_TMPDIR/state
  export NV_TEGRA_RELEASE=$BATS_TEST_TMPDIR/nv_tegra_release
  export NVPMODEL_CONF=$BATS_TEST_TMPDIR/nvpmodel.conf
  export DOCKER_DAEMON_JSON=$BATS_TEST_TMPDIR/docker/daemon.json
  echo '# R36 (release), REVISION: 4.3, GCID: 0, BOARD: generic, EABI: aarch64' >"$NV_TEGRA_RELEASE"
  cat >"$NVPMODEL_CONF" <<'CONF'
< POWER_MODEL ID=0 NAME=MAXN >
< POWER_MODEL ID=2 NAME=MODE_15W >
CONF

  # 현재 15W 모드(ID 2), GUI 부팅, NVMe 루트, 컨테이너 없음, earlyoom/jtop 미설치
  stub nvpmodel '[[ $1 == -q ]] && printf "NV Power Mode: MODE_15W\n2\n"; exit 0'
  stub jetson_clocks
  stub systemctl '
case "$1" in
  get-default) echo graphical.target ;;
  is-enabled)  exit 0 ;;
esac
exit 0'
  stub swapon
  stub findmnt 'echo /dev/nvme0n1p1'
  stub dpkg 'exit 1'
  stub dpkg-query 'echo 6.2'
  stub docker
  stub nvidia-container-runtime
  # 혹시라도 호출되면 기록되도록 위험 명령도 모두 가짜로
  for c in apt-get pip3 fallocate mkswap sysctl; do stub "$c"; done
}

@test "--dry-run: 할 일과 되돌리기 방법을 보여 주고 아무것도 바꾸지 않는다" {
  run "$SCRIPTS/setup-performance.sh" --dry-run --headless --disable-zram
  [ "$status" -eq 0 ]
  [[ $output == *"[dry-run] nvpmodel -m 0"* ]]
  [[ $output == *"[dry-run] systemctl set-default multi-user.target"* ]]
  [[ $output == *'"default-runtime": "nvidia"'* ]]
  # 되돌리기 안내: 원래 전력 모드 ID 와 GUI 복귀
  [[ $output == *"sudo nvpmodel -m 2"* ]]
  [[ $output == *"sudo systemctl set-default graphical.target"* ]]
  refute_called "$MUTATING"
  [ ! -e "$JT_STATE_DIR" ]
  [ ! -e "$DOCKER_DAEMON_JSON" ]
}

@test "--dry-run 은 root 없이도 돈다" {
  JT_EUID=1000 run "$SCRIPTS/setup-performance.sh" --dry-run
  [ "$status" -eq 0 ]
  refute_called "$MUTATING"
}

@test "터미널이 아니면 --yes 없이 아무것도 바꾸지 않는다" {
  run "$SCRIPTS/setup-performance.sh" --headless </dev/null
  [ "$status" -ne 0 ]
  [[ $output == *"--yes"* ]]
  refute_called "$MUTATING"
}

@test "실제 실행: Docker 설정은 기존 키를 지키고, 원본 백업과 되돌리기 기록을 남긴다" {
  mkdir -p "$(dirname "$DOCKER_DAEMON_JSON")"
  echo '{"log-driver": "json-file"}' >"$DOCKER_DAEMON_JSON"
  run "$SCRIPTS/setup-performance.sh" --yes --no-clocks --swap-size 0 --no-earlyoom --no-jtop --headless
  [ "$status" -eq 0 ]
  python3 - "$DOCKER_DAEMON_JSON" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
assert d["default-runtime"] == "nvidia", d
assert d["log-driver"] == "json-file", d
PY
  grep -q json-file "$DOCKER_DAEMON_JSON.orig"
  assert_called '^nvpmodel -m 0'
  assert_called '^systemctl restart docker'
  assert_called '^systemctl set-default multi-user.target'
  grep -q 'graphical.target' "$JT_STATE_DIR/rollback.log"
  grep -q "$DOCKER_DAEMON_JSON.orig" "$JT_STATE_DIR/rollback.log"
}

@test "실행 중인 컨테이너가 있으면 Docker 를 재시작하지 않는다" {
  stub docker '[[ $1 == ps ]] && echo abc123; exit 0'
  run "$SCRIPTS/setup-performance.sh" --yes --no-clocks --swap-size 0 --no-earlyoom --no-jtop
  [ "$status" -eq 0 ]
  refute_called '^systemctl restart docker'
  [[ $output == *"재시작 보류"* ]]
}

@test "이미 nvidia 런타임이면 Docker 설정을 건드리지 않는다" {
  mkdir -p "$(dirname "$DOCKER_DAEMON_JSON")"
  printf '{"default-runtime":"nvidia","runtimes":{"nvidia":{"path":"x","runtimeArgs":[]}}}' >"$DOCKER_DAEMON_JSON"
  run "$SCRIPTS/setup-performance.sh" --yes --no-clocks --swap-size 0 --no-earlyoom --no-jtop
  [ "$status" -eq 0 ]
  [[ $output == *"이미 nvidia"* ]]
  [ ! -e "$DOCKER_DAEMON_JSON.orig" ]
  refute_called '^systemctl restart docker'
}
