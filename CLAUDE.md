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
- 메모리 계획은 `docs/memory-plan.md`. 새 구성요소를 넣을 때 이 문서의 예산을 먼저 확인하고 고친다.

## 명령어

- VM 만들기: `multipass/create-vms.sh` (이미 있는 VM은 건너뛴다)
- VM 삭제: `multipass/delete-vms.sh` (확인을 묻는다. 되돌릴 수 없다)
- IP가 바뀌었을 때: `multipass/update-hosts.sh` (~/.ssh/config.d/platform-infra와 VM 안의 /etc/hosts를 다시 쓴다)
- 통신 확인: `multipass/check-network.sh`
- Ansible 연결 확인: `cd ansible && ansible all -m ping`
- 접속: `ssh cp1`, `ssh worker1`, `ssh worker2` (전용 키 ~/.ssh/platform_ed25519)

## 진행 단계

- 1단계: VM과 Ansible 준비 (완료 시 README에 기록)
