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

## 7단계 실측: 인증 서버 추가, 쿠폰 서버 증가

- **인증 서버(auth)**: 로그인·발급 부하에서 RSS 최대 약 354MiB = 힙 확보 88(사용 최대 75~78) + 힙 밖 183(Metaspace 122, 코드 캐시 44) + 네이티브 약 83, 스레드 40
  - 힙 160MB 고정(`-Xmx160m`, 사용 최대의 2배) → 최대치 160 + 195 + 90 ≈ 445MiB → **limit 512Mi** (87%). 바꾼 뒤 1분 부하: 오류 0, RSS 약 350(68%)
- **쿠폰 서버**: Spring Security·OAuth2 리소스 서버를 넣자 힙 밖이 186 → 233MiB(Metaspace 138 → 153, 코드 캐시 47 → 62), RSS 598MiB / 640 (93%, `JavaContainerMemoryHigh` pending)
  - 부하 때 힙 사용 최대 약 183MB라 힙 256은 줄이지 않는다 → 최대치 256 + 235 + 120 ≈ 611MiB → **limit 640 → 704Mi** (87%), 힙은 `-Xmx256m`으로 고정
- 힙을 limit의 비율(`MaxRAMPercentage`)이 아니라 `-Xmx`로 정했다: limit을 바꿔도 힙이 따라 변하지 않아 계산이 분명하다

## 예산 (limit 기준 = 최악의 경우, 워커 2대)

```
구성요소                              limit 합   실측 최대   근거
──────────────────────────────────────────────────────────────────────
OS + k3s agent (워커 2대)                 800        800   측정
쿠폰 서버 × 2                            1408      1200   limit 704 (RSS 약 600)
인증 서버 × 2                            1024       708   limit 512 (RSS 약 354)
MySQL                                     640        620   100만 줄 부하
Kafka                                     640        501
Redis                                     160         32
ArgoCD (4개)                              576        301
모니터링 (VM, Grafana, vmalert,           912        420
  Alertmanager, ksm, node-exporter, exporter 3)
──────────────────────────────────────────────────────────────────────
지금 떠 있는 것 합계                     6160       4582   용량 7802 → limit 기준 여유 21%
──────────────────────────────────────────────────────────────────────
15% 여유를 지키는 상한 (7802 × 0.85)     6632
→ 남은 서비스(Gateway·알림)에 쓸 수 있는 limit 합: 472
```

바뀐 것: 6단계 5008 → 7단계 6160 (인증 서버 +1024, 쿠폰 서버 +128)

## 판단 (7단계): Gateway·알림을 지금 방식으로는 15% 안에 못 넣는다 → 8단계에서 2번을 골랐다

- 인증 서버만큼(512) 쓰는 서비스를 2대씩 올리면 2 × 2 × 512 = 2048 → 합 8208로 **용량(7802)을 넘는다**
- 남은 예산은 472MiB뿐이다. 선택지:
  1. **알림 서버는 1대**(비동기 처리라 사용자 응답 시간에 직접 영향이 없다) + **Gateway도 1대로 시작**: 2 × 512 = 1024 → 합 7184, 여유 8%
  2. **Gateway를 별도 Spring 서비스 대신 Traefik 기능으로**(라우팅·속도 제한은 Traefik 미들웨어, 토큰 검증은 각 서비스가 이미 한다): Gateway 몫 0 → 알림 1~2대만 추가
  3. **기존 것을 더 줄이기**: Kafka 힙 384 → 256(전체 GC 기록으로 필요량 확인 후), 모니터링 보관 기간·Grafana 조정 등. 수백 MB 수준
  4. VM을 더 키우기는 어렵다 (맥 16GB 중 VM 10GB + macOS 5GB)
- 실측 기반으로는 여유가 41%다. limit 합이 빠듯한 이유는 JVM 서비스의 limit을 최악의 경우(힙이 최대까지 찬 상태)로 잡기 때문이다

## 8단계: Gateway를 Traefik으로, 알림 서버 예산

- Gateway는 별도 Spring 서비스가 아니라 Traefik 미들웨어로 만들었다 (docs/gateway.md) → **워커 예산에서 Gateway 몫 0**
- Traefik(cp1): 요청 ID 플러그인·버퍼링·요청 제한을 넣고 k6 부하(초당 약 240건)에서 RSS 최대 **59MiB** (전에는 최대 34MiB)
  - limit을 처음으로 정했다: **128Mi** (46%). 차트가 `GOMEMLIMIT=115MiB`를 넣어 Go GC가 그 전에 회수한다
  - cp1은 워커 예산과 따로다: 지난 1시간 사용 최대 1464 / 1955MB (여유 약 25%)
- 워커 limit 합은 그대로 **6160MiB** (인증·쿠폰 서버의 limit은 바꾸지 않음. k6 부하 때 RSS 인증 334 / 512, 쿠폰 602 / 704)

### 알림 서버에 쓸 수 있는 예산

```
15% 여유를 지키는 상한 (7802 × 0.85)      6632
지금 limit 합                             6160
──────────────────────────────────────────────
알림 서버에 쓸 수 있는 limit 합             472 MiB
```

- 인증 서버(웹 + JPA + Redis, 실측 RSS 약 330~354MiB)를 기준으로 하면 알림 서버 1대는 limit **448Mi**(힙 128MB)면 들어간다 → 합 6608, 여유 15.3%
- 2대(896)는 합 7056, 여유 9.6% → 15% 목표를 넘긴다. 알림은 Kafka에서 이벤트를 받아 비동기로 보내므로 1대가 잠깐 멈춰도
  이벤트는 Kafka에 남아 다시 처리된다 → **1대로 시작**하는 것이 맞는 자리다 (사용자 응답 경로에 없다)
- 사용자용 웹 API 없이 Kafka 소비자 + actuator(지표·상태 확인)만 두면 인증 서버보다 작아질 수 있다 → 만들 때 실측해서 정한다

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
