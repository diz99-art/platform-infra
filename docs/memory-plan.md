# 메모리 계획

전체 플랫폼(쿠폰·인증·Gateway·알림 서버 + 공용 미들웨어 + 운영 도구)이 다 올라갔을 때를 기준으로 세운 예산이다.
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

## 6단계에서 limit 합 여유 4%의 원인 (구성요소별, 5단계 계획 7504MB 기준)

- 상태 있는 구성요소의 limit이 실측보다 컸다: MySQL 768 (실측 220, 최대 620), Kafka 768 (최대 541), Redis 192 (최대 37)
- ArgoCD 704 (실측 합 215)
- 아직 없는 서비스의 추정치가 컸다: 플랫폼 서비스 4 × 512 = 2048, 모니터링 900
- 줄일 수 없는 것: 쿠폰 서버 2 × 640 (실측 최대 555~576, 아래 분석), OS·k3s 약 800

## 6단계 조정 (실측 근거)

- MySQL 768 → **640**: 버퍼 풀 256 고정, 100만 줄 부하 때 anon 최대 403
- Kafka 768 → **640**: 힙 384 고정 + 힙 밖 약 130 = 최대 약 515 (힙은 GC 로그상 필요량을 몰라 그대로)
- Redis 192 → **160**: maxmemory 64 × AOF fork 최대 2배
- ArgoCD 704 → 768 → **576**: server 128 → 96, redis 64 → 32. repo-server는 Helm 차트 렌더링 때 128·256Mi에서 OOMKilled → 320으로 올렸다가,
  Helm 차트를 **OCI 레지스트리(ghcr.io)**에서 받도록 바꿔(HTTP 저장소의 차트 목록 index.yaml을 받지 않음) 렌더링 최대 202 → 60Mi → **128**
- 모니터링 추정 900 → **실제 limit 912** (실측 최대 합 약 420): VictoriaMetrics 256, Grafana 320 (192로 시작했다가 OOMKilled), vmalert·Alertmanager 각 48, kube-state-metrics 64, node-exporter 32 × 워커 2, exporter 3개 112
- Traefik이 재시작하면서 cp1로 옮겨감 (k3s Traefik은 control-plane taint를 견딘다) → 워커 기준선 444 → 400, 대신 cp1 여유가 줄었다

## 쿠폰 서버 516 → 555Mi 분석 (limit은 줄이지 않음)

- 두 파드를 Actuator 지표로 나눠 보면 **힙 밖 약 186MB, JVM이 모르는 네이티브 약 100MB는 두 파드가 같다.** 차이는 힙 확보량(248MB vs 93MB)뿐
- 힙이 큰 파드도 오래 사는 객체(Tenured)는 170MB를 확보해 놓고 49MB만 쓴다 → **누수가 아니다.** 부하 때 SerialGC가 힙을 최대(256MB) 가까이 늘려 놓고 운영체제에 잘 돌려주지 않는 것
- 최대치 계산: 힙 256 + 힙 밖 187 + 네이티브 약 105 ≈ 548MB → 실측 최대 548~576(working set, 캐시 약간 포함)과 맞다. 이보다 커지지 않는다
- 그래서 RSS 기준 85~89%에 머무르고 `ContainerMemoryHigh` 알림이 울린다 (아래 "판단"의 선택지)

## 실측 (6단계: 모니터링 설치 후, 2026-10-20)

VM 안 `free -m` 기준, 끊김 조사 부하(초당 약 1,500건) 뒤.

- cp1: used 1366MB, available **589MB** (k3s-server + Traefik + node-exporter. 5단계 778MB에서 줄었다)
- worker1: used 1575MB, available 2326MB
- worker2: used 2209MB, available 1691MB (모니터링 대부분이 worker2에 몰림: 스케줄러는 requests만 본다)
- 지난 1시간 최대(working set): 쿠폰 555 / Kafka 501 / MySQL 227 / Redis 32 / ArgoCD controller 178, repo-server 202(렌더링 순간), server 57 / Grafana 305(RSS 211) / VictoriaMetrics 115 / 나머지 모니터링 각 9~16 Mi
- 스케줄러 기준 requests 합: worker1 1440Mi, worker2 1640Mi. limits 합: worker1 2000Mi, worker2 2400Mi

## 예산 (limit 기준 = 최악의 경우, 워커 2대)

6단계 후속 결정: **파일 서버는 계획에서 뺐다**(MySQL `file` DB·계정·Secret도 지움). 플랫폼 서비스(Gateway·인증·알림)의 limit은 **미리 정하지 않고 인증 서버를 만들 때 실측해서 정한다.**

```
구성요소                              limit 합   실측 최대   근거
──────────────────────────────────────────────────────────────────────
OS + k3s agent (워커 2대)                 800        800   측정
쿠폰 서버 × 2                            1280      1110   limit 640 (RSS 최대 약 555)
MySQL                                     640        620   100만 줄 부하
Kafka                                     640        501
Redis                                     160         32
ArgoCD (4개)                              576        301   OCI 전환 후 repo-server 렌더링 최대 60
모니터링 (VM, Grafana, vmalert,           912        420   Grafana는 RSS 기준
  Alertmanager, ksm, node-exporter, exporter 3)
──────────────────────────────────────────────────────────────────────
지금 떠 있는 것 합계                     5008       3784   용량 7802 → limit 기준 여유 36%
──────────────────────────────────────────────────────────────────────
15% 여유를 지키는 상한 (7802 × 0.85)     6632
→ 플랫폼 서비스 3개(Gateway·인증·알림)에 쓸 수 있는 limit 합: 1624 (평균 541Mi)
```

- 쿠폰 서버만큼(640) 쓰면 3 × 640 = 1920 → 합 6928, 여유 11% → 그때는 쿠폰 서버보다 가볍게 만들거나(의존성·힙) 다른 곳을 줄여야 한다
- 인증 서버를 만들면 실측(`memory.peak`, RSS, JVM 힙·힙 밖)으로 limit을 정하고, 이 표를 고친다. 그 값을 보고 Gateway·알림의 예상치를 정한다

바뀐 것: 5단계 7504 → 6단계 1차 7248(플랫폼 서비스 4 × 512 추정 포함) → 지금 5008 + 서비스 3개(미정)
(MySQL −128, Kafka −128, Redis −32, ArgoCD 704 → 576, 모니터링 900 → 912, 기준선 −44, 파일 서버 제외)

## 판단

- **지금 떠 있는 것 기준 여유 36%**. 플랫폼 서비스 3개를 합 1624Mi 안에 올리면 15%를 지킨다
- 6단계 1차 계산(7%)이 목표에 못 미쳤던 이유: 플랫폼 서비스 4 × 512 추정치, Helm 렌더링으로 커진 repo-server, Grafana 13
  → 파일 서버 제외, OCI로 repo-server 320 → 128, 서비스는 실측으로 정하기로 바꿨다
- 쿠폰 서버는 RSS 85~89%에 머문다 (SerialGC가 힙을 최대 가까이 확보, 위 분석). Java 앱 메모리 알림은 90%, 힙 사용률은 따로 본다 (docs/monitoring.md)
- cp1은 여유가 589MB로 줄었다 (Traefik이 cp1로 옮겨감). cp1에 새 구성요소를 두지 않는다

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
