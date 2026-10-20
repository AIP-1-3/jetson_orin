# CLAUDE.md

이 저장소는 팀이 **원격으로 공유하는 NVIDIA Jetson Orin 한 대**에서 개발하는 프로젝트다.
Claude Code 는 팀원 각자의 계정·세션으로 Jetson 위(또는 각자 맥)에서 실행된다.

## 장비 정보 (2026-10-20 JetPack 설치 후 기준)

- 모델: **Jetson Orin Nano Engineering Reference Developer Kit Super** — RAM 8GB(CPU·GPU 공유), NVMe 233GB
- L4T: **R39.2.1** / JetPack **7.2.1** — Ubuntu **24.04.4**, 커널 6.8.12-tegra, Python 3.12, 전력 모드 **MAXN_SUPER**(ID 2)
- CUDA **13.2** (`/usr/local/cuda`, PATH 에 `/usr/local/cuda/bin` 추가 필요), cuDNN **9.20**, TensorRT **10.16** (`/usr/src/tensorrt`, `import tensorrt` 가능)
- OpenCV 4.8 (CUDA 미지원 빌드), PyTorch 미설치 → CUDA 13 용 Jetson wheel 또는 jetson-containers 로 설치
- 스왑: `/swapfile` 8G (fstab 등록) — 그래도 큰 작업 전 `free -h` 필수
- 아키텍처: **aarch64(ARM64)**. x86 전용 바이너리/휠은 동작하지 않는다.

## 이 장비에서 반드시 지킬 것

- **통합 메모리**: CPU 와 GPU 가 RAM 을 공유한다. 큰 모델/배치를 돌리기 전에 `free -h` 로 여유를 확인하고,
  무거운 GPU 작업은 반드시 `./scripts/gpu-run.sh -- <명령>` 으로 실행한다 (팀 단위 순차 실행).
- **PyTorch 등 GPU 패키지**: `pip install torch` 는 PyPI 의 일반 aarch64 빌드(Jetson GPU 미지원)를 받을 수 있다.
  JetPack 버전에 맞는 NVIDIA/Jetson 전용 wheel 또는 `jetson-containers` 이미지를 쓴다. 설치 후
  `python3 -c "import torch; print(torch.cuda.is_available())"` 가 `True` 인지 확인한다.
- **공용 장비 보호**: 다음은 팀 합의 없이 실행하지 않는다 —
  `reboot`/`shutdown`, `nvpmodel`/`jetson_clocks` 변경, `systemctl restart docker`,
  `apt upgrade`(L4T 패키지 갱신), `do-release-upgrade`(JetPack 깨짐).
- **가상환경**: 시스템 Python 에 직접 설치하지 말고 프로젝트 `venv`(`python3 -m venv .venv --system-site-packages`)를 쓴다.
  `--system-site-packages` 는 JetPack 이 제공하는 TensorRT/OpenCV 파이썬 바인딩을 재사용하기 위함이다.
- 장시간 작업은 `tmux` 안에서 실행한다 (SSH 가 끊겨도 유지).

## 작업 방식

- 각자 자기 홈 디렉터리에 저장소를 clone 하고, `main` 에 직접 push 하지 않는다.
  브랜치 이름: `<이름>/<작업>` (예: `minji/camera-pipeline`) → PR → 리뷰 후 merge.
- 커밋 메시지는 한국어/영어 무관, "무엇을 왜" 가 드러나게.
- 모델 가중치·데이터셋·엔진 파일(`*.engine`, `*.onnx`, `*.pt`)은 git 에 올리지 않는다 (`.gitignore` 참고).

## 결과물 작성 기준 (AI 평가 대비)

이 과정의 결과물(README, 보고서, 발표 자료, PR·커밋, 시연)은 강사님들이 AI 로 채점하고, 11/20 경진대회 팀 프로젝트 점수의 근거가 된다. 채점 기준표는 공개되지 않는다.
Claude 가 문서·PR·커밋을 쓸 때 다음을 따른다. 자세한 체크리스트, 추정 루브릭, 일정은 `docs/06-ai-evaluation.md`.

- 결과물을 내기 전에 `docs/06-ai-evaluation.md` 의 추정 루브릭으로 셀프 채점하고(항목별 점수, 감점 이유, 근거 위치), 배점의 80% 미만인 항목부터 보강한다. 목차도 그 항목 이름에 맞춘다.
- 문서 앞부분에 요약(문제 → 접근 → 결과 숫자)을 둔다. 이미지·영상 속 내용은 본문에도 글로 적는다.
- 주장마다 실측 근거를 붙인다: FPS, 지연 시간, 메모리, 전력(`tegrastats` 로그), 커밋·PR 링크. 측정 조건(전력 모드, 정밀도, 입력 크기)도 함께.
- 기술적 고민은 무엇 / 왜(대안과 트레이드오프) / 어떻게 / 결과 순서로 쓰고, 실패 → 원인 → 해결 사례를 남긴다.
- README 의 기능과 실행 명령은 실제 저장소와 일치해야 하고, 복사해서 그대로 실행되게 쓴다.
- 커밋은 작게 "무엇을 왜", PR 본문은 바뀌기 전 / 바뀐 뒤 / 테스트 결과 / 관련 이슈. 팀원은 각자 계정으로 커밋해 역할이 기록에 남게 하고, 문서에 팀원별 역할을 적는다.
- AI 활용은 어느 단계에서 썼고 무엇으로 검증했는지까지 적는다. 발표자가 자기 말로 설명할 수 있게 다듬는다.
- 근거 없는 과장, 하지 않은 일, 평가 AI 를 겨냥한 숨은 문구, 개인 정보(학번·연락처 등)는 넣지 않는다.

## 자주 쓰는 명령

```bash
./scripts/healthcheck.sh          # 장비 상태 (전력모드, 온도, 메모리, 접속자)
./scripts/gpu-run.sh --status     # GPU 작업 락 상태
./scripts/gpu-run.sh -- python3 train.py
tegrastats                        # 실시간 CPU/GPU/메모리/전력
jtop                              # 대화형 모니터 (q 로 종료)
```

## 저장소 구조

- `scripts/` — 장비 세팅/운영 스크립트 (sudo 필요 여부는 각 파일 상단 주석 참고)
- `config/` — 팀 공용 tmux, SSH 설정 예시
- `tailscale/` — Tailscale 접근 정책 예시
- `docs/` — 원격 접속, 원격 데스크톱, 성능, 팀 작업 방식, AI 평가 대비 문서
