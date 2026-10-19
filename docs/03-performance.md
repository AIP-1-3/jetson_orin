# 03. 성능 최적화 + 원격 장비 안정성

Jetson 성능은 **전력 모드 → 저장장치 → 메모리 → 발열** 순으로 영향이 크다.
원격 전용 장비라서 **"멈추지 않게"** 하는 설정도 성능만큼 중요하다. 멈추면 아무도 고칠 수 없다.

## 한 번에 적용

```bash
sudo ./scripts/setup-performance.sh --headless --disable-zram   # NVMe 루트 기준 권장 조합
sudo reboot
./scripts/healthcheck.sh
```

| 단계 | 내용 | 효과 | 되돌리기 |
|---|---|---|---|
| 전력 모드 | `nvpmodel` 로 MAXN_SUPER 또는 MAXN (보드별 ID 자동 탐지) | CPU/GPU 코어·클럭 상한 해제 | `sudo nvpmodel -m <ID>` (`nvpmodel -q --verbose`로 목록) |
| 클럭 고정 | `jetson_clocks` + 부팅 시 자동 적용 서비스 | DVFS 지연 제거, 벤치마크 편차 감소 | `sudo systemctl disable jetson-maxclocks` + `sudo jetson_clocks --restore /var/lib/jetson-team/jetson_clocks.default` |
| 스왑 | NVMe 에 16GB `/swapfile`, `swappiness=10` | 대형 모델 로딩/빌드 중 OOM 방지 | `/etc/fstab` 에서 줄 삭제 후 재부팅 |
| zram 끄기 (옵션) | JetPack 기본 zram 비활성 | 압축 스왑의 CPU 부하 제거 (NVMe 스왑이 있을 때) | `sudo systemctl enable nvzramconfig` |
| earlyoom | 메모리 고갈 직전 가장 큰 프로세스 정리, sshd/tailscaled 보호 | **장비 전체 멈춤 → 원격 접속 불가** 상황 방지 | `sudo systemctl disable --now earlyoom` |
| jtop | `jetson-stats` 설치 | 실시간 모니터링 | `sudo pip3 uninstall jetson-stats` |
| Docker | 기본 런타임 `nvidia` | `--runtime nvidia` 없이도 컨테이너에서 GPU 사용 | `/etc/docker/daemon.json.orig` 복원 |
| 헤드리스 (옵션) | GUI 데스크톱 끄기 | 약 1GB 안팎 메모리 확보 | `sudo systemctl set-default graphical.target` |

## 1. 저장장치: 가장 큰 체감 차이

- 루트가 **SD 카드**라면 NVMe SSD 로 옮기는 것이 단일 개선 중 효과가 가장 크다 (pip 설치, Docker 이미지, 데이터 로딩 모두 빨라짐).
- 확인: `./scripts/healthcheck.sh` 의 "루트디스크" 가 `/dev/nvme...` 인지.
- 옮기는 방법은 JetPack 버전에 따라 다르다: SDK Manager 로 NVMe 에 직접 플래시하는 것이 가장 확실하다.
  (원격으로는 불가능 — 장비 앞에 있을 때 작업)

## 2. 메모리: 통합 메모리 이해하기

- CPU 와 GPU 가 같은 RAM 을 쓴다. `free -h` 의 여유 = GPU 가 쓸 수 있는 여유.
- 메모리를 먹는 것들: GNOME 데스크톱(헤드리스로 해결), VS Code Server(접속자당 수백 MB), Claude Code 세션, Docker 컨테이너, xrdp 세션(로그아웃 안 하면 계속 남음).
- **두 명이 동시에 큰 GPU 작업** → 장비 멈춤의 가장 흔한 원인. `./scripts/gpu-run.sh -- <명령>` 으로 순서를 세운다.

## 3. 발열

- `jetson_clocks` 는 최대 클럭을 유지하므로 발열이 늘어난다. 쿨러/방열판이 제대로 붙어 있는지, 통풍되는 곳인지 확인.
- `healthcheck.sh` 온도가 장시간 85°C 이상이면 스로틀링(자동 감속)이 걸려 오히려 느려진다 → 위치/쿨링 개선 또는 한 단계 낮은 전력 모드.

## 4. 원격 전용 장비 생존 수칙

| 위험 | 대비 |
|---|---|
| 정전/멈춤 후 아무도 전원 버튼을 못 누름 | **스마트 플러그**(원격 전원 차단/인가) + 전원 인가 시 자동 부팅되는지 장비 앞에서 한 번 테스트 |
| 메모리 고갈로 SSH 먹통 | earlyoom (적용됨), gpu-run.sh |
| Tailscale 키 만료로 접속 불가 | `tag:jetson` 태그 (docs/01) |
| 누군가 업그레이드/재부팅 | `.claude/settings.json` 에서 Claude 가 실행 못 하게 막아둠 + 팀 규칙 (docs/04) |
| 업데이트로 JetPack 깨짐 | `do-release-upgrade` 금지, `apt upgrade` 는 팀 공지 후 관리자만 |
| 공유기 재부팅/IP 변경 | Tailscale 은 IP 가 바뀌어도 자동 재연결 — 별도 조치 불필요 |

## 참고

- [JetPack 6.2.2 / Jetson Linux 36.5 (2026-02)](https://forums.developer.nvidia.com/c/robotics-edge-computing/jetson-systems/announcements/71)
- [JetPack 7.2 — Orin 지원 발표 (JetsonHacks, GTC 2026 Taipei)](https://jetsonhacks.com/2026/05/31/gtc-2026-taipei/amp/)
