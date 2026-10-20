# 사내 플랫폼 인프라 (platform-infra)

k3s 클러스터에서 쿠폰·인증·Gateway·알림·파일 서버를 운영하는 학습용 사내 플랫폼의 인프라 저장소.

## 사용자와 목적

- 사용자는 리눅스·네트워크·쿠버네티스 초보다. 목적은 학습과 백엔드·데브옵스 취업 대비다.
- 설명은 한국어로 한다.

## 작업 방식

- 완성된 코드와 설정을 바로 작성한다. 그 안에 쓰인 개념과 왜 그렇게 했는지를 함께 설명한다.
- 사용자가 직접 한 작업(명령, 설정, 코드)은 리뷰하고 개선점을 설명한다.
- 유료 서비스는 쓰지 않는다. 무료·오픈소스 도구만 쓴다 (Multipass, Ansible, k3s, GitHub 무료 플랜 등).
- 관리자 비밀번호(sudo)나 macOS 권한 허용이 필요한 작업은 사용자에게 명령을 알려주고 직접 실행하게 한다.

## 저장소 구성

- `coupon-system` (기존, ~/Projects/coupon-system): 선착순 쿠폰 발급 서버
- `platform-services`: 인증, Gateway, 알림, 파일 서버
- `platform-infra` (이 저장소): VM, k3s 클러스터, 공용 미들웨어(MySQL 등) 설정

## 핵심 결정

- VM 3대: cp1(컨트롤 플레인), worker1, worker2. Ubuntu 24.04, Multipass(QEMU)로 만든다.
- DB는 MySQL 하나만 클러스터에 두고, 서비스별로 DB와 전용 계정을 나눈다 (coupon, auth, notification, file). 메모리를 아끼기 위해서다.
- k3s 기본 구성요소(Traefik, ServiceLB, local-path, metrics-server)는 켜둔다. cp1에는 control-plane NoSchedule taint를 건다.
- 플레이북은 멱등하게 쓴다: 확인용 command에는 changed_when: false, 설치는 when 조건, 서비스 재시작은 핸들러로.
- 메모리 계획은 `docs/memory-plan.md`. 새 구성요소를 넣을 때 이 문서의 예산을 먼저 확인하고 고친다.

## 명령어

- VM 만들기: `multipass/create-vms.sh` (이미 있는 VM은 건너뛴다)
- VM 삭제: `multipass/delete-vms.sh` (확인을 묻는다. 되돌릴 수 없다)
- IP가 바뀌었을 때: `multipass/update-hosts.sh` (~/.ssh/config.d/platform-infra와 VM 안의 /etc/hosts를 다시 쓴다)
- 통신 확인: `multipass/check-network.sh`
- Ansible 연결 확인: `cd ansible && ansible all -m ping`
- 접속: `ssh cp1`, `ssh worker1`, `ssh worker2` (전용 키 ~/.ssh/platform_ed25519)
- k3s 설치·설정 맞추기: `cd ansible && ansible-playbook site.yml` (멱등. 두 번째 실행은 changed=0이어야 한다)
- k3s 완전 제거: `cd ansible && ansible-playbook k3s-uninstall.yml -e confirm=yes` (클러스터 안의 데이터도 지워진다)
- kubectl: kubeconfig는 `~/.kube/platform-infra.yaml`, 컨텍스트 `platform-infra` (~/.zshrc의 KUBECONFIG에 등록)

## 진행 단계

- 1단계: VM과 Ansible 준비 (완료)
- 2단계: Ansible로 k3s v1.36.5+k3s1 설치 (완료). 설계는 `docs/k3s-design.md`, 검증 기록은 `docs/k3s-verification.md`
