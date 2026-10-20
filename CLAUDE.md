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

- VM 3대: cp1(컨트롤 플레인, 2GB), worker1·worker2(각 4GB). Ubuntu 24.04, Multipass(QEMU)로 만든다. 클러스터를 쓸 때 Docker Desktop은 끈다 (맥 16GB).
- DB는 MySQL 하나만 클러스터에 두고, 서비스별로 DB와 전용 계정을 나눈다 (coupon, auth, notification, file). 메모리를 아끼기 위해서다.
- k3s 기본 구성요소(Traefik, ServiceLB, local-path, metrics-server)는 켜둔다. cp1에는 control-plane NoSchedule taint를 건다.
- 플레이북은 멱등하게 쓴다: 확인용 command에는 changed_when: false, 설치는 when 조건, 서비스 재시작은 핸들러로.
- 비밀은 Ansible Vault(`group_vars/all/vault.yml`, `vault_` 접두사)에 두고 Ansible이 쿠버네티스 Secret을 만든다. Secret 매니페스트는 저장소에 두지 않는다.
- MySQL: `data` 네임스페이스 StatefulSet, worker1 고정 경로 PV(Retain). 앱 접속 정보 Secret은 `apps` 네임스페이스의 `mysql-<서비스>`. 서비스 계정은 자기 DB에만 권한(DROP 없음).
- 배치: MySQL은 worker1(`[mysql]`), Redis·Kafka는 worker2(`[queue]`), 앱은 스케줄러가 나눔. 모든 파드에 `enableServiceLinks: false`.
- 이미지 태그는 커밋 해시만 쓴다 (latest 금지). Java 앱은 메모리 requests = limits, CPU limit 없음, 실측해서 limit을 정한다.
- MySQL 계정 연결 상한 = (replicas + maxSurge) × 커넥션 풀 + 여유 (`mysql_service_max_connections_overrides`).
- 메모리 계획은 `docs/memory-plan.md`. 새 구성요소를 넣을 때 이 문서의 예산을 먼저 확인하고, 올린 뒤 실측해서 고친다 (워커 여유 목표 15%, limit 합 기준 지금 5%: 다음 서비스부터 실측으로 limit을 정한다).
- VM 크기 바꾸기: 한 대씩 `kubectl drain` → `multipass stop` → `multipass set local.<이름>.memory=…` → start → `kubectl uncordon`, `multipass/vms.conf`도 고친다.

## 명령어

- VM 만들기: `multipass/create-vms.sh` (이미 있는 VM은 건너뛴다)
- VM 삭제: `multipass/delete-vms.sh` (확인을 묻는다. 되돌릴 수 없다)
- IP가 바뀌었을 때: `multipass/update-hosts.sh` (~/.ssh/config.d/platform-infra와 VM 안의 /etc/hosts를 다시 쓴다)
- 통신 확인: `multipass/check-network.sh`
- Ansible 연결 확인: `cd ansible && ansible all -m ping`
- 접속: `ssh cp1`, `ssh worker1`, `ssh worker2` (전용 키 ~/.ssh/platform_ed25519)
- k3s 설치·설정 맞추기: `cd ansible && ansible-playbook site.yml` (멱등. 두 번째 실행은 changed=0이어야 한다)
- k3s 완전 제거: `cd ansible && ansible-playbook k3s-uninstall.yml -e confirm=yes` (클러스터 안의 데이터도 지워진다)
- MySQL 배포: `cd ansible && ansible-playbook mysql.yml` (vault 비밀번호 파일 `ansible/.vault-pass` 필요)
- 비밀 보기·고치기: `ansible-vault view|edit group_vars/all/vault.yml`. 평문 비밀번호를 파일·출력·커밋에 남기지 않는다 (no_log, check-secrets.sh hook)
- MySQL 백업: `kubectl -n data create job --from=cronjob/mysql-backup <이름>`, 맥으로: `scripts/fetch-mysql-backups.sh`, 복구: `scripts/mysql-restore.sh <DB> <폴더>`
- Redis·Kafka: `ansible-playbook redis.yml`, `kafka.yml` (worker2 고정). Kafka 도구는 일회용 파드에서: `kubectl -n data run kcli --rm -it --image=apache/kafka:4.3.1 --overrides='{"spec":{"enableServiceLinks":false}}' -- bash`
- 쿠폰 서버: `ansible-playbook coupon.yml -e coupon_image_tag=<coupon-system 커밋 해시>`. 이미지는 coupon-system의 GitHub Actions가 GHCR에 올린다 (맥 Docker 안 씀)
- kubectl: kubeconfig는 `~/.kube/platform-infra.yaml`, 컨텍스트 `platform-infra` (~/.zshrc의 KUBECONFIG에 등록)

## 진행 단계

- 1단계: VM과 Ansible 준비 (완료)
- 2단계: Ansible로 k3s v1.36.5+k3s1 설치 (완료). 설계는 `docs/k3s-design.md`, 검증 기록은 `docs/k3s-verification.md`
- 3단계: MySQL 8.4.11 (완료). 설계는 `docs/mysql.md`, 검증·복구 훈련 기록은 `docs/mysql-verification.md`
- 4단계: Redis·Kafka, 쿠폰 서버 이전 (완료). `docs/redis-kafka.md`, `docs/coupon.md`
- 다음: 플랫폼 서비스(Gateway·인증·알림·파일), ArgoCD, 모니터링. Secret 저장 암호화·NetworkPolicy는 Vault 단계에서
