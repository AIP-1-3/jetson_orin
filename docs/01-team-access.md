# 01. 팀 원격 접속 (Tailscale + SSH)

목표: 팀원 누구나 **어디서든** `ssh jetson` 한 줄로 접속하되, **Jetson 말고 다른 기기(내 맥 등)는 노출되지 않게** 한다.

> Tailscale 자체가 VPN 이라서 별도 VPN 이나 공유기 포트포워딩은 필요 없다.
> 포트포워딩으로 22번을 인터넷에 여는 것은 하지 말 것 (무차별 대입 공격 대상이 된다).

## 1. 팀원을 어떻게 붙일까: 초대 vs 기기 공유

| 방식 | 팀원이 보는 것 | 장점 | 단점 | 추천 상황 |
|---|---|---|---|---|
| **tailnet 초대 (Invite users)** | 내 tailnet 전체 (ACL 로 제한) | 장비가 늘어도 한 번에 관리, 그룹/정책 사용 | 사용자 수에 포함 (무료 Personal 플랜 6명까지) | **팀 프로젝트 (권장)** |
| 기기 공유 (Share) | Jetson 한 대만 | 사용자 수 미포함, 팀원은 자기 tailnet 유지 | 베타 기능, 사용자별 정책 불가 | 외부 협력자 1~2명 잠깐 |

팀원이 6명 이하라면 **초대 + 아래 ACL 정책**이 가장 깔끔하다. 무료 플랜 한도는 바뀔 수 있으니
[가격 페이지](https://tailscale.com/pricing)에서 확인한다.

## 2. 관리자 작업 (한 번만)

1. **ACL 정책 먼저 적용** — 기본 정책은 "모두가 모두에게 접근 허용"이다. 그대로 초대하면 팀원이 **내 맥까지** 접근할 수 있다.
   - [관리 콘솔 → Access controls](https://login.tailscale.com/admin/acls) 에 `tailscale/policy.example.hujson` 내용을 붙여넣고 이메일만 바꾼 뒤 저장.
2. **Jetson 에 `tag:jetson` 붙이기** — Machines → Jetson ⋯ → *Edit ACL tags*.
   - 태그가 붙은 기기는 **노드 키 만료(기본 180일)가 꺼진다.** 원격 전용 장비가 반년 뒤 갑자기 접속 불가가 되는 사고를 막는다.
3. **MagicDNS 확인** — DNS 탭에서 켜져 있으면 IP 대신 `jetson-orin` 같은 이름으로 접속 가능.
   이름이 길거나 애매하면 Machines 에서 Jetson 이름을 바꾼다.
4. **팀원 초대** — Users → *Invite users*.
5. **Jetson 에 팀원 계정 생성** (Jetson 에서 실행):
   ```bash
   sudo ./scripts/add-team-member.sh <리눅스아이디> --github <깃허브아이디>
   ```
   GitHub 계정에 SSH 공개키가 등록돼 있으면 자동으로 가져온다. 없으면 `--key-file 공개키.pub`.
6. **모든 팀원 키 등록을 확인한 뒤** 비밀번호 SSH 차단:
   ```bash
   sudo ./scripts/secure-ssh.sh --dry-run   # 바뀔 내용 미리 보기
   sudo ./scripts/secure-ssh.sh             # 적용 + 10분 자동 되돌리기 예약
   ```
   적용 후 **기존 창을 닫지 말고** 새 터미널에서 `ssh jetson` 으로 접속 테스트.
   - 접속 성공 → `sudo ./scripts/secure-ssh.sh --keep` (자동 되돌리기 취소, 설정 유지)
   - 접속 실패 → 기존 창에서 `sudo ./scripts/secure-ssh.sh --rollback`, 또는 10분 기다리면 자동으로 원래대로

## 3. 팀원 작업

1. [Tailscale 앱](https://tailscale.com/download) 설치 → 초대 메일 수락 → 같은 계정으로 로그인.
2. SSH 키가 없다면 만들고, GitHub 에 등록하거나 관리자에게 공개키(`.pub`)를 전달:
   ```bash
   ssh-keygen -t ed25519 -C "내이름@맥"
   cat ~/.ssh/id_ed25519.pub
   ```
3. `config/ssh_config.example` 을 `~/.ssh/config` 에 붙여넣고 `HostName`, `User` 수정.
4. 접속: `ssh jetson`

## 4. 자주 겪는 문제

| 증상 | 확인 |
|---|---|
| `ssh: Could not resolve hostname` | 맥에서 Tailscale 이 켜져 있는지, `tailscale status` 에 Jetson 이 보이는지 |
| 연결이 느림/끊김 | `tailscale ping jetson-orin` → `via DERP` 면 중계 경유(느림). 학교/회사 방화벽이 UDP 를 막는 경우가 많다. 집/핫스팟에서 비교 |
| `Permission denied (publickey)` | 관리자에게 `add-team-member.sh` 재실행 요청, `ssh -v jetson` 로그 공유 |
| 몇 달 뒤 갑자기 접속 불가 | Jetson 키 만료 → 2-2 단계(태그) 누락 여부 확인 |

## 참고

- [Tailscale: Inviting vs sharing](https://tailscale.com/kb/1388/inviting-vs-sharing)
- [Tailscale: Share your machines](https://tailscale.com/kb/1084/sharing)
- [Tailscale: Pricing](https://tailscale.com/pricing)
