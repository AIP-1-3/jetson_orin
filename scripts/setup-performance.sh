#!/usr/bin/env bash
# Jetson Orin 성능/안정성 기본 세팅 (재실행해도 안전하게 설계)
#
#  1) 최대 전력 모드(MAXN / MAXN_SUPER) 적용
#  2) 부팅 시 jetson_clocks 자동 적용 (클럭 고정 → 성능 편차 제거)
#  3) NVMe 스왑 파일 (통합 메모리 부족 대비)
#  4) earlyoom (메모리 고갈로 SSH까지 먹통되는 상황 방지 — 원격 장비에 필수)
#  5) jtop 모니터링 도구
#  6) Docker 기본 런타임을 nvidia 로 (GPU 컨테이너를 플래그 없이 사용)
#  7) (옵션) 헤드리스 부팅: GUI 데스크톱을 끄고 메모리 확보
#
# 사용법:
#   sudo ./scripts/setup-performance.sh [옵션]
#     --headless          부팅 시 GUI 비활성화 (원격 데스크톱은 xrdp가 별도 세션으로 제공)
#     --swap-size SIZE    스왑 파일 크기 (기본 16G, 0 이면 건너뜀)
#     --disable-zram      JetPack 기본 zram 비활성화 (NVMe 스왑을 쓸 때 권장, 재부팅 후 적용)
#     --no-clocks         jetson_clocks 자동 적용 건너뜀
#     --no-earlyoom       earlyoom 설치 건너뜀
#     --no-jtop           jtop 설치 건너뜀
#     --no-docker         Docker 런타임 설정 건너뜀
#     --dry-run           바꿀 내용만 보여 주고 아무것도 바꾸지 않음 (sudo 없이도 가능)
#     --yes               확인 질문 생략 (비대화형 실행용)
#
# 실행 전에 할 일 목록과 위험(재부팅 필요, 컨테이너 재시작 등)을 보여 주고 확인을 받는다.
# 끝나면 단계별 되돌리기 명령을 출력하고 /var/lib/jetson-team/rollback.log 에도 남긴다.
# 절전·자동 꺼짐 관련 설정(sleep/suspend target)은 건드리지 않는다.
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

HEADLESS=0
SWAP_SIZE=16G
DISABLE_ZRAM=0
DO_CLOCKS=1
DO_EARLYOOM=1
DO_JTOP=1
DO_DOCKER=1
NEED_REBOOT=0

usage() { sed -n '2,/^set -euo/p' "$0" | sed '$d; s/^# \{0,1\}//'; exit "${1:-0}"; }

while [[ $# -gt 0 ]]; do
  case $1 in
    --headless)     HEADLESS=1 ;;
    --swap-size)    SWAP_SIZE=${2:?--swap-size 값이 필요합니다}; shift ;;
    --disable-zram) DISABLE_ZRAM=1 ;;
    --no-clocks)    DO_CLOCKS=0 ;;
    --no-earlyoom)  DO_EARLYOOM=0 ;;
    --no-jtop)      DO_JTOP=0 ;;
    --no-docker)    DO_DOCKER=0 ;;
    --dry-run)      DRY_RUN=1 ;;
    --yes|-y)       ASSUME_YES=1 ;;
    -h|--help)      usage 0 ;;
    *)              warn "알 수 없는 옵션: $1"; usage 1 ;;
  esac
  shift
done

require_root
require_jetson

# 경로는 테스트에서 임시 디렉터리로 바꿀 수 있다
STATE_DIR=${JT_STATE_DIR:-/var/lib/jetson-team}
NVPMODEL_CONF=${NVPMODEL_CONF:-/etc/nvpmodel.conf}
DOCKER_DAEMON_JSON=${DOCKER_DAEMON_JSON:-/etc/docker/daemon.json}
run mkdir -p "$STATE_DIR"

