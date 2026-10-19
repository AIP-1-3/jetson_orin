# 02. 원격 데스크톱 (Thincast + xrdp)

## 핵심: Thincast 는 "클라이언트"다

Thincast Client 는 맥/윈도우/리눅스용 **RDP 클라이언트**다. Jetson 화면을 받으려면 Jetson 쪽에 **RDP 서버**가 있어야 한다.
이 저장소는 **xrdp + XFCE** 를 쓴다.

| 선택지 | 모니터 없이(헤드리스) | 사용자별 독립 세션 | 메모리 | 비고 |
|---|---|---|---|---|
| **xrdp + XFCE (채택)** | O | O (팀원마다 따로) | 가벼움 | Thincast/Windows App 등 아무 RDP 클라이언트로 접속 |
| GNOME 원격 데스크톱 | X (더미 HDMI 필요) | X (화면 하나 공유) | 무거움 | 실제 모니터 화면을 그대로 보여야 할 때 |
| NoMachine | O | 유료 플랜에서 | 보통 | ARM64 빌드 제공, 영상/카메라 미리보기가 부드러운 편 |

> **GUI 는 필요할 때만.** 코딩·빌드·학습은 SSH(터미널, VS Code Remote-SSH, Claude Code)가 훨씬 빠르고 가볍다.
> GUI 는 카메라 미리보기, 시각화 도구, GUI 전용 툴을 쓸 때만 띄운다. 다 쓰면 **로그아웃**(창 닫기 아님)해서 메모리를 돌려준다.

## 1. Jetson 세팅 (관리자, 한 번만)

```bash
# (권장) 헤드리스 부팅: GNOME 이 쓰던 메모리를 작업에 돌려주고, xrdp 검은 화면 문제도 예방
sudo ./scripts/setup-performance.sh --headless
# xrdp + XFCE 설치/튜닝
sudo ./scripts/setup-remote-desktop.sh
sudo reboot
```

원격 데스크톱 로그인에는 리눅스 **비밀번호**가 필요하다. `add-team-member.sh` 가 계정 생성 시 설정한다.

## 2. 맥에서 Thincast 로 접속

1. Thincast Client 실행 → 새 연결
2. 주소: `jetson-orin` (Tailscale MagicDNS 이름, 포트 3389 기본값)
3. 사용자/비밀번호: Jetson 리눅스 계정
4. 체감 속도 개선 (메뉴에 있는 항목만):
   - 해상도는 맥 화면 전체보다 **한 단계 낮게** (예: 1600×900) — 전송량이 크게 준다
   - 색 깊이 24bit (서버도 24bit 로 맞춰 둠), 배경화면/애니메이션 끄기
   - 네트워크 유형을 "LAN" 대신 실제 환경(브로드밴드 등)에 맞게

## 3. 성능 참고

- xrdp 화면 전송은 **CPU** 로 인코딩한다. Orin Nano 는 하드웨어 영상 인코더(NVENC)가 없어서
  화면이 큰 변화(영상 재생)를 보일 때 CPU 를 꽤 쓴다. 학습 중에는 GUI 를 내려두는 편이 낫다.
- 카메라/추론 결과를 "보기만" 할 거라면 GUI 대신 **웹 스트리밍**(예: 추론 결과를 MJPEG/WebRTC 로 8000번대 포트에 띄우고
  맥 브라우저로 `http://jetson-orin:8080` 접속)이 훨씬 가볍다. ACL 정책에 8000–8999 포트를 열어둔 이유다.

## 4. 문제 해결

| 증상 | 원인/해결 |
|---|---|
| 로그인 직후 검은 화면 또는 바로 끊김 | 같은 계정이 모니터(GDM)에도 로그인돼 있음 → 헤드리스 전환 또는 로컬 로그아웃. `~/.xsession` 내용이 `xfce4-session` 인지 확인 |
| "color managed device" 인증 창 반복 | `setup-remote-desktop.sh` 재실행 (polkit 규칙 설치) |
| 접속 자체가 안 됨 | `systemctl status xrdp`, Tailscale ACL 에 `tcp:3389` 허용 여부 |
| 로그 | `/var/log/xrdp.log`, `/var/log/xrdp-sesman.log`, `~/.xsession-errors` |

## 참고

- [Thincast 제품 목록](https://thincast.com/en/products) — Client(무료). 나머지는 Workstation(Windows)·게이트웨이·웹 액세스 제품이라 Jetson 의 RDP 서버 역할은 하지 않는다
- [Thincast Client (Flathub, aarch64 지원)](https://flathub.org/apps/com.thincast.client)
