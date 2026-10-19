#!/usr/bin/env bash
# 무거운 GPU 작업(학습/대형 모델 추론/TensorRT 빌드)을 팀 전체에서 한 번에 하나씩 실행
#
# Jetson 은 CPU·GPU 가 같은 메모리를 나눠 쓴다(통합 메모리).
# 두 사람이 동시에 큰 작업을 돌리면 메모리가 바닥나 장비 전체가 멈추고,
# 원격에서는 SSH 조차 안 되는 상황이 된다. 이 스크립트는 파일 락으로 순서를 세운다.
#
# 사용법:
#   ./scripts/gpu-run.sh [--wait-max SEC] -- <명령...>
#   ./scripts/gpu-run.sh --status
# 예:
#   ./scripts/gpu-run.sh -- python3 train.py --epochs 10
#   ./scripts/gpu-run.sh --wait-max 600 -- trtexec --onnx=model.onnx --saveEngine=model.engine
set -euo pipefail

LOCK=/tmp/jetson-gpu.lock
WAIT_MAX=""

usage() { sed -n '2,/^set -euo/p' "$0" | sed '$d; s/^# \{0,1\}//'; exit "${1:-0}"; }

open_lock() {
  # /tmp 는 sticky + fs.protected_regular 때문에 남이 만든 파일을 O_CREAT 로 열 수 없다.
  # 이미 있으면 읽기 전용으로 연다 (flock 은 읽기 전용 fd 로도 배타 락이 걸린다).
  if [[ -e $LOCK ]]; then
    exec 9<"$LOCK"
  else
    (umask 000; : >"$LOCK") 2>/dev/null || true
    exec 9<"$LOCK"
  fi
}

case ${1:-} in
  --status)
    open_lock
    if flock -n 9; then
      echo "GPU 락: 비어 있음"
    else
      echo "GPU 락: 사용 중 — 'jtop' 또는 'ps -eo user,pid,etime,rss,cmd --sort=-rss | head' 로 확인"
    fi
    exit 0 ;;
  -h|--help|"") usage 0 ;;
esac

while [[ $# -gt 0 ]]; do
  case $1 in
    --wait-max) WAIT_MAX=${2:?--wait-max 값이 필요합니다}; shift ;;
    --)         shift; break ;;
    *)          break ;;
  esac
  shift
done
[[ $# -gt 0 ]] || usage 1

open_lock
if ! flock -n 9; then
  echo "[gpu-run] 다른 팀원의 GPU 작업이 실행 중입니다. 끝날 때까지 대기합니다..." >&2
  if [[ -n $WAIT_MAX ]]; then
    flock -w "$WAIT_MAX" 9 || { echo "[gpu-run] ${WAIT_MAX}초 대기 후 포기" >&2; exit 75; }
  else
    flock 9
  fi
fi

echo "[gpu-run] $(whoami) 실행 시작: $*" >&2
# exec 로 실행해 락(fd 9)을 명령이 끝날 때까지 들고 있게 한다. 명령이 죽으면 락도 자동 해제된다.
exec "$@"
