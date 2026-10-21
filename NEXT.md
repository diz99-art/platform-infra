# 다음에 이어서 할 일 (2026-10-21 중단)

다른 프로젝트 때문에 8단계 도중에 멈췄다. 다시 시작할 때 이 파일을 위에서부터 따라간다.

## 지금 상태

- 커밋: platform-infra `96c3418`(이 파일을 넣은 커밋), platform-services `73e537a`, coupon-system `7ef9cac`. 세 저장소 모두 push 끝
- VM 3대(cp1, worker1, worker2)는 `multipass stop`으로 멈춰 두었다 (삭제하지 않았다. 데이터는 그대로)
- 8단계에서 끝난 것
  - Gateway를 Traefik 미들웨어로 만듦: `k8s/apps/gateway/`(IngressRoute 하나에 /auth/*, /coupons/*), `ansible/roles/traefik/`
  - 요청 제한(로그인·가입 IP당 분당 60, 발급 토큰당 초당 5), 보안 헤더, 요청 ID 플러그인, 본문 1MiB·헤더 32KiB 제한
  - 검증: 제한을 넘으면 429, 정상 사용자 영향 없음. k6 `bench/issue-auth.js` 20,000건 실패 0
  - 메모리 실측 → 알림 서버 예산 472MiB (`docs/memory-plan.md`의 8단계)
  - 시험 데이터 규칙(`@loadtest.invalid`, `[LOAD]`)과 스크립트, 지우기 전 백업
- 8단계에서 남은 것: 아래 1~3, 그리고 README "8단계: Gateway(Traefik)" 절 (키 교체 결과를 넣어 마지막에 쓴다)
- 자세한 내용: `docs/gateway.md`, `docs/test-data.md`, `docs/memory-plan.md`

## 다시 시작하기: VM 켜기 → 클러스터 확인

```bash
# 0. Docker Desktop은 끈 상태로 (맥 16GB). 긴 작업 전에는 다른 터미널에서 caffeinate -is -t 7200
cd ~/Projects/platform-infra
for r in platform-infra platform-services coupon-system; do git -C ~/Projects/$r pull --rebase; done

# 1. VM 켜기 (순서는 상관없지만 cp1을 먼저 켜면 노드가 빨리 Ready가 된다)
multipass start cp1
multipass start worker1 worker2
multipass list                       # 셋 다 Running, IP 192.168.252.2/.3/.4 인지

# 2. IP가 바뀌었으면 (보통 그대로다)
multipass/update-hosts.sh
multipass/check-network.sh

# 3. 클러스터 (1~3분 기다린다)
kubectl get nodes                    # 3대 Ready
kubectl get pods -A | grep -v -E 'Running|Completed'   # 헤더만 나오면 정상
kubectl -n platform get applications # 모두 Synced / Healthy
curl -s -o /dev/null -w '%{http_code}\n' http://192.168.252.2/auth/.well-known/jwks.json   # 200
```

- 시계: 맥이 오래 꺼져 있었으면 VM 시계가 늦을 수 있다. `ssh cp1 chronyc tracking`으로 확인 (JWT 만료 판정이 시계에 기댄다)
- 파드가 CrashLoop이면 MySQL·Redis·Kafka(`data` 네임스페이스)가 먼저 떴는지 본다. 앱은 의존성이 뜨면 재시작으로 회복된다
- VM 멈추기: `multipass stop cp1 worker1 worker2`
- **하면 안 되는 것**: `multipass delete`, `multipass purge`, `multipass/delete-vms.sh` (VM 디스크가 지워진다. MySQL·Redis 데이터는 VM 안에만 있다)

## 남은 일 (이 순서로)

`!`를 앞에 붙이면 Claude Code 대화 안에서 실행된다. vault 쓰기와 DB 대량 수정은 Claude의 자동 권한에서 막히므로 사용자가 직접 실행한다.

### 1. MySQL 서비스 비밀번호 교체 (1순위)

8단계 작업 중 coupon·auth·notification·file 계정 비밀번호가 Claude 대화 출력에 노출됐다.

```bash
! scripts/rotate-mysql-passwords.sh     # vault 새 값 → ALTER USER → apps의 mysql-<서비스> Secret
```

이어서 Claude에게 "비밀번호 교체 끝"이라고 말한다 → `k8s/apps/auth/deployment.yaml`, `k8s/apps/coupon/deployment.yaml`의
`platform-infra/secret-rev`를 `"2"`로 올려 push → ArgoCD가 파드를 새 Secret으로 다시 띄운다.
확인: 두 앱 파드가 새로 Running, 로그인·발급이 된다. (바꾼 뒤 push 전까지는 새 DB 연결이 실패하므로 바로 이어서 한다)

### 2. 시험 데이터 정리

기준과 이유는 `docs/test-data.md`의 "8단계의 한 번 정리". 백업은 이미 있다 (`~/platform-backups/mysql/20261020-221440/`, `~/platform-backups/redis/20261020-221452/`).
1번 뒤라 데이터가 바뀌었으면 백업을 한 번 더 받는다: `kubectl -n data create job --from=cronjob/mysql-backup before-cleanup` → `scripts/fetch-mysql-backups.sh`

```bash
# 표시 붙이기: docs/test-data.md의 SQL 블록을 그대로 실행 (예전 쿠폰 이름에 [LOAD], @example.com USER 계정을 @loadtest.invalid로)
! scripts/cleanup-test-data.sh -n       # 지울 개수만 보기 (관리자 id 1은 남는지 확인)
! scripts/cleanup-test-data.sh          # 지우기
```

### 3. JWT 서명 키 교체 실습 (부하 중 401 = 0 확인)

절차의 근거는 platform-services `docs/auth.md`의 키 교체. 활성 kid는 지금 `2026-10-20`. 전체 40분쯤 걸린다.

1. Claude에게 "키 교체 시작" → Claude가 `scripts/load/rotation-load.py`를 클러스터 안에서 40분 돌린다 (관리자 토큰 필요: coupon-system `bench/token.sh admin@platform.local <비밀번호>`, 비밀번호는 vault의 `vault_auth_admin_password`)
2. `! scripts/rotate-jwt-key.sh add 2026-10-20b` (새 키를 vault에 넣고 auth.yml 실행. 아직 서명에는 안 쓴다)
3. Claude: `k8s/apps/auth/deployment.yaml`의 `platform-infra/jwt-keys`를 `"2026-10-20,2026-10-20b"`로 push → JWKS에 두 키
4. 5분 이상 기다림 (쿠폰 서버의 JWKS 캐시 5분)
5. Claude: `k8s/apps/auth/config.env`에 `AUTH_JWT_ACTIVE_KID=2026-10-20b` push → 새 토큰은 새 키로 서명
6. 15분 이상 기다림 (옛 키로 서명된 액세스 토큰 TTL 15분)
7. `! scripts/rotate-jwt-key.sh remove 2026-10-20`
8. Claude: `platform-infra/jwt-keys`를 `"2026-10-20b"`로 push
9. 부하 결과에서 401 합계 0 확인, 각 단계 시각·걸린 시간을 `docs/key-rotation.md`에 기록, platform-services `docs/auth.md` 갱신
10. 시험 데이터(`rot…@loadtest.invalid`, `[LOAD] 키 교체`)를 `scripts/cleanup-test-data.sh`로 지움
11. README "8단계: Gateway(Traefik)" 절, CLAUDE.md 진행 단계 갱신 → 커밋·push → 8단계 보고

### 4. 9단계: 알림 서버

- 예산: 워커 메모리 472MiB (`docs/memory-plan.md`). 1대 448Mi면 워커 여유 15.3%(목표 15% 충족), 2대면 9.6%
- 시작 전 결정할 것: replica 1대(여유 지킴, 배포 중 잠깐 끊김) / 2대(무중단, 여유 목표 미달)
- MySQL `notification` DB·계정은 3단계에서 이미 만들어 두었다. Kafka 발급 이벤트를 받아 알림을 보내는 구조로 설계 예정

## GitHub에 없고 맥에만 있는 것

잃어버리면 되살릴 수 없거나 다시 만들기 번거로운 것들. 맥 백업(Time Machine 등)에 들어가는지 확인한다.

- `ansible/.vault-pass`: vault 비밀번호. **없으면 `group_vars/all/vault.yml`(모든 비밀)을 영원히 못 푼다.** 저장소 밖(비밀번호 관리자 등)에도 따로 보관해 둘 것. 절대 커밋·공유하지 않는다
- `~/.ssh/platform_ed25519`(개인 키), `.pub`: VM 접속 키. 잃으면 `multipass shell <이름>`으로 들어가 새 공개 키를 넣는다
- `~/.ssh/config.d/platform-infra`: ssh 별칭 (`multipass/update-hosts.sh`로 다시 만들 수 있다)
- `~/.kube/platform-infra.yaml`: kubeconfig, 클러스터 관리자 인증서가 들어 있다 (`ansible-playbook site.yml`로 다시 받을 수 있다)
- VM 디스크: multipassd가 관리 (`/var/root/Library/Application Support/multipassd/`). 그 안에 MySQL(`worker1:/srv/data/mysql`), Redis·Kafka(`worker2:/srv/data/…`), MySQL 자동 백업(`worker1:/srv/backup/mysql`)이 있다
- `~/platform-backups/`: 맥으로 가져온 MySQL 덤프와 Redis 스냅숏. 시험 데이터와 계정 해시가 들어 있으니 공유하지 않는다
- 클러스터 안에만 있는 것: Secret들(vault로 다시 만들 수 있다), ArgoCD·Grafana 상태(Git과 vault로 다시 만들 수 있다)

주의:

- VM은 `stop`만 한다. Multipass나 macOS를 업데이트한 뒤 VM이 안 뜨면 먼저 `multipass list`·`multipass info`로 보고, 지우고 다시 만들지 않는다
- 맥이 잠들면 VM이 멈춘다. 다시 깨어나면 시계부터 확인
- vault 값은 화면에 출력하지 않는다 (`ansible-vault view`는 사용자 본인 터미널에서만). 넣을 때는 `scripts/set-vault-secret.sh <키>`
- platform-infra main에는 CI 봇이 커밋한다 → 작업 전 `git pull --rebase`
