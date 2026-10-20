# 사내 플랫폼 인프라 (platform-infra)

k3s 클러스터에서 쿠폰·인증·Gateway·알림 서버를 운영하는 학습용 사내 플랫폼의 인프라 저장소.

## 사용자와 목적

- 사용자는 리눅스·네트워크·쿠버네티스 초보다. 목적은 학습과 백엔드·데브옵스 취업 대비다.
- 설명은 한국어로 한다.

## 작업 방식

- 완성된 코드와 설정을 바로 작성한다. 그 안에 쓰인 개념과 왜 그렇게 했는지를 함께 설명한다.
- 사용자가 직접 한 작업(명령, 설정, 코드)은 리뷰하고 개선점을 설명한다.
- 유료 서비스는 쓰지 않는다. 무료·오픈소스 도구만 쓴다 (Multipass, Ansible, k3s, GitHub 무료 플랜 등).
- 관리자 비밀번호(sudo)나 macOS 권한 허용이 필요한 작업은 사용자에게 명령을 알려주고 직접 실행하게 한다.

## 보고 방식

- 작업 중 설명은 짧게 한다. 자세한 설명(개념, 이유, 측정값, 겪은 문제)은 `docs/` 문서에 남기고 경로만 알려준다.
- 마지막 "Claude 전달용" 보고(형식은 사용자 전역 CLAUDE.md)에 아래 세 항목을 더한다. 표는 쓰지 않는다.
  사용자는 이 보고를 다른 Claude에게 가져가 설명을 듣는다 → 이 보고만 읽어도 맥락이 통하게, 용어는 정확한 이름으로 쓴다.
  - [설계 결정] 결정마다 한 줄씩: 무엇을 / 어떻게 / 왜 / 다른 선택지
  - [새 개념] 이번 작업에서 처음 나온 기술 용어 목록
  - [문서] 관련 docs 경로와 GitHub 링크

## 저장소 구성

- `coupon-system` (기존, ~/Projects/coupon-system): 선착순 쿠폰 발급 서버
- `platform-services`: 인증, Gateway, 알림 (파일 서버는 6단계에서 계획에서 뺐다)
- `platform-infra` (이 저장소): VM, k3s 클러스터, 공용 미들웨어(MySQL 등) 설정

## 핵심 결정