log "장비: $(jetson_model) | L4T $(l4t_release) | JetPack $(jetpack_version) | Ubuntu $(ubuntu_version)"
log "루트 디스크: $(root_device)"

# ---------------------------------------------------------------------------
# 1) 전력 모드: nvpmodel.conf 에서 MAXN_SUPER > MAXN 순으로 ID를 찾는다.
#    모드 ID는 보드/JetPack 마다 달라서 하드코딩하지 않는다.
# ---------------------------------------------------------------------------
setup_power_mode() {
  local conf=$NVPMODEL_CONF id name current current_id
  [[ -r $conf ]] || { warn "$conf 없음 — 전력 모드 설정 건너뜀"; return; }

  for name in MAXN_SUPER MAXN; do
    id=$(sed -nE "s/^< *POWER_MODEL +ID=([0-9]+) +NAME=${name} *>.*/\1/p" "$conf" | head -n1)
    [[ -n $id ]] && break
  done
  [[ -n ${id:-} ]] || { warn "MAXN 모드를 찾지 못했습니다. 'nvpmodel -q --verbose' 로 확인하세요."; return; }

  current=$(nvpmodel -q 2>/dev/null | sed -nE 's/^NV Power Mode: *//p' | head -n1)
  current_id=$(nvpmodel -q 2>/dev/null | grep -xE '[0-9]+' | head -n1 || true)
  if [[ $current == "$name" ]]; then
    ok "전력 모드 이미 $name (ID=$id)"
    return
  fi

  log "전력 모드 변경: ${current:-unknown} → $name (ID=$id)"
  [[ -n $current_id ]] && rollback_note "전력 모드 (${current:-unknown} 로)" "sudo nvpmodel -m $current_id"
  # 일부 모드 전환은 재부팅을 요구하며 nvpmodel 이 YES/no 를 물어본다.
  # 원격 세션이 갑자기 끊기지 않도록 'no' 로 답하고, 적용 여부를 다시 확인한다.
  echo no | run nvpmodel -m "$id" || true
  [[ $DRY_RUN == 1 ]] && return
  current=$(nvpmodel -q 2>/dev/null | sed -nE 's/^NV Power Mode: *//p' | head -n1)
  if [[ $current == "$name" ]]; then
    ok "전력 모드 $name 적용 (재부팅 후에도 유지)"
  else
    warn "전력 모드는 재부팅 후 적용됩니다 (현재: ${current:-unknown})."
    NEED_REBOOT=1
  fi
}

# ---------------------------------------------------------------------------
# 2) jetson_clocks: 재부팅하면 풀리므로 systemd 서비스로 부팅 시 적용
# ---------------------------------------------------------------------------
setup_clocks() {
  local unit=/etc/systemd/system/jetson-maxclocks.service
  command -v jetson_clocks >/dev/null || { warn "jetson_clocks 없음 — 건너뜀"; return; }

  # 되돌리기용 기본값을 최초 1회 저장 (jetson_clocks --restore 파일로 복구)
  if [[ ! -s $STATE_DIR/jetson_clocks.default ]]; then
    run jetson_clocks --store "$STATE_DIR/jetson_clocks.default" >/dev/null
    ok "기본 클럭 값 저장: $STATE_DIR/jetson_clocks.default"
  fi

  write_file "$unit" <<EOF
[Unit]
Description=Lock Jetson clocks to maximum (jetson_clocks)
After=nvpmodel.service
Wants=nvpmodel.service

[Service]
Type=oneshot
# nvpmodel 적용이 끝난 뒤 클럭을 고정해야 덮어써지지 않는다
ExecStartPre=/bin/sleep 15
ExecStart=$(command -v jetson_clocks)
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
  run systemctl daemon-reload
  run systemctl enable jetson-maxclocks.service >/dev/null 2>&1
  run jetson_clocks
  rollback_note "jetson_clocks 고정 해제" \
    "sudo systemctl disable jetson-maxclocks.service && sudo rm $unit && sudo jetson_clocks --restore $STATE_DIR/jetson_clocks.default"
  ok "jetson_clocks 적용 + 부팅 시 자동 적용 등록 (jetson-maxclocks.service)"
}

