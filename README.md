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
 ├── cp1 (2 CPU / 2GB) ── k3s server (컨트롤 플레인)
 │                         Traefik(Ingress), CoreDNS, metrics-server
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

 요청 흐름: 브라우저 → Traefik(Ingress) → Gateway → 각 서비스 → MySQL(서비스별 DB)
```

- MySQL을 서비스마다 두지 않고 하나만 두는 이유와 메모리 예산: [docs/memory-plan.md](docs/memory-plan.md)

## 진행 단계

- [x] 1단계: VM과 Ansible 준비
- [ ] 2단계: Ansible로 k3s 설치
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
