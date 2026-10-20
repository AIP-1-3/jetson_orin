#!/usr/bin/env bash
# Jetson 상태 한눈에 보기 (sudo 없이 실행 가능)
#   ./scripts/healthcheck.sh
# 원격에서 "느리다/멈춘다" 싶을 때 가장 먼저 돌려보고, 결과를 팀 채널에 붙여넣으면 된다.
set -uo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

section() { printf '\n%s── %s %s\n' "$C_BLUE" "$1" "$C_RESET"; }
svc() {
  local state
  state=$(systemctl is-active "$1" 2>/dev/null) || true
  printf '  %-26s %s\n' "$1" "${state:-not-found}"
}

section "장비"
if is_jetson; then
  echo "  모델     : $(jetson_model)"
  echo "  L4T      : $(l4t_release)"
  echo "  JetPack  : $(jetpack_version)"
else
  warn "Jetson 이 아닌 환경입니다 — 일부 항목은 비어 있습니다."
fi
echo "  OS       : Ubuntu $(ubuntu_version) / kernel $(uname -r)"
echo "  가동시간 : $(uptime -p)"
echo "  부팅모드 : $(systemctl get-default 2>/dev/null)"
echo "  루트디스크: $(root_device)"

section "전력/클럭"
if command -v nvpmodel >/dev/null; then
  mode=$(nvpmodel -q 2>/dev/null | sed -nE 's/^NV Power Mode: *//p' | head -n1)
  echo "  전력 모드: ${mode:-확인 불가 (sudo nvpmodel -q)}"
fi
if command -v tegrastats >/dev/null; then
  # 1회 샘플: RAM, SWAP, CPU별 사용률, GPU(GR3D_FREQ), 온도, 전력
  sample=$(timeout 3 tegrastats --interval 1000 2>/dev/null | head -n1)
  echo "  tegrastats: ${sample:-확인 불가}"
fi

section "온도"
for z in /sys/devices/virtual/thermal/thermal_zone*; do
  [[ -r $z/type && -r $z/temp ]] || continue
  t=$(<"$z/temp")
  (( t > 0 )) && printf '  %-14s %5.1f°C\n' "$(<"$z/type")" "$(awk "BEGIN{print $t/1000}")"
done

section "메모리 (CPU·GPU 공유)"
free -h | sed 's/^/  /'
swapon --show 2>/dev/null | sed 's/^/  /'

section "디스크"
df -h / /home 2>/dev/null | awk 'NR==1 || !seen[$0]++' | sed 's/^/  /'

section "메모리 상위 프로세스"
ps -eo user:12,pid,etime,rss:10,comm --sort=-rss 2>/dev/null | head -n 8 \
  | awk 'NR==1{print "  "$0; next}{printf "  %-12s %7s %11s %8.0fMB %s\n",$1,$2,$3,$4/1024,$5}'

section "접속 중인 사용자"
who | sed 's/^/  /'
if [[ -x $SCRIPT_DIR/gpu-run.sh ]]; then
  echo "  $("$SCRIPT_DIR/gpu-run.sh" --status)"
fi

section "Tailscale"
if command -v tailscale >/dev/null; then
  echo "  IP  : $(tailscale ip -4 2>/dev/null | head -n1)"
  tailscale status 2>/dev/null | head -n 10 | sed 's/^/  /'
else
  warn "tailscale 미설치"
fi

section "서비스"
for s in ssh tailscaled jetson-maxclocks earlyoom jtop xrdp docker nvzramconfig; do svc "$s"; done
section "꺼짐 방지 (절전 차단 여부 — masked 면 차단됨)"
for t in sleep.target suspend.target hibernate.target hybrid-sleep.target; do
  state=$(systemctl is-enabled "$t" 2>/dev/null) || true
  printf '  %-26s %s\n' "$t" "${state:-unknown}"
done
echo
