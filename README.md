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
 ├── worker1 (2 CPU / 3GB) ── 데이터 계층
 │       MySQL 8.4 (하나만)          Redis 7     Kafka (KRaft, 1대)
 │       ├─ DB coupon       ← 계정 coupon
 │       ├─ DB auth         ← 계정 auth
 │       ├─ DB notification ← 계정 notification
 │       └─ DB file         ← 계정 file
 │
 └── worker2 (2 CPU / 3GB) ── 애플리케이션 계층
         Gateway ─┬─ 인증 서버
                  ├─ 쿠폰 서버 ──── Redis, Kafka, MySQL(coupon)
                  ├─ 알림 서버
                  └─ 파일 서버

 요청 흐름: 브라우저 → 노드 IP:80 (ServiceLB) → Traefik(Ingress) → Gateway → 각 서비스 → MySQL(서비스별 DB)
```

- MySQL을 서비스마다 두지 않고 하나만 두는 이유와 메모리 예산: [docs/memory-plan.md](docs/memory-plan.md)

## 진행 단계

- [x] 1단계: VM과 Ansible 준비
- [x] 2단계: Ansible로 k3s 설치
- [ ] 이후: MySQL·Redis·Kafka 배포, 서비스 배포, 모니터링

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

- Docker Desktop 메모리를 3GB로 줄인다 (Settings > Resources > Memory). 클러스터 작업 중에는 Docker Desktop을 꺼두는 것이 가장 좋다.

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
