# 4단계 설계: Redis와 Kafka

쿠폰 발급 경로에 쓰는 Redis 7.4(재고 판정)와 Kafka 4.3(발급 메시지 큐, KRaft 단일 노드)를 `data` 네임스페이스에 StatefulSet으로 둔다.

## 쿠폰 발급 흐름과 각자의 역할

```
POST /coupons/{id}/issue
  │
  ├─ Redis (Lua 스크립트 한 번): 기간·재고·중복 검사 → 카운터 +1, 발급 유저 목록에 추가     ← 선착순 판정
  ├─ Kafka: 발급 메시지 전송 (acks=all) → 202 응답                                       ← 여기까지가 "발급 API"
  │
  └─ Kafka 컨슈머 (쿠폰 서버 안): 메시지를 받아 MySQL coupon_issue에 저장                 ← 비동기 저장
       실패하면 1초 간격 3번 재시도 → 그래도 실패하면 DLT 토픽
  대사 작업 (매분, ShedLock으로 한 서버만): Redis 발급 목록 ↔ MySQL을 비교해 빠진 쪽을 채운다  ← 안전망
```

## 배치: MySQL은 worker1, Redis와 Kafka는 worker2

인벤토리 그룹으로 정한다: `[mysql]` = worker1, `[queue]` = worker2 (`ansible/inventory.ini`).

이유:
1. **메모리 분산**: 상태를 가진 구성요소의 limit 합이 worker1 768MB(MySQL), worker2 960MB(Kafka 768 + Redis 192)로 비슷해진다.
   상태 없는 쿠폰 서버 2대는 스케줄러가 노드마다 1대씩 나눈다(topologySpreadConstraints).
2. **장애가 겹치는 경우를 줄인다**: 발급 API는 Redis와 Kafka만 있으면 응답한다. 둘을 같은 노드에 두면
   "발급이 멈추는 노드"가 worker2 하나뿐이다. 둘을 다른 노드에 나누면 둘 중 어느 노드가 죽어도 발급이 멈춘다.
   반대로 worker1(MySQL)이 죽으면 발급은 계속되고 저장만 늦어진다 (컨슈머 재시도 → DLT → 대사 작업이 나중에 채움).
3. 셋 다 local PV라 노드에 고정된다. 한 번 정하면 옮기기 어려우므로(데이터 폴더를 옮겨야 함) 처음에 정한다.

## 데이터 보존

공통: MySQL과 같은 방식. 노드의 고정 경로를 가리키는 PV(`Retain`, `claimRef`, `nodeAffinity`)를 직접 만든다.
- Redis: worker2 `/srv/data/redis` (uid 999, gid 1000)
- Kafka: worker2 `/srv/data/kafka` (uid 1000, gid 1000)
→ 파드를 지워도, k3s를 지우고 다시 깔아도 남는다.

### Redis: AOF, 1초마다 fsync

- Redis는 보통 "캐시"라 날아가도 된다고 생각하지만, 여기서는 **재고 카운터와 발급 유저 목록이 들어 있는 데이터**다.
  비면 카운터가 0부터 다시 세져서, 대사 작업이 DB 기준으로 채우기 전(최대 1분)에 정해진 수량보다 많이 발급될 수 있다.
- `appendonly yes`: 쓰기 명령을 파일(AOF)에 이어 쓰고, 다시 켤 때 그대로 재생한다.
- `appendfsync everysec`: 1초마다 디스크에 확실히 기록 → 최악의 경우 마지막 1초를 잃는다 (always는 매 명령마다라 느리다).
- `save ""`: RDB 스냅샷은 끈다. AOF와 둘 다 쓰면 fork가 두 번 일어나 메모리가 더 튄다. (AOF 파일 앞부분이 RDB 형식이라 재시작은 빠르다)
- `maxmemory 64mb` + `maxmemory-policy noeviction`: 꽉 차면 키를 지우지 않고 쓰기를 거부한다.
  캐시라면 오래된 키를 지우는 게 맞지만, 재고 카운터가 조용히 지워지면 초과 발급이 나므로 "실패를 드러내는" 쪽을 고른다.
- limit 192Mi = maxmemory의 3배: AOF를 다시 쓸 때(rewrite) fork로 잠깐 메모리가 늘어난다(copy-on-write).
- 비밀번호(`requirepass`)는 ConfigMap이 아니라 Secret으로 마운트한 `auth.conf`를 `include`로 읽는다. 명령줄 인자(`--requirepass`)로 주면 `ps`에 보인다.
  앱은 `apps` 네임스페이스의 Secret `redis`(password, host, port)를 받는다.

### Kafka: KRaft, 고정 클러스터 ID, 1초마다 flush

