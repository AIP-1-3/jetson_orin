# 04. 팀 작업 방식 (Claude Code + Git + 공용 장비 규칙)

## 1. 어디서 Claude Code 를 돌릴까

| 방식 | 언제 | 장점 | 주의 |
|---|---|---|---|
| **Jetson 위 tmux 안에서 실행 (기본)** | CUDA/카메라/TensorRT 등 장비 의존 작업 | Claude 가 직접 빌드·실행·`tegrastats` 확인까지 함 | 세션당 메모리 사용 → 다 쓰면 종료 |
| VS Code Remote-SSH + Claude Code 확장 | 에디터 화면으로 diff 보면서 작업 | 익숙한 UI | VS Code Server 가 접속자당 수백 MB |
| 맥 로컬에서 실행, Jetson 은 git pull 후 실행만 | 문서/웹/순수 로직 작업 | Jetson 자원 사용 0 | 장비 의존 코드는 검증 불가 |

## 2. Claude Code 설치 (팀원 각자, 각자 계정)

계정은 **절대 공유하지 않는다.** 각자 Jetson 리눅스 계정에서 본인 Claude 계정으로 로그인한다.

```bash
ssh jetson
curl -fsSL https://claude.ai/install.sh | bash   # ARM64(aarch64) 자동 지원
claude --version
claude doctor
```

## 3. 하루 작업 흐름

```bash
ssh jetson
tmux new -A -s work                 # 있으면 다시 붙고, 없으면 새로 만든다
cd ~/jetson_orin && git pull
git switch -c <이름>/<작업>          # 예: minji/yolo-tensorrt
claude                              # CLAUDE.md 를 읽고 장비 규칙을 따른다
# ... 작업 ...
git push -u origin <이름>/<작업>     # → GitHub 에서 PR
# 자리 비울 때: Ctrl-b d  (tmux 에서 빠져나오기 — 작업은 계속 돈다)
```

처음 한 번: `git clone https://github.com/AIP-1-3/jetson_orin.git ~/jetson_orin`

## 4. 공용 장비 규칙 (팀 합의용 초안)

1. **무거운 GPU 작업은 `./scripts/gpu-run.sh -- <명령>`** 으로만. 순서대로 실행되고, 겹치면 자동 대기한다.
2. **재부팅·전력 모드 변경·Docker 재시작·apt upgrade** 는 팀 채널에 공지 → 관리자가 실행.
   Claude 는 `.claude/settings.json` 에 의해 이 명령들이 차단돼 있다.
3. 작업 끝나면: Claude 세션 종료, xrdp 는 **로그아웃**, 안 쓰는 Docker 컨테이너 정리.
4. 장비가 느리면 먼저 `./scripts/healthcheck.sh` 결과를 채널에 붙여넣는다.
5. 데이터셋/모델은 git 대신 Jetson 공용 디렉터리(예: `/data`, 관리자가 생성)에 둔다.

## 5. Git 규칙

- `main` 보호: GitHub → Settings → Branches → *Require a pull request before merging* 켜기 권장.
- PR 은 작게, 리뷰어 1명 이상.
- `CLAUDE.md` 의 "장비 정보" 는 첫 세팅 후 관리자가 채워서 PR 로 올린다 — 이후 모든 팀원의 Claude 가 같은 맥락으로 작업한다.

## 참고

- [Claude Code 설치 문서](https://code.claude.com/docs/en/setup)
