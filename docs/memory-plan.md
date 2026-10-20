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

## 실측 (워커 4GB 변경 후, 2026-10-20)

VM 안 `free -m` 기준. VM의 실제 총량은 커널 몫을 빼고 cp1 1955MB, worker 3901MB다 (4096이 아님).

- cp1: used 870~1216MB, available 740~1085MB (k3s-server가 약 1GB, 시간에 따라 흔들림)
- worker1: OS + k3s agent 약 400MB, MySQL 포함 used 568MB (MySQL 재시작 직후라 버퍼 풀이 빈 상태)
- worker2: OS + k3s agent + Traefik 444MB
- MySQL 파드 (cgroup): 재시작 직후 151MiB → 100만 줄 넣은 직후 620MiB (실제 사용 anon 403MiB + 파일 캐시 209MiB)
  - 파일 캐시는 메모리가 부족하면 커널이 돌려받는다. limit 768Mi는 이 최대치보다 150MB 정도 여유가 있다

## 예산표 (limit 기준 = 최악의 경우)

"측정"은 실제로 잰 값, "추정"은 공식 문서·흔한 설정 기준의 예상치다. 단위 MB.
배치는 권장안이다. MySQL·Redis·Kafka만 worker1에 고정하고, 나머지는 스케줄러가 requests를 보고 정한다.

```
노드 (실제 총량)        구성요소                       예산   근거
─────────────────────────────────────────────────────────────────────────
cp1 (1955)              k3s server + 기본 구성요소     1216   측정 최대치
                        (taint: 앱 파드 금지)           ────
                                                       남음 약 740
─────────────────────────────────────────────────────────────────────────
worker1 (3901)          OS + k3s agent                  400   측정
  데이터 + 일부 앱      MySQL                           768   limit (측정 최대 620)
                        Redis 7                         128   추정 (실사용 30~60)
                        Kafka 1대 (KRaft, 힙 512M)      768   추정
                        쿠폰 서버 1번                   512   limit (추정)
                        모니터링 (Prometheus 계열)      900   추정: Prometheus 500, Grafana 150, 나머지 250
                                                       ────
                                                       3476   남음 425 (11%)
─────────────────────────────────────────────────────────────────────────
worker2 (3901)          OS + k3s agent + Traefik        444   측정
  앱                    쿠폰 서버 2번                   512   limit (추정)
                        Gateway·인증·알림·파일 × 4    1792   limit 448 × 4 (추정)
                        ArgoCD (최소 구성)              600   추정: controller 300, repo-server 150, server 100, redis 50
                                                       ────
                                                       3348   남음 553 (14%)
─────────────────────────────────────────────────────────────────────────
워커 합계               필요 6824 / 용량 7802 → 남음 978 (13%)
```

- 쿠폰 서버 2대는 노드를 나눠 둔다 (podAntiAffinity). 한 노드가 죽어도 쿠폰 발급이 멈추지 않게 하는 실습도 된다
- (3GB 때는 필요 6750 / 용량 5912 → 약 840 부족이었다)

## 판단

- 전체 계획이 **들어간다**. 다만 여유가 13%로 목표(15%)보다 조금 적다
- limit은 최악의 경우라 평소 사용량은 이보다 낮다. 그래도 아래를 지킨다
  - 새 구성요소를 올릴 때마다 `free -m`의 available과 `kubectl top pods -A`로 실측해서 이 표를 고친다
  - Spring 앱은 처음 배포할 때 실제 사용량을 재고 limit을 정한다 (추정 448~512MB가 크면 줄인다)
  - 모니터링이 생각보다 크면 VictoriaMetrics로 바꾸는 안(약 -500MB)을 쓴다
- 노드의 available이 300MB 아래로 내려가면 쿠버네티스가 파드를 쫓아내기(eviction) 시작할 수 있다

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