- VM 3대: cp1(컨트롤 플레인, 2GB), worker1·worker2(각 4GB). Ubuntu 24.04, Multipass(QEMU)로 만든다. 클러스터를 쓸 때 Docker Desktop은 끈다 (맥 16GB).
- DB는 MySQL 하나만 클러스터에 두고, 서비스별로 DB와 전용 계정을 나눈다 (coupon, auth, notification). 메모리를 아끼기 위해서다.
- k3s 기본 구성요소(Traefik, ServiceLB, local-path, metrics-server)는 켜둔다. cp1에는 control-plane NoSchedule taint를 건다.
- 플레이북은 멱등하게 쓴다: 확인용 command에는 changed_when: false, 설치는 when 조건, 서비스 재시작은 핸들러로.
- 비밀은 Ansible Vault(`group_vars/all/vault.yml`, `vault_` 접두사)에 두고 Ansible이 쿠버네티스 Secret을 만든다. Secret 매니페스트는 저장소에 두지 않는다.
- MySQL: `data` 네임스페이스 StatefulSet, worker1 고정 경로 PV(Retain). 앱 접속 정보 Secret은 `apps` 네임스페이스의 `mysql-<서비스>`. 서비스 계정은 자기 DB에만 권한(DROP 없음).
- 역할 분리: Ansible = VM·k3s·데이터 계층(MySQL·Redis·Kafka)·Secret·ArgoCD 자체, ArgoCD = 앱(`k8s/apps/`, Kustomize). AppProject `apps`는 Secret과 클러스터 전체 객체를 금지한다.
- 배치: MySQL은 worker1(`[mysql]`), Redis·Kafka는 worker2(`[queue]`), 앱은 스케줄러가 나눔. 모든 파드에 `enableServiceLinks: false`.
- 이미지 태그는 커밋 해시만 쓴다 (latest 금지). Java 앱은 메모리 requests = limits, CPU limit 없음, 실측해서 limit을 정한다.
- MySQL 계정 연결 상한 = (replicas + maxSurge) × 커넥션 풀 + 여유 (`mysql_service_max_connections_overrides`).
- limit은 실측 최대치(`memory.peak`, VictoriaMetrics의 max_over_time)를 근거로 정한다. 측정 조건이 실제 사용 조건을 대표하는지 먼저 확인한다 (repo-server: Kustomize만 렌더링할 때 값으로 줄였다가 Helm 렌더링에서 OOMKilled).
- 메모리 위험은 RSS / limit으로 본다 (working set은 파일 캐시 포함).
- 시험 스크립트에서 `git commit -a`를 쓸 때는 작업 트리가 깨끗한지 먼저 확인한다.
- 메모리 계획은 `docs/memory-plan.md`. 새 구성요소를 넣을 때 이 문서의 예산을 먼저 확인하고, 올린 뒤 실측해서 고친다 (워커 여유 목표 15%).
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
- ArgoCD 설치·설정: `ansible-playbook argocd.yml`. 화면 http://192.168.252.2/argocd/ (admin, 비밀번호는 vault의 vault_argocd_admin_password)
- 앱 배포는 GitOps: coupon-system에 push → Actions(test → image → deploy)가 `k8s/apps/coupon/kustomization.yaml`의 newTag를 바꿔 push → ArgoCD가 동기화. 사람이 newTag를 고치거나 kubectl apply로 앱을 바꾸지 않는다 (selfHeal이 되돌린다)
- 롤백: platform-infra에서 봇의 태그 커밋을 `git revert` 후 push. 지금 Git 확인: `kubectl -n platform annotate application coupon argocd.argoproj.io/refresh=normal --overwrite`
- CI(github-actions[bot])가 platform-infra main에 커밋한다 → 작업 전에 `git pull --rebase`
- 모니터링: Grafana http://192.168.252.2/grafana/ , Alertmanager /alertmanager/. 구성요소는 ArgoCD(`k8s/platform/monitoring`, Helm 앱 3개), Secret·Traefik 설정은 `ansible-playbook monitoring.yml`
- 대시보드 수정: `k8s/platform/monitoring/dashboards/gen_dashboards.py` 고치고 실행 → JSON까지 커밋. 알림 규칙 수정 뒤 `scripts/test-alerts.sh`
- vault 값 넣기(화면에 안 보이게): `scripts/set-vault-secret.sh <키>` (예: vault_discord_webhook_url)
- 오래 걸리는 시험 전에는 맥이 잠들지 않게 `caffeinate -is -t 7200`. 맥이 잠들면 VM이 멈춘다 (chrony가 깨어난 뒤 시계를 맞춘다)
- kubectl: kubeconfig는 `~/.kube/platform-infra.yaml`, 컨텍스트 `platform-infra` (~/.zshrc의 KUBECONFIG에 등록)

## 진행 단계

- 1단계: VM과 Ansible 준비 (완료)
- 2단계: Ansible로 k3s v1.36.5+k3s1 설치 (완료). 설계는 `docs/k3s-design.md`, 검증 기록은 `docs/k3s-verification.md`
- 3단계: MySQL 8.4.11 (완료). 설계는 `docs/mysql.md`, 검증·복구 훈련 기록은 `docs/mysql-verification.md`
- 4단계: Redis·Kafka, 쿠폰 서버 이전 (완료). `docs/redis-kafka.md`, `docs/coupon.md`
- 5단계: ArgoCD GitOps (완료). `docs/gitops.md`
- 6단계: 모니터링·알림, 메모리 조정, 끊김 조사 (완료). `docs/monitoring.md`, `docs/memory-plan.md`
- 다음: 플랫폼 서비스(Gateway·인증·알림). limit은 미리 정하지 않고 인증 서버를 만들 때 실측해서 정한다 (15% 여유를 지키려면 3개 합 1624Mi 안 = 평균 541Mi, docs/memory-plan.md). Secret 저장 암호화·NetworkPolicy는 Vault 단계에서