# ---------------------------------------------------------------------------
# 3) 스왑 파일: SD카드/eMMC 에 만들면 수명을 깎으므로 NVMe 일 때만 기본 진행
# ---------------------------------------------------------------------------
setup_swap() {
  local swapfile=/swapfile bytes avail dev
  [[ $SWAP_SIZE == 0 ]] && { log "스왑 파일 건너뜀 (--swap-size 0)"; return; }

  if swapon --show=NAME --noheadings | grep -qx "$swapfile"; then
    ok "스왑 파일 이미 활성: $(swapon --show=NAME,SIZE --noheadings | grep "^$swapfile")"
    return
  fi

  dev=$(root_device)
  if [[ $dev != /dev/nvme* ]]; then
    warn "루트가 NVMe가 아닙니다($dev). SD/eMMC 수명 보호를 위해 스왑 파일을 만들지 않습니다."
    warn "NVMe SSD 로 루트를 옮기는 것이 성능 측면에서 가장 큰 개선입니다 (docs/03-performance.md)."
    return
  fi

  bytes=$(numfmt --from=iec "$SWAP_SIZE") || die "잘못된 스왑 크기: $SWAP_SIZE"
  avail=$(df --output=avail -B1 / | tail -n1)
  (( avail > bytes * 2 )) || { warn "디스크 여유 공간 부족 — 스왑 파일 건너뜀"; return; }

  log "스왑 파일 생성: $swapfile ($SWAP_SIZE)"
  if [[ -e $swapfile ]]; then
    die "$swapfile 가 이미 있지만 스왑으로 쓰이고 있지 않습니다. 확인 후 지우고 다시 실행하세요."
  fi
  run fallocate -l "$bytes" "$swapfile"
  run chmod 600 "$swapfile"
  run mkswap "$swapfile" >/dev/null
  run swapon "$swapfile"
  grep -qE "^${swapfile}[[:space:]]" /etc/fstab || echo "$swapfile none swap sw 0 0" | write_file --append /etc/fstab
  ok "스왑 파일 활성화 + /etc/fstab 등록"

  # 통합 메모리 구조에서는 스왑을 너무 일찍 쓰면 GPU 작업이 느려진다
  echo 'vm.swappiness=10' | write_file /etc/sysctl.d/90-jetson-team-swap.conf
  run sysctl -q -p /etc/sysctl.d/90-jetson-team-swap.conf
  rollback_note "스왑 파일 제거" \
    "sudo swapoff $swapfile && sudo sed -i '\\|^$swapfile |d' /etc/fstab && sudo rm $swapfile /etc/sysctl.d/90-jetson-team-swap.conf"
}

setup_zram() {
  [[ $DISABLE_ZRAM == 1 ]] || return 0
  if systemctl is-enabled nvzramconfig.service >/dev/null 2>&1; then
    run systemctl disable nvzramconfig.service >/dev/null 2>&1
    rollback_note "zram 다시 켜기 (재부팅 후 적용)" "sudo systemctl enable nvzramconfig.service"
    ok "zram 비활성화 (재부팅 후 적용)"
    NEED_REBOOT=1
  else
    ok "zram 이미 비활성 또는 없음"
  fi
}

