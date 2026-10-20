# 메모리 계획

전체 플랫폼(쿠폰·인증·Gateway·알림·파일 서버 + 공용 미들웨어 + 운영 도구)이 다 올라갔을 때를 기준으로 세운 예산이다.
새 구성요소를 넣을 때는 아래 예산표를 먼저 고치고, 합계가 VM 메모리를 넘지 않는지 확인한다.

## 맥 사양 (2026-10-20 확인)

- Apple M2 Pro, CPU 10코어, 메모리 16GB, 디스크 남은 공간 89GB
- Docker Desktop: 처음 7.75GB → 3GB로 줄임 → 클러스터를 쓸 때는 끈다

## 맥 메모리 16GB 나누기 (2026-10-20 변경: 워커 3GB → 4GB)

- macOS + 브라우저 + IDE: 약 5GB
- VM 3대: 최대 10GB (cp1 2GB, worker1 4GB, worker2 4GB)
- 합계 15GB → **클러스터를 쓸 때는 Docker Desktop을 끈다** (켜면 3GB가 더해져 18GB, 맥이 스왑을 쓰며 느려진다)
- 컨테이너 이미지 빌드는 GitHub Actions(public 저장소 무료)에서 하거나, 빌드할 때만 Docker Desktop을 잠깐 켠다

Multipass(QEMU)는 VM에 준 메모리를 처음부터 다 잡지 않고 VM 안에서 쓰는 만큼 가져간다.
(변경 직후 실측: QEMU 프로세스 3개 합계 약 2.9GB, 맥 메모리 여유 62%) 하지만 서비스가 다 올라가면 거의 다 쓰게 되므로 예산은 최대치로 잡는다.

### 워커 메모리를 바꾼 방법 (한 대씩, 운영 방식 그대로)

```bash
kubectl drain worker2 --ignore-daemonsets --delete-emptydir-data   # 파드를 다른 노드로 옮기고 새 배치 금지
multipass stop worker2
multipass set local.worker2.memory=4G
multipass start worker2
kubectl uncordon worker2                                           # 다시 배치 허용
```

- worker2: 18초. Traefik이 worker1로 옮겨갔다가 돌아옴
- worker1: MySQL이 worker1에 고정이라 drain 중 `Pending`으로 기다림 → **MySQL 중단 28초**. 데이터 그대로
- IP 변화 없음, `check-network.sh` 15개 OK, `site.yml`·`mysql.yml` 모두 changed=0
- `multipass/vms.conf`도 4G로 고쳤다 (VM을 새로 만들 때 같은 크기가 되도록)

## 실측 (5단계: ArgoCD 설치 후, 2026-10-20)

VM 안 `free -m` 기준, 배포 중 발급 부하(약 16만 건)를 준 직후. VM의 실제 총량은 커널 몫을 빼고 cp1 1955MB, worker 3901MB다.

- cp1: used 1176MB, available 778MB (k3s-server 약 1GB. 870~1216MB 사이에서 흔들림)
- worker1: used 1316MB, available 2584MB (MySQL, 쿠폰 서버 1대, ArgoCD controller·repo-server·redis)
- worker2: used 1595MB, available 2305MB (Redis, Kafka, 쿠폰 서버 1대, ArgoCD server, Traefik)
- 파드 (cgroup anon = 실제 사용):
  - 쿠폰 서버 361·516Mi / limit 640Mi (부하를 많이 받은 쪽이 81%. 4단계 494 → 516으로 조금씩 오름)
  - Kafka 483Mi / 768Mi (4단계 423 → 483. 힙 384m 고정이라 쓴 만큼 실제 메모리로 채워진다)
  - MySQL 220Mi / 768Mi (100만 줄 넣었을 때 최대 620Mi), Redis 27Mi / 192Mi (발급 기록 약 30만 건)
  - ArgoCD: controller 161, repo-server 28, server 22, redis 4 = 215Mi / limit 합 704Mi
  - kube-system 합계 약 173Mi (Traefik 127Mi)
- 스케줄러가 보는 메모리 requests 합: worker1 1424Mi, worker2 1280Mi

## 예산표 (limit 기준 = 최악의 경우)

"측정"은 실제로 잰 값, "추정"은 아직 배포하지 않아 공식 문서·쿠폰 서버 실측을 바탕으로 한 예상치다. 단위 MB.
상태가 있는 것(MySQL, Redis, Kafka)은 노드에 고정, 나머지는 스케줄러가 requests를 보고 정한다. 아래 배치는 그 예상이다
(ArgoCD는 실제로는 두 노드에 나뉘어 떴지만 표에서는 worker2에 몰아 적었다).

