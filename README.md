# platform-infra

맥 한 대 위에 VM 3대로 k3s 클러스터를 만들고, 쿠폰·인증·Gateway·알림·파일 서버를 운영하는 학습용 사내 플랫폼의 인프라 저장소.
전부 무료 도구(Multipass, Ansible, k3s)로 만든다.

## 저장소 구성

- [coupon-system](https://github.com/diz99-art/coupon-system): 선착순 쿠폰 발급 서버 (Spring Boot, Redis, Kafka)
- platform-services: 인증, Gateway, 알림, 파일 서버 (예정)
- platform-infra (이 저장소): VM, k3s 클러스터, 공용 미들웨어 설정

## 전체 구조

```
 맥 (M2 Pro, 16GB)
 │
 │  Multipass 가상 네트워크 192.168.252.0/24  (게이트웨이·DHCP·NAT = 맥 192.168.252.1)
 │
 ├── cp1 (2 CPU / 2GB) ── k3s server (컨트롤 플레인), taint로 앱 파드 금지
 │                         CoreDNS, metrics-server, local-path-provisioner
 │                         (Traefik(Ingress)은 워커 중 하나에, ServiceLB는 모든 노드에 뜬다)
 │
 ├── worker1 (2 CPU / 4GB) ── 저장 경로
 │       MySQL 8.4 (하나만)                     쿠폰 서버 1번
 │       ├─ DB coupon       ← 계정 coupon
 │       ├─ DB auth         ← 계정 auth
 │       ├─ DB notification ← 계정 notification
 │       └─ DB file         ← 계정 file
 │
 └── worker2 (2 CPU / 4GB) ── 발급 경로
         Redis 7.4 (재고 판정)   Kafka 4.3 (KRaft 1대)   쿠폰 서버 2번   Traefik

 앱 (stateless, 스케줄러가 노드에 나눠 배치):
         Gateway ─┬─ 인증 서버
                  ├─ 쿠폰 서버 × 2 ─── Redis, Kafka, MySQL(coupon)   ← 4단계에서 이전
                  ├─ 알림 서버
                  └─ 파일 서버

 요청 흐름: 브라우저 → 노드 IP:80 (ServiceLB) → Traefik(Ingress) → Gateway → 각 서비스 → MySQL(서비스별 DB)
```

- MySQL을 서비스마다 두지 않고 하나만 두는 이유와 메모리 예산: [docs/memory-plan.md](docs/memory-plan.md)

## 진행 단계

- [x] 1단계: VM과 Ansible 준비
- [x] 2단계: Ansible로 k3s 설치
- [x] 3단계: MySQL (Vault 비밀 관리, StatefulSet, 서비스별 DB·계정, 백업·복구)
- [x] 4단계: Redis·Kafka, 쿠폰 서버 이전 (GitHub Actions ARM64 이미지 → GHCR → k3s)
- [x] 5단계: ArgoCD GitOps (push → 자동 배포, self-heal, Git 롤백)
- [ ] 이후: 플랫폼 서비스(Gateway·인증·알림·파일), 모니터링, Vault 단계(Secret 저장 암호화, NetworkPolicy)

## 1단계: VM과 Ansible 준비

### 한 일

1. 맥 사양 확인 후 VM 3대 크기 결정 ([메모리 계획](docs/memory-plan.md))
2. 프로젝트 전용 SSH 키 `~/.ssh/platform_ed25519` 생성
3. cloud-init으로 공개키 등록·기본 패키지 설치를 자동화한 VM 3대 생성
4. ssh 별칭(`ssh cp1`)과 VM 간 이름 통신(`ping worker1`) 설정
5. Ansible 인벤토리 작성, `ansible all -m ping` 확인

### 파일

- `multipass/vms.conf`: VM 이름·CPU·메모리·디스크 목록 (스크립트들이 같이 읽음)
- `multipass/cloud-init.yaml`: VM 첫 부팅 설정 (SSH 공개키, 패키지, 시간대, 스왑 끄기)
- `multipass/create-vms.sh`: VM 생성. 이미 있으면 건너뛰므로 여러 번 실행해도 안전
- `multipass/delete-vms.sh`: VM 삭제 (확인을 묻는다)
- `multipass/update-hosts.sh`: 현재 IP로 ssh 설정과 VM의 `/etc/hosts`를 다시 씀
- `multipass/check-network.sh`: 맥 → VM, VM ↔ VM, VM → 인터넷 통신 확인
- `ansible/inventory.ini`, `ansible/ansible.cfg`: Ansible 서버 목록과 설정
- `docs/concepts.md`: VM과 컨테이너, IP, 서브넷, 게이트웨이, NAT, DHCP, SSH 키, cloud-init, Ansible 설명
- `docs/vm-operations.md`: VM 멈추기·켜기, IP가 바뀌었을 때 대처법

### 처음부터 따라 하기

```bash
# 1. 도구 설치 (Multipass는 관리자 비밀번호를 묻는다)
brew install --cask multipass
brew install ansible

# 2. VM 3대 만들기 (5~10분)
multipass/create-vms.sh

# 3. 접속과 통신 확인
ssh cp1
multipass/check-network.sh

# 4. Ansible 연결 확인
cd ansible && ansible all -m ping
```

### 매일 쓰는 명령

```bash
multipass stop --all       # 끄기 (메모리 반환)
multipass start --all      # 켜기
multipass/update-hosts.sh  # IP가 바뀌었을 때
```

### 메모리 설정

- Docker Desktop 메모리를 3GB로 줄였다 (Settings > Resources > Memory). 워커를 4GB로 늘린 뒤로는 **클러스터를 쓸 때 Docker Desktop을 끈다** (VM 최대 10GB + macOS 5GB).

## 2단계: Ansible로 k3s 설치

### 한 일

1. 롤 3개(common, k3s_server, k3s_agent)로 k3s 클러스터 자동 설치 플레이북 작성. k3s 버전은 `group_vars/all.yml`에 `v1.36.5+k3s1`로 고정
2. 맥에 kubectl 설치, cp1의 kubeconfig를 주소·이름만 바꿔 `~/.kube/platform-infra.yaml`로 저장
3. nginx 3개 + Ingress로 배치·접속·자가 치유 확인 후 정리
4. 제거 플레이북을 만들고 "제거 → 재설치"를 실제로 해봄

### 플레이북 구조

```
ansible/
├── group_vars/all.yml     k3s 버전, 서버 IP(팩트에서), kubeconfig 위치
├── site.yml               common → k3s_server → k3s_agent
├── k3s-uninstall.yml      워커 → 서버 순으로 제거 (-e confirm=yes 필요)
└── roles/
    ├── common/            패키지, 시간대, 스왑, 커널 모듈(overlay, br_netfilter), sysctl
    ├── k3s_server/        config.yaml 템플릿, 설치, Ready 대기, 조인 토큰, 맥 kubeconfig
    └── k3s_agent/         config.yaml 템플릿(서버 주소·토큰), 설치, Ready 대기
```

롤·변수·핸들러·팩트가 각각 어디에 쓰였는지는 [docs/k3s-design.md](docs/k3s-design.md)에 정리했다.

### 설계 결정 (자세한 이유는 docs/k3s-design.md)

- Traefik(Ingress), ServiceLB, local-path, metrics-server: **전부 켠다**. 추가 설치 없이 브라우저 접속과 저장소가 바로 되고, 대안(ingress-nginx, MetalLB, Longhorn)은 메모리나 설정이 더 든다.
- cp1: **taint로 앱 파드를 막는다** (`node-role.kubernetes.io/control-plane:NoSchedule`). k3s 서버만으로 이미 약 1.2GB를 써서, 앱이 올라오면 API 서버가 위험하다.
- MySQL 데이터(3단계): worker1에 고정하고, k3s 폴더 밖의 고정 경로를 가리키는 PV를 직접 만든다(`Retain`). 그리고 mysqldump로 백업한다. 기본 local-path는 k3s를 제거하거나 PVC를 지우면 데이터도 같이 지워지기 때문이다.

### 멱등성과 검증 결과 (자세한 기록: docs/k3s-verification.md)

- 첫 실행 49초: changed cp1 11, worker 9 → **바로 다시 실행 15초: 3대 모두 changed=0**
- worker2의 설정 파일을 손으로 고친 뒤 실행: 그 파일만 되돌리고 worker2의 k3s-agent만 재시작
- `kubectl get nodes`: 3대 Ready, nginx 3개는 worker1에 2개, worker2에 1개 (cp1 0개), 세 노드 IP 모두 HTTP 200
- 파드 하나 삭제 → 바로 새 파드 생성, 약 1초 뒤 시작
- **제거 6초 + 재설치 29초 + Traefik 준비 약 35초 = 70초**면 클러스터를 처음부터 다시 만든다
- `--check --diff` 미리 보기: changed=0, 16초

### 사용법

```bash
cd ansible
ansible-playbook site.yml                            # 설치 (여러 번 실행해도 안전)
ansible-playbook site.yml --check --diff             # 실제로 바꾸지 않고 무엇이 바뀔지만 보기
ansible-playbook k3s-uninstall.yml -e confirm=yes    # 완전히 제거 (클러스터 안의 데이터도 사라짐)

kubectl get nodes                                    # ~/.zshrc에 KUBECONFIG를 등록해둠
kubectl apply -f k8s/examples/nginx-demo.yaml        # 동작 확인용 예제 (http://192.168.252.2/)
kubectl delete -f k8s/examples/nginx-demo.yaml
```

맥의 `~/.zshrc`에 다음 줄을 추가했다. 이 클러스터 설정이 앞에 있어 기본 컨텍스트가 되고, 나중에 다른 클러스터 설정(`~/.kube/config`)이 생겨도 같이 쓸 수 있다.

```bash
export KUBECONFIG="$HOME/.kube/platform-infra.yaml:$HOME/.kube/config"
```

### 트러블슈팅 (실제로 겪은 것)

- **kubeconfig의 이름이 `\1: platform-infra`로 깨짐**: `regex_replace`의 되돌림 참조를 `'\\1'`로 썼더니 글자 그대로 들어갔다. Ansible YAML의 `>-` 블록 안에서는 `'\1'`로 써야 한다. 고친 뒤에는 kubeconfig 파일만 changed가 됐고, 다음 실행부터 0.
- **처음 설치 때 k3s가 두 번 시작됨**: 설치 스크립트가 서비스를 시작한 직후, 새 설정 파일 때문에 핸들러가 또 재시작했다. 핸들러에 `when: k3s_install is not changed`를 넣어 재설치 시간이 40초 → 31초로 줄었다.
- **`--check`로 실행하면 "Ready 대기"에서 끝나지 않음**: check 모드는 `command` 작업을 실행하지 않고 건너뛴다. 그래서 버전 확인 결과가 비어서 "설치 필요"로 판단했고, Ready 대기는 결과가 영원히 비어 30번 재시도했다. 읽기만 하는 명령에는 `check_mode: false`를 붙여 check 때도 실제로 실행하게 했다. 또 `get_url`은 check 모드에서 늘 changed로 보고해서, 설치가 필요할 때만 내려받게 바꿨다.
- **설치 직후 `deployments.apps "traefik" not found`**: Traefik은 k3s가 Helm 작업(`helm-install-traefik` 파드)으로 설치해서, 플레이북이 끝나고도 30~40초 뒤에 생긴다. `kubectl -n kube-system get pods`에서 helm-install 파드가 Completed가 될 때까지 기다린다.
- **`kubectl wait --for=condition=Ready pod -l app=...`가 타임아웃**: 지워지는 중(Terminating)인 옛 파드도 같은 라벨이라 같이 기다린다. 복구 확인은 `kubectl get deploy`의 AVAILABLE이나 이벤트(`kubectl get events`)로 본다.
- **`cat /etc/rancher/k3s/config.yaml`이 Permission denied**: 토큰이 들어 있어 권한을 600(root만)으로 둔 것이다. `sudo cat`으로 본다.
- **`--limit workers`로 워커만 실행하면 실패**: 조인 토큰과 서버 IP를 cp1에서 가져오므로 cp1도 같이 실행돼야 한다. 롤 처음에 assert로 알아보기 쉬운 메시지를 띄운다.
- **kubectl이 다른 클러스터(Docker Desktop)를 봄**: `kubectl config current-context`로 확인하고 `kubectl config use-context platform-infra`.
- **첫 실행의 `remote_tmp /root/.ansible/tmp did not exist` 경고**: sudo로 처음 실행할 때 임시 폴더를 만들었다는 안내다. 무해하고 두 번째부터는 안 나온다.

## 3단계: MySQL

### 한 일

1. 비밀번호 6개를 무작위로 만들어 Ansible Vault로 암호화(`ansible/group_vars/all/vault.yml`). Ansible이 풀어서 쿠버네티스 Secret을 만든다. 평문은 어디에도 파일로 남지 않는다
2. MySQL 8.4.11을 `data` 네임스페이스에 StatefulSet으로 배포. worker1의 고정 경로 PV(Retain)에 데이터를 둔다
3. 서비스별 DB 4개(coupon, auth, notification, file)와 자기 DB에만 권한이 있는 전용 계정, 읽기 전용 백업 계정
4. 매일 03:00 백업 CronJob, 맥으로 가져오는 스크립트, 복구 스크립트. 복구 훈련 2번

### 구조

```
맥: ansible-playbook mysql.yml  (vault.yml을 풀어 Secret 생성)
 │
 ├─ data 네임스페이스
 │    StatefulSet mysql (worker1 고정) ─ PVC data-mysql-0 ─ PV mysql-data (Retain) ─ worker1:/srv/data/mysql
 │    Service mysql (ClusterIP, 클러스터 안에서만)  ← 앱 접속: mysql.data.svc.cluster.local:3306
 │    CronJob mysql-backup (매일 03:00) ─ PV mysql-backup ─ worker1:/srv/backup/mysql (7일)
 │                                                          └─ scripts/fetch-mysql-backups.sh → 맥 ~/platform-backups/mysql (30일)
 └─ apps 네임스페이스
      Secret mysql-coupon / mysql-auth / mysql-notification / mysql-file  (앱이 env로 받음)

MySQL 안: DB coupon ← 계정 coupon, DB auth ← 계정 auth, ... (각자 자기 DB만), 계정 backup (읽기 전용)
```

플레이북: `ansible/mysql.yml` → 롤 `ansible/roles/mysql` (tasks: storage → k8s → schema, templates: 저장소·설정·MySQL·백업)

### 설계 결정 (자세한 이유: [docs/mysql.md](docs/mysql.md))

- **Vault와 Secret**: Vault는 Git에 보관하기 위한 암호화(AES256), Secret은 파드에 전달하기 위한 객체(base64일 뿐 암호화 아님). Secret YAML은 저장소에 없고, pre-commit hook(`scripts/check-secrets.sh`)이 평문 vault·Secret 매니페스트·`.vault-pass` 커밋을 막는다
- **StatefulSet**: 고정 이름(`mysql-0`), 파드마다 자기 PVC, 옛 파드가 완전히 끝난 뒤 새 파드를 띄움 → 같은 데이터 폴더를 MySQL 두 개가 동시에 여는 일이 없다
- **고정 경로 PV + Retain + nodeAffinity**: k3s를 지워도, PVC를 지워도 데이터 폴더가 남는다. 디스크가 worker1에 있으므로 파드도 worker1에 고정
- **자원**: requests 250m/512Mi, limit 메모리 768Mi만 (CPU limit은 스로틀링 때문에 두지 않음). 버퍼 풀 256M, performance_schema OFF, 연결 120 (계정당 25)
- **Probe**: startup(초기화 최대 5분 기다림), liveness(`mysqladmin ping`, 비밀번호와 무관), readiness(`SELECT 1`, 실패하면 Service에서만 뺌)
- **최소 권한**: 서비스 계정은 자기 DB에 SELECT·INSERT·UPDATE·DELETE·CREATE·ALTER·INDEX 등만. DROP, GRANT, 다른 DB, 전역 권한 없음

### 검증 결과 (자세한 기록: [docs/mysql-verification.md](docs/mysql-verification.md))

- 멱등성: `mysql.yml` 재실행 changed=0 (11초), `site.yml`도 changed=0
- 최소 권한: coupon 계정은 `SHOW DATABASES`에 coupon만 보이고, 다른 DB 접근(1044/1142), DB·계정 생성, GRANT, 자기 테이블 DROP까지 모두 거부. 틀린 비밀번호는 1045
- 데이터 보존: 파드 삭제 → 8초 뒤 그대로, worker1 재부팅 → 27초 뒤 그대로, **k3s 전체 제거·재설치 → 77초 뒤 데이터와 계정 그대로**
- 백업: 3초, 보관 기간 지난 폴더 자동 삭제 확인
- 메모리: MySQL 151MiB(재시작 직후) ~ 620MiB(100만 줄 직후), limit 768Mi

### 복구 훈련 기록

- 훈련 1 (작은 데이터): `DROP DATABASE coupon` → 앱 접속 실패(1049) → 맥의 백업으로 복구. 가져오기 0.18초 + 복구 0.20초 + 확인 0.09초 = **0.47초**.
  마지막 백업 뒤에 넣은 1줄은 사라짐 → RPO(잃을 수 있는 데이터) = 백업 간격 (지금 최대 24시간)
- 훈련 2 (100만 줄, 80MB 테이블, 백업 7.5MB): 가져오기 0.3초 + 복구 6.3초 + 확인 0.2초 = **6.7초**, 1,000,000줄 복구 확인

### 사용법

```bash
cd ansible
ansible-playbook mysql.yml                                  # 배포 (여러 번 실행해도 안전)
ansible-vault edit group_vars/all/vault.yml                 # 비밀번호 보기·고치기
ansible-playbook mysql.yml -e mysql_rotate_passwords=true   # 비밀번호 교체

kubectl -n data create job --from=cronjob/mysql-backup backup-now   # 지금 백업
scripts/fetch-mysql-backups.sh                                       # 맥으로 가져오기
scripts/mysql-restore.sh coupon ~/platform-backups/mysql/<날짜-시각>   # 복구 (확인을 묻는다)
kubectl apply -f k8s/examples/mysql-client.yaml                      # 앱처럼 접속해보기
```

처음 클론했을 때: `ansible/.vault-pass`(비밀번호 관리자에 보관한 값)를 만들고, `ln -sf ../../scripts/check-secrets.sh .git/hooks/pre-commit`으로 검사 hook을 연결한다.

### 메모리 예산 (자세히: [docs/memory-plan.md](docs/memory-plan.md))

- 실측: cp1 남음 약 740MB(taint로 앱 금지), worker1 MySQL 포함 751MB 사용, worker2 401MB 사용
- 워커 3GB일 때: 전체 계획(서비스 6개, Redis, Kafka, ArgoCD, 모니터링)에 6750MB가 필요한데 용량 5912MB → 약 840MB 부족
- **워커를 4GB로 늘렸다** (한 대씩 drain → stop → `multipass set local.<이름>.memory=4G` → start → uncordon, MySQL 중단 28초)
- 지금: 필요 6824MB / 용량 7802MB → **들어간다** (여유 978MB, 13%). 새 구성요소를 올릴 때마다 실측해서 예산표를 고친다

### 트러블슈팅 (실제로 겪은 것)

- **`Plugin 'mysql_native_password' is not loaded`**: MySQL 8.4는 옛 인증 방식이 꺼져 있다. `mysql_user`에 `plugin: caching_sha2_password` + `plugin_auth_string`을 쓴다
- **계정 작업이 매번 changed**: caching_sha2 해시는 매번 달라 비교할 수 없다 → `update_password: on_create`
- **`no_log`로 오류가 가려짐**: 진짜 비밀번호 대신 가짜 계정으로 같은 옵션을 넣어 ad-hoc(`ansible cp1 -m ansible.mysql.mysql_user ...`)으로 원인을 봤다
- **VM에서 MySQL 폴더 그룹이 `systemd-journal`로 보임**: 컨테이너의 mysql(999)과 Ubuntu의 systemd-journal 그룹이 같은 숫자일 뿐이다. 권한은 숫자로 판단한다
- **`created_at`이 9시간 이르게 보임**: MySQL 서버 시간대는 UTC다 (관례). 보여줄 때 KST로 바꾼다
- **VM 재부팅 직후 `kubectl get node`가 계속 Ready**: 쿠버네티스가 노드 이상을 알아채기까지 약 40초 걸린다. VM 상태는 `multipass list`, `ssh worker1 uptime`으로 본다

## 4단계: 쿠폰 서버 이전

### 한 일

1. Redis 7.4와 Kafka 4.3(KRaft 단일 노드)을 `data` 네임스페이스에 StatefulSet으로 배포 (worker2 고정 경로 PV)
2. coupon-system 저장소의 GitHub Actions에 이미지 job 추가: main 테스트 통과 → ARM64 러너에서 빌드 → `ghcr.io/diz99-art/coupon-system:<커밋 해시>`
3. 쿠폰 서버를 `apps` 네임스페이스에 Deployment 2대 + Service + PDB + Ingress로 배포. prod 프로필, 설정은 ConfigMap, 비밀번호는 vault → Secret 재사용
4. Swagger·발급 API·Kafka→MySQL 저장, 파드 삭제·롤링 업데이트 중 무중단, 메모리 실측

### 구조

```
POST /coupons/{id}/issue  (맥 → 노드IP:80 → Traefik → coupon Service → 파드 2대 중 하나)
  ├─ Redis (worker2): Lua로 기간·재고·중복 판정, 카운터 +1                  ┐ 발급 경로: 이 둘만 있으면 202 응답
  ├─ Kafka (worker2): 발급 메시지 → 202 응답                                ┘
  └─ 컨슈머 (쿠폰 서버 안) → MySQL (worker1) coupon_issue 저장             ← 비동기. 실패하면 재시도 → DLT → 1분마다 대사 작업이 보정

GitHub (coupon-system main push) → Actions: test → image(ARM64) → GHCR
맥: ansible-playbook coupon.yml -e coupon_image_tag=<커밋 해시>
```

> 5단계에서 쿠폰 서버 배포는 Ansible(`coupon.yml`)에서 ArgoCD(GitOps)로 바뀌었다. 아래 `coupon.yml`은 4단계 당시 기록.

플레이북: `redis.yml`, `kafka.yml`, `coupon.yml` (롤: `roles/redis`, `roles/kafka`, `roles/coupon`). 순서: `site.yml → mysql.yml → redis.yml → kafka.yml → coupon.yml`

### 설계 결정 (자세한 이유: [docs/redis-kafka.md](docs/redis-kafka.md), [docs/coupon.md](docs/coupon.md))

- **배치**: MySQL은 worker1, Redis와 Kafka는 함께 worker2. 상태 있는 구성요소의 limit이 768 대 960으로 고르게 나뉘고, 발급 API가 의존하는 Redis·Kafka가 한 노드에 있어 "발급이 멈추는 노드"가 하나뿐이다. worker1(MySQL)이 죽으면 발급은 계속되고 저장만 늦어진다
- **Redis 보존**: 재고 카운터가 들어 있어 캐시가 아니라 데이터 → AOF + 1초마다 fsync, `noeviction`(꽉 차면 지우지 말고 거부), 비밀번호는 Secret 파일을 `include`
- **Kafka 보존**: `log.dirs`를 PV로(기본 /tmp), `CLUSTER_ID` 고정, 1초마다 flush(복제본이 없어서), 토픽 자동 생성 끔, 보관 72시간
- **Probe**: Redis는 `redis-cli ping`, Kafka는 `tcpSocket`(exec 검사는 JVM을 새로 띄워 수백 MB를 씀), 쿠폰 서버는 Actuator `/actuator/health/liveness`·`readiness` (관리 포트 8081, 외부에 안 열림)
- **이미지 태그 = 커밋 해시**: 불변이라 노드마다 다른 이미지가 돌 일이 없고, 떠 있는 버전을 바로 추적하고, 되돌릴 때 예전 해시로 다시 배포하면 된다. `latest`는 매니페스트가 그대로라 쿠버네티스가 바뀐 줄도 모른다
- **무중단**: 노드별로 1대씩(topologySpreadConstraints), maxSurge 1·maxUnavailable 0, preStop 10초, graceful shutdown, PDB minAvailable 1
- **JVM**: 메모리 requests = limits = 640Mi, 힙 40%(256MB), Metaspace 상한 192m, OOM이면 즉시 종료, CPU limit 없음
- **`enableServiceLinks: false`** (모든 파드): 같은 네임스페이스 Service마다 붙는 `KAFKA_PORT=tcp://...` 같은 환경변수가 Kafka 이미지의 설정으로 바뀌어 시작이 깨질 수 있다

### 검증 결과

- Swagger: 맥 브라우저에서 `http://192.168.252.2/swagger-ui.html` (관리 포트의 `/actuator/health`는 밖에서 404)
- API: 수량 5 쿠폰에 7명 → 5명 202, 2명 409 매진, 중복 409. MySQL에 5건, 컨슈머 lag 0
- **파드 삭제 중 발급**: 40초간 10,856건 전부 202, 실패 0. MySQL = Redis 카운터 = Redis 목록 = 10,856
- **롤링 업데이트 중 발급**: 30,833건 전부 202, 재시작 0 (연결 상한 수정 후). 저장은 컨슈머 리밸런스 동안 10~20초 늦어졌다가 전부 따라옴
- 데이터 보존: Redis 키·Kafka 메시지를 넣고 파드를 지움 → 8초 뒤 그대로
- 멱등성: `site/mysql/redis/kafka/coupon.yml` 모두 다시 실행 changed=0
- CI: test 2분 32초 + image(ARM64) 2분 2초. GHCR 이미지는 익명 pull 가능(public) → pull secret 불필요

### 메모리 실측과 여유율 (자세히: [docs/memory-plan.md](docs/memory-plan.md))

- 실측 (부하 직후): worker1 used 1184MB, worker2 used 1368MB. 쿠폰 서버 423~494Mi, Kafka 423Mi, MySQL 187Mi, Redis 15Mi
- 전체 계획의 limit 합 7400 / 7802MB → **여유 5%** (3단계 계획 13%에서 쿠폰 서버 512→640 등으로 +576MB)
- 실측 기반 예상으로는 여유 25%. 다음 서비스는 실측으로 limit을 정하고, Kafka limit 축소·VictoriaMetrics로 여유 16%까지 되찾는 안을 문서에 적었다

### 트러블슈팅 (실제로 겪은 것)

- **쿠폰 서버 512Mi가 87%까지 참**: 힙 밖 메모리가 211MB(Metaspace 145)라 힙이 다 크면 limit을 넘는다 → 640Mi, 힙 40%, Metaspace 192m
- **배포 중 새 파드가 `max_user_connections (25)` 초과로 시작 실패**: 롤링 업데이트 중에는 파드가 3대(풀 10 × 3 = 30) → coupon 계정 상한 35로. 3단계에서 maxSurge를 빼먹은 계산 실수
- **배포 직후 DB 건수가 202 응답 수보다 적음**: 컨슈머 그룹 리밸런스 동안 저장이 멈췄다가 따라온다(lag 0, DLT 0 확인). 비동기 저장 구조의 정상 동작
- **롤링 업데이트 중 `IncompleteRead` 4건 (32,540건 중)**: 서버에서는 발급·저장됐고 응답만 끊겼다(재요청하면 409라 중복 없음). 이후 재현되지 않음. Traefik ↔ Tomcat 연결 종료 경합으로 추정, 접근 로그로 다시 볼 과제
- **Kafka 명령줄 도구는 브로커 파드 밖에서**: 도구도 JVM이라 브로커 컨테이너 안에서 돌리면 limit 768Mi를 넘을 수 있다 → `kubectl run kcli --image=apache/kafka:4.3.1 ...` 일회용 파드
- **`runAsNonRoot`인데 이미지가 `USER app`(이름)뿐**: 쿠버네티스가 root인지 확인할 수 없어 거부한다 → 이미지의 uid(100)를 `runAsUser`에 숫자로 적었다
- **zsh 변수 함정**: `for path in ...`가 PATH를 덮어씀, `$CID:count`의 `:c`가 수정자로 해석됨 → 다른 이름, `${CID}`

## 5단계: GitOps

### 한 일

1. ArgoCD v3.5.5를 `platform` 네임스페이스에 Helm 차트로 설치 (Ansible `argocd.yml`). Dex·알림·ApplicationSet은 끔. 화면 `http://192.168.252.2/argocd/`
2. 쿠폰 서버 매니페스트를 Ansible 템플릿에서 Kustomize(`k8s/apps/coupon/`)로 옮기고, ArgoCD Application이 배포하게 했다. Ansible `coupon` 롤은 삭제
3. coupon-system CI에 `deploy` job: 이미지 뒤에 platform-infra의 이미지 태그를 커밋 해시로 바꿔 push (deploy key)
4. 자동 배포 시간, self-heal, Git 롤백, 배포·롤백 중 발급 부하를 검증

### 구조

```
coupon-system push ─▶ Actions: test ─▶ image(ARM64 → GHCR) ─▶ deploy(newTag 변경 → platform-infra push)
                                                                         │
platform-infra (Git = 원하는 상태)                                       ▼
  k8s/argocd/apps/coupon.yaml   ◀── 루트 Application "platform-apps" (Ansible이 만듦)
  k8s/apps/coupon/ (Kustomize)  ◀── Application "coupon" (자동 동기화, prune, selfHeal)
                                          │ 60초+α마다 Git 확인
                                          ▼
                       apps 네임스페이스: Deployment coupon 롤링 업데이트

역할: Ansible = VM·k3s·MySQL·Redis·Kafka·Secret·ArgoCD 자체 / ArgoCD = 앱
```

### 설계 결정 (자세한 이유: [docs/gitops.md](docs/gitops.md))

- **ArgoCD 최소 구성**: controller·repo-server·server·redis만. Dex(SSO), 알림, ApplicationSet은 쓸 일이 없어 끔. 동시 처리 수도 줄임 → 실측 215Mi
- **Kustomize (Helm 아님)**: 평범한 YAML, CI가 바꿀 곳이 `images.newTag` 한 줄, kubectl·ArgoCD 내장, configMapGenerator로 설정이 바뀌면 자동 재배포. ArgoCD 자체처럼 남이 만든 소프트웨어는 Helm 차트로 설치
- **app of apps**: 루트 Application이 `k8s/argocd/apps/`를 본다 → 새 앱은 YAML 하나 추가로 끝
- **AppProject `apps`**: apps 네임스페이스만, 클러스터 전체 객체 금지, **Secret 금지** (Git에 Secret을 넣어도 배포 거부)
- **비밀번호는 그대로 Vault → Ansible → Secret**. ArgoCD 관리자 비밀번호도 vault (bcrypt 해시를 한 번 만들어 고정 → 멱등)
- **deploy key**: CI가 platform-infra에만 쓸 수 있는 SSH 키. PAT보다 범위가 좁고 사람 계정·만료와 무관
- **감지는 60초 주기 확인**: 클러스터가 NAT 뒤라 GitHub webhook을 받을 수 없다 (기본 120초에서 줄임)
- **롤백 = git revert**: 자동 동기화 중에는 ArgoCD 화면의 Rollback이 막힌다. Git에 기록이 남는 쪽이 정석
- coupon-system: 문서만 바뀐 push는 CI를 건너뜀 (`paths-ignore`) → README 수정으로 파드가 다시 뜨지 않게

### 검증 결과

- **push → 클러스터 배포 (사람 손 없음)**: 4분 32초(워크플로 변경), **5분 34초(코드 변경)**. 가장 긴 구간은 테스트 2~3분, ArgoCD 감지는 7~52초
- **배포 중 발급 부하**: 101,923건 전부 202, 실패 0. DB = Redis 카운터 = 101,923, 재시작 0
- **self-heal**: `kubectl scale --replicas=1` → 0.85초 뒤 2로, `kubectl delete svc` → 0.7초 뒤 재생성
- **롤백**: 봇 커밋 `git revert` → 40초에 이전 이미지로(롤백 중 발급 58,965건 전부 202), 롤포워드 32초
- 멱등성: `site/mysql/redis/kafka/argocd.yml` 다시 실행 changed=0

### 메모리 (자세히: [docs/memory-plan.md](docs/memory-plan.md))

- ArgoCD 215Mi (limit 합 704Mi). 노드: cp1 used 1176 / worker1 1316 / worker2 1595 MB
- 쿠폰 서버 한 대가 516Mi / 640Mi(81%)까지 올라옴, Kafka 483Mi
- 전체 계획 limit 합 7504 / 7802MB → **여유 4%**, 실측 기반 예상 **28%**. ArgoCD limit 축소 + 서비스 실측 + VictoriaMetrics로 16%까지 되찾는 안

### 처음부터 다시 만들 때

```bash
cd ansible
ansible-playbook site.yml && ansible-playbook mysql.yml && ansible-playbook redis.yml && ansible-playbook kafka.yml
ansible-playbook argocd.yml          # 이 뒤로 쿠폰 서버는 ArgoCD가 Git을 보고 알아서 배포한다
```

### 트러블슈팅 (실제로 겪은 것)

- **ArgoCD가 넘겨받은 뒤 옛 ConfigMap이 남음**: Ansible이 만든 `coupon-config`는 ArgoCD가 만든 게 아니라 prune 대상이 아니다 → 직접 삭제
- **로컬 platform-infra가 원격보다 뒤처짐**: CI 봇이 main에 커밋한다. 작업 전 `git pull --rebase`
- **zsh에서 `custom-columns=...[0]...`가 `no matches found`**: zsh가 `[0]`을 파일 이름 패턴으로 본다 → 인자를 따옴표로 감싼다