# ---------------------------------------------------------------------------
# 4) earlyoom: 메모리 고갈 시 시스템 전체가 멈추기 전에 가장 큰 프로세스를 정리
# ---------------------------------------------------------------------------
setup_earlyoom() {
  local conf=/etc/default/earlyoom
  if ! dpkg -s earlyoom >/dev/null 2>&1; then
    log "earlyoom 설치"
    run apt-get install -y earlyoom >/dev/null
  fi
  if [[ -e $conf.orig || -e $conf ]]; then
    rollback_note "earlyoom 설정 원복" "sudo cp -a $conf.orig $conf && sudo systemctl restart earlyoom"
  else
    rollback_note "earlyoom 제거" "sudo apt-get remove earlyoom"
  fi
  backup_once "$conf"
  # systemd 가 이 값을 공백으로만 나누므로 정규식에 공백/따옴표/$ 를 쓰지 않는다.
  # sshd·tailscaled 등 원격 접속 경로는 절대 죽이지 않게 보호한다.
  write_file "$conf" <<'EOF'
# managed by jetson_orin/scripts/setup-performance.sh
EARLYOOM_ARGS="-r 3600 --avoid=^(sshd|tailscaled|systemd|xrdp|Xorg|dockerd|containerd)"
EOF
  run systemctl enable earlyoom >/dev/null 2>&1
  run systemctl restart earlyoom
  ok "earlyoom 활성 (원격 접속 프로세스 보호 설정)"
}

# ---------------------------------------------------------------------------
# 5) jtop (jetson-stats)
# ---------------------------------------------------------------------------
setup_jtop() {
  if command -v jtop >/dev/null; then
    ok "jtop 이미 설치됨"
    return
  fi
  log "jtop(jetson-stats) 설치"
  run apt-get install -y python3-pip >/dev/null
  # Ubuntu 24.04(JetPack 7)는 PEP 668 때문에 시스템 pip 설치에 플래그가 필요하다
  if ! run pip3 install -U jetson-stats >/dev/null 2>&1; then
    run pip3 install -U --break-system-packages jetson-stats >/dev/null 2>&1 \
      || { warn "jtop 설치 실패 — 'sudo pip3 install -U jetson-stats' 를 직접 시도하세요."; return; }
  fi
  run systemctl restart jtop.service 2>/dev/null || true
  rollback_note "jtop 제거" "sudo pip3 uninstall jetson-stats"
  ok "jtop 설치 (팀원은 jtop 그룹에 추가되어야 사용 가능 — add-team-member.sh 가 처리)"
}

# ---------------------------------------------------------------------------
# 6) Docker 기본 런타임 = nvidia
# ---------------------------------------------------------------------------
setup_docker() {
  local f=$DOCKER_DAEMON_JSON after running
  command -v docker >/dev/null || { log "Docker 미설치 — 건너뜀"; return; }
  command -v nvidia-container-runtime >/dev/null \
    || { warn "nvidia-container-runtime 없음 — 'sudo apt install nvidia-container-toolkit' 후 재실행"; return; }

  # 바뀔 내용을 먼저 계산한다 (이미 nvidia 면 빈 문자열). 파일은 write_file 로만 쓴다.
  after=$(python3 - "$f" <<'PY'
import json, os, sys
path = sys.argv[1]
data = {}
if os.path.exists(path) and os.path.getsize(path) > 0:
    with open(path) as fh:
        data = json.load(fh)
new = json.loads(json.dumps(data))
new.setdefault("runtimes", {}).setdefault(
    "nvidia", {"path": "nvidia-container-runtime", "runtimeArgs": []})
new["default-runtime"] = "nvidia"
if new != data:
    print(json.dumps(new, indent=2))
PY
) || die "$f 를 읽지 못했습니다 (JSON 문법 확인)."
  if [[ -z $after ]]; then
    ok "Docker 기본 런타임 이미 nvidia"
    return
  fi

  if [[ -e $f ]]; then
    rollback_note "Docker 설정 원복 (컨테이너 재시작됨)" "sudo cp -a $f.orig $f && sudo systemctl restart docker"
  else
    rollback_note "Docker 설정 원복 (컨테이너 재시작됨)" "sudo rm $f && sudo systemctl restart docker"
  fi
  run mkdir -p "$(dirname "$f")"
  backup_once "$f"
  printf '%s\n' "$after" | write_file "$f"

  # 팀원이 돌리는 컨테이너를 죽이지 않도록, 실행 중인 컨테이너가 있으면 재시작하지 않는다
  running=$(docker ps -q 2>/dev/null | wc -l)
  if (( running > 0 )); then
    warn "실행 중인 컨테이너 ${running}개 — Docker 재시작 보류. 팀원과 조율 후: sudo systemctl restart docker"
  else
    run systemctl restart docker
    ok "Docker 기본 런타임 nvidia 적용"
  fi
}