```
노드 (실제 총량)        구성요소                         예산   근거
───────────────────────────────────────────────────────────────────────────
cp1 (1955)              k3s server + 기본 구성요소       1216   측정 최대치
                        (taint: 앱 파드 금지)             ────
                                                         남음 약 740
───────────────────────────────────────────────────────────────────────────
worker1 (3901)          OS + k3s agent                    400   측정
  저장 경로             MySQL                             768   limit (측정 220, 최대 620)
                        쿠폰 서버 1번                     640   limit (측정 최대 516)
                        모니터링 (Prometheus 계열)        900   추정
                        플랫폼 서비스 2개 × 512          1024   추정 (쿠폰 서버 실측 기준)
                                                         ────
                                                         3732   남음 169 (4%)
───────────────────────────────────────────────────────────────────────────
worker2 (3901)          OS + k3s agent + Traefik          444   측정
  발급 경로             Redis                             192   limit (측정 27)
                        Kafka                             768   limit (측정 483)
                        쿠폰 서버 2번                     640   limit (측정 최대 516)
                        ArgoCD                            704   limit 합 (측정 215)   ← 추정 600에서 변경
                        플랫폼 서비스 2개 × 512          1024   추정
                                                         ────
                                                         3772   남음 129 (3%)
───────────────────────────────────────────────────────────────────────────
워커 합계 (limit)       필요 7504 / 용량 7802 → 남음 298 (4%)
```

바뀐 것: 3단계 계획 6824 → 4단계 7400 (쿠폰 서버 512→640 × 2, 다른 Spring 서비스 448→512 × 4, Redis 128→192) → 5단계 7504 (ArgoCD 추정 600 → limit 합 704).

### 세 가지 기준으로 다시 본 여유율

- **limit 합 (모두가 동시에 상한까지 쓰는 최악의 경우)**: 7504 / 7802 → **여유 4%**. 목표(15%)보다 적다
- **실측 기반 예상 (부하 직후 수준)**: OS·k3s 844 + MySQL 620 + Redis 30 + Kafka 490 + 쿠폰 2 × 520 + 다른 서비스 4 × 420 + ArgoCD 220 + 모니터링 700 = 5624 / 7802 → **여유 28%**
- **requests 합 (스케줄러 기준)**: 지금 worker1 1424Mi, worker2 1280Mi. 전부 올려도 노드당 약 2.9GB로 allocatable(약 3.9GB) 안 → 배치는 된다

## 판단

- 쿠버네티스에서 limit 합이 용량에 가까운 것(오버커밋) 자체는 흔하다. 모든 파드가 동시에 상한까지 쓰는 일은 드물다
- 하지만 노드의 available이 300MB 아래로 떨어지면 kubelet이 파드를 쫓아내기(eviction) 시작한다. 지금 계획은 최악의 경우 그 근처까지 간다
- 그래서 다음을 지킨다
  - 새 서비스는 **올린 뒤 실측해서 limit을 정한다**. 쿠폰 서버보다 라이브러리가 적은 서비스는 400~450MB로 충분할 가능성이 크다 (4 × 60 = 약 240MB 절약)
  - ArgoCD limit 704 → 약 500 후보 (실측 215, repo-server의 렌더링 순간 최대치를 재 본 뒤): 약 200MB 절약
  - 모니터링을 Prometheus 대신 VictoriaMetrics + Grafana로 하는 안: 약 500MB 절약
  - ~~Kafka limit 768 → 640~~: 실측이 423 → 483으로 올라 보류 (640이면 75%)
  - 위 셋을 다 하면 limit 합 약 6560 → 여유 16%
- 쿠폰 서버는 부하를 받을수록 조금씩 올라간다(494 → 516). 모니터링을 올린 뒤 시간에 따른 추이를 보고 640Mi가 충분한지 다시 판단한다
- 노드 available은 `free -m`, 파드 실제 사용은 cgroup `memory.stat`의 anon으로 본다. `kubectl top`은 캐시가 섞여 들쭉날쭉하다

## MySQL을 하나만 두는 이유

- MySQL 서버 하나는 아무것도 안 해도 150~400MB를 쓴다 (실측: 재시작 직후 151MiB, 데이터를 쓰면 620MiB까지).
  서비스마다 따로 두면 4개 × 768MB limit = 3GB가 들고, 하나로 합치면 768MB면 된다.
- 대신 서비스끼리 데이터를 섞지 않도록 DB를 나누고, 계정마다 자기 DB에만 권한을 준다 (docs/mysql.md).
  → 실무의 "서비스별 DB 분리" 원칙을 지키면서 물리 서버만 공유하는 방식이다.
- 단점: MySQL이 죽으면 모든 서비스가 같이 멈춘다. 서비스 하나의 무거운 쿼리가 다른 서비스를 느리게 할 수 있다 (계정별 연결 수 제한으로 일부 막음).

## VM을 3대로 하는 이유 (2대와 비교)

- 2대(컨트롤 플레인 1 + 워커 1)면 VM 하나만큼 운영체제·k3s 오버헤드(약 300MB)를 아낄 수 있다.
- 하지만 워커가 1대면 "파드를 여러 노드에 나눠 배치", "노드 하나를 비우고(drain) 다른 노드로 옮기기", "노드 장애" 같은 쿠버네티스의 핵심 실습을 할 수 없다.

## 디스크

- cp1 15GB, worker1·worker2 각 20GB = 최대 55GB (메모리만 늘렸고 디스크는 그대로). 실제로는 쓴 만큼만 늘어난다 (thin provisioning).
- worker1의 MySQL 데이터(`/srv/data/mysql`)는 빈 상태 약 280MB, 100만 줄(80MB 테이블)을 넣었을 때 363MB. 백업은 같은 100만 줄이 gzip으로 7.5MB.
- local PV의 용량(5Gi)은 강제되지 않는다. worker1에서 `df -h /`로 가끔 확인한다.