- KRaft: ZooKeeper 없이 브로커가 메타데이터도 직접 관리한다. 1대가 브로커와 컨트롤러를 겸한다(`process.roles=broker,controller`).
- `CLUSTER_ID` 고정: 처음 켤 때 데이터 폴더를 이 ID로 포맷하고 `meta.properties`에 적는다. 다시 켤 때 ID가 다르면 기존 데이터를 열지 않으므로, 값을 롤 기본값에 고정했다 (비밀 아님).
- `log.dirs=/var/lib/kafka/data`: 이미지 기본값은 `/tmp`라 재시작하면 사라진다.
- 복제본 1: 브로커가 1대라 모든 토픽(내부 토픽 포함)의 복제본이 1개다. 쿠폰 서버도 `KAFKA_REPLICATION_FACTOR=1`로 토픽을 만든다.
- `log.flush.interval.ms=1000`: Kafka는 원래 복제본으로 안전을 지키고 디스크 쓰기는 OS에 맡긴다. 복제본이 없으니 1초마다 직접 flush해서,
  VM이 갑자기 꺼져도 잃는 메시지를 1초 안으로 줄인다 (Redis와 같은 기준). 그래도 잃은 발급은 대사 작업이 Redis 기록으로 DB를 채운다.
- 보관 72시간, 세그먼트 64MB: 메시지는 몇 초 안에 DB로 저장되므로 오래 둘 필요가 없다.
- `auto.create.topics.enable=false`: 토픽은 쿠폰 서버의 `NewTopic` 설정(파티션 3)대로만 만든다. 오타 난 이름으로 토픽이 저절로 생기지 않게.
- 보안: 지금은 PLAINTEXT(암호화·인증 없음), 클러스터 안에서만 보인다. SASL·NetworkPolicy는 Vault 단계에서.

### 검증

- Redis 키와 Kafka 메시지를 넣고 두 파드를 동시에 지움 → 8초 뒤 둘 다 Ready, 키와 메시지 그대로

## Probe

- **Redis**: 셋 다 `redis-cli ping | grep -q PONG` (비밀번호는 `REDISCLI_AUTH` 환경변수)
  - AOF를 다시 읽는 동안에는 `LOADING`으로 답한다 → startupProbe(3초 × 60번)가 PONG을 기다려 준다
- **Kafka**: 셋 다 `tcpSocket` 9092 (포트가 열려 있나)
  - `kafka-broker-api-versions.sh` 같은 exec 검사는 매번 JVM을 새로 띄워 수백 MB와 몇 초를 쓴다. 작은 노드에서는 검사 자체가 메모리 부족을 만든다
  - Kafka는 로그 복구가 끝나야 9092를 연다 → 포트 검사만으로도 "시작 완료"를 꽤 정확히 알 수 있다
  - 같은 이유로 Kafka 명령줄 도구는 브로커 컨테이너가 아니라 별도 일회용 파드에서 실행한다 (브로커 limit 768Mi 안에서 JVM이 하나 더 뜨면 OOM 위험)

## 메모리 설정

- Redis: requests 64Mi, limit 192Mi, maxmemory 64mb
- Kafka: requests 512Mi, limit 768Mi, 힙 384m 고정 (`KAFKA_HEAP_OPTS=-Xms384m -Xmx384m`)
  - limit의 나머지 384Mi: JVM 자체(메타스페이스, 스레드), 네트워크 버퍼, 그리고 Kafka가 크게 기대는 OS 페이지 캐시
  - 네트워크 스레드 2, I/O 스레드 4 (기본 3, 8): 트래픽이 작고 CPU가 2개뿐이다

## 겪은 함정: `enableServiceLinks`

- 쿠버네티스는 파드를 만들 때 **같은 네임스페이스의 모든 Service**에 대해 `KAFKA_PORT=tcp://10.43.x.x:9092`, `REDIS_SERVICE_HOST=...` 같은 환경변수를 넣는다 (옛 Docker links 호환 기능).
- Kafka 이미지는 `KAFKA_`로 시작하는 환경변수를 전부 설정으로 바꾸므로, Service 이름이 `kafka`이면 `KAFKA_PORT=tcp://...`가 `port=tcp://...` 설정이 되어 시작이 깨질 수 있다 (알려진 함정이라 처음부터 막았다).
  Spring 앱도 같은 네임스페이스에 `redis`라는 Service가 있으면 `REDIS_PORT=tcp://...`를 포트 설정으로 읽어 숫자 변환에서 실패한다. 지금은 쿠폰 서버(apps)와 Redis(data)의 네임스페이스가 달라 해당하지 않지만, 같은 실수를 막으려고 끈다.
- 그래서 모든 파드(MySQL, 백업 CronJob, Redis, Kafka, 쿠폰 서버)에 `enableServiceLinks: false`를 넣었다. 서비스 주소는 DNS(`redis.data.svc.cluster.local`)로 찾는다.
- MySQL에는 실제로 `MYSQL_PORT`, `MYSQL_SERVICE_HOST` 등 12개가 들어가 있었고, 끈 뒤 0개가 됐다 (MySQL 1회 재시작).