# ---------------------------------------------------------------------------
# 7) 헤드리스: GDM/GNOME 이 쓰는 메모리(대략 0.8~1.5GB)를 작업에 돌려준다
# ---------------------------------------------------------------------------
setup_headless() {
  [[ $HEADLESS == 1 ]] || return 0
  if [[ $(systemctl get-default) == multi-user.target ]]; then
    ok "이미 헤드리스 부팅 (multi-user.target)"
  else
    run systemctl set-default multi-user.target >/dev/null
    rollback_note "GUI 부팅으로 복귀 (재부팅 후 적용)" "sudo systemctl set-default graphical.target"
    ok "헤드리스 부팅으로 변경 (재부팅 후 적용)"
    NEED_REBOOT=1
  fi
}

# ---------------------------------------------------------------------------
# 실행 전 확인: 원격 장비라 무엇이 바뀌고 무엇이 위험한지 먼저 보여 준다
# ---------------------------------------------------------------------------
log "할 일"
echo "  - 전력 모드 MAXN 계열로 변경 (모드에 따라 재부팅 후 적용)"
[[ $DO_CLOCKS == 1 ]]    && echo "  - jetson_clocks 클럭 고정 + 부팅 시 자동 적용 (발열·소비전력 증가)"
[[ $SWAP_SIZE != 0 ]]    && echo "  - NVMe 스왑 파일 $SWAP_SIZE"
[[ $DISABLE_ZRAM == 1 ]] && echo "  - zram 비활성화 (재부팅 후 적용)"
[[ $DO_EARLYOOM == 1 ]]  && echo "  - earlyoom 설치/재시작 (sshd·tailscaled 는 보호 목록에 포함)"
[[ $DO_JTOP == 1 ]]      && echo "  - jtop 설치"
[[ $DO_DOCKER == 1 ]]    && echo "  - Docker 기본 런타임 nvidia (실행 중인 컨테이너가 있으면 재시작 보류)"
[[ $HEADLESS == 1 ]]     && echo "  - 부팅 시 GUI 끄기 (원격 데스크톱은 xrdp 로 계속 사용 가능)"
[[ $DRY_RUN == 1 ]] && log "dry-run: 실제로는 아무것도 바꾸지 않습니다."
confirm "진행할까요? (SSH·Tailscale 설정은 바꾸지 않습니다)" || die "취소했습니다. 아무것도 바꾸지 않았습니다."

setup_power_mode
[[ $DO_CLOCKS == 1 ]] && setup_clocks
setup_swap
setup_zram
if [[ $DO_EARLYOOM == 1 || $DO_JTOP == 1 ]]; then run apt-get update -qq; fi
[[ $DO_EARLYOOM == 1 ]] && setup_earlyoom
[[ $DO_JTOP == 1 ]] && setup_jtop
[[ $DO_DOCKER == 1 ]] && setup_docker
setup_headless

echo
if [[ $DRY_RUN == 1 ]]; then
  ok "dry-run 끝. 위 [dry-run] 줄이 실제 실행 시 바뀌는 내용입니다."
else
  ok "성능 세팅 완료. 상태 확인: ./scripts/healthcheck.sh"
fi
print_rollback_notes "$STATE_DIR/rollback.log"
if [[ $NEED_REBOOT == 1 ]]; then
  warn "재부팅이 필요한 변경이 있습니다. 팀원에게 알린 뒤: sudo reboot"
fi
