# 4단계: 쿠폰 서버 쿠버네티스 이전

[coupon-system](https://github.com/diz99-art/coupon-system)을 `apps` 네임스페이스에 2대로 띄운다. 이미지는 GitHub Actions가 만든다 (맥의 Docker는 쓰지 않는다).

## 전체 흐름

```
coupon-system 저장소 (main에 push)
  └─ GitHub Actions
       test  (ubuntu-latest, x86): docker compose로 MySQL·Redis·Kafka → ./gradlew test        2분 32초
       image (ubuntu-24.04-arm):   테스트 통과 시 linux/arm64 이미지 빌드 → GHCR에 push       2분 2초
            ghcr.io/diz99-art/coupon-system:<커밋 해시>

platform-infra (맥)
  └─ ansible-playbook coupon.yml -e coupon_image_tag=<커밋 해시>
       ConfigMap coupon-config, Deployment coupon(2대), Service, PDB, Ingress  → apps 네임스페이스
       (Secret mysql-coupon, redis는 mysql.yml, redis.yml이 vault 값으로 이미 만들어 둠)

맥 브라우저 → 노드 IP:80 → Traefik → Service coupon:80 → 파드 8080
                                        파드 8081(Actuator)은 Service·Ingress로 열지 않음 (probe와 나중의 Prometheus만)
```

## 1. 이미지 빌드 (GitHub Actions)

- `coupon-system/.github/workflows/ci.yml`에 `image` job을 추가했다. `needs: test` + `main` push일 때만 → 테스트를 통과한 코드만 이미지가 된다.
- **ARM64 러너에서 바로 빌드**: k3s 노드(맥 M2 위 VM)가 ARM64다. x86 러너에서 QEMU로 ARM을 흉내 내면 Gradle 빌드가 몇 배 느려진다. public 저장소는 ARM 러너도 무료다.
- 로그인은 `GITHUB_TOKEN`: 실행할 때마다 GitHub가 발급하고 끝나면 사라지는 토큰. 권한은 job에 `packages: write`만 준다. 저장해 둔 비밀번호가 없다.
- `docker/metadata-action`이 OCI 라벨(`org.opencontainers.image.source`, `revision` 등)을 붙인다 → 이미지만 보고도 어느 저장소·커밋에서 왔는지 안다. 이 라벨로 패키지가 저장소에 연결되어 public 저장소의 패키지가 public이 됐다 (익명 pull HTTP 200 확인) → 클러스터에 pull secret이 필요 없다.
- 빌드 캐시: `cache-from/to: type=gha` → 의존성이 그대로면 Gradle 다운로드 층을 다시 쓴다. 실측: 첫 빌드 2분 2초 → 캐시가 있는 두 번째 빌드(README만 바뀐 커밋 `8983373`) 25초.
  README만 바뀌어도 이미지는 새로 만들어지지만, 클러스터는 `coupon_image_tag`를 바꿔 배포하기 전까지 기존 이미지를 쓴다.

### 태그를 커밋 해시로 붙이는 이유

- **불변(immutable)**: `latest`나 `v1`은 새로 push하면 다른 이미지를 가리키게 된다. 같은 태그로 배포했는데 노드마다 다른 이미지가 돌 수 있다
  (노드에 옛 `latest`가 캐시되어 있으면 그대로 쓴다). 커밋 해시는 한 번 정해지면 다른 내용을 가리킬 수 없다.
- **추적**: 클러스터에서 `kubectl get deploy coupon -o jsonpath='{..image}'`만 보면 정확히 어느 커밋이 떠 있는지 안다 → `git show <해시>`.
- **되돌리기**: 문제가 생기면 이전 커밋 해시로 `coupon.yml`을 다시 실행하면 된다. "그 시점의 latest가 뭐였지?"를 찾을 필요가 없다.
- **배포 기록**: 태그가 바뀌어야 Deployment 정의가 바뀌고 롤링 업데이트가 일어난다. `latest`면 매니페스트가 그대로라 쿠버네티스가 바뀐 줄 모른다.
- 40자 전체를 쓴 이유: 짧은 해시(7자)는 저장소가 커지면 겹칠 수 있다. 사람이 볼 때는 앞 7자만 봐도 된다.

## 2. 배포 설계 (`ansible/roles/coupon`)

### Deployment인 이유

쿠폰 서버는 상태를 MySQL·Redis·Kafka에 두고 자신은 상태가 없다. 어느 파드가 요청을 받아도 같고, 이름이나 저장소가 고정될 필요가 없다 → Deployment.
(MySQL·Redis·Kafka는 자기 데이터 폴더가 있어 StatefulSet)

### 설정과 비밀

- ConfigMap `coupon-config`: `SPRING_PROFILES_ACTIVE=prod`, Redis·Kafka 주소, `KAFKA_REPLICATION_FACTOR=1`, Swagger 켜기, 커넥션 풀 크기, `JAVA_TOOL_OPTIONS`
  - Spring은 환경변수 이름을 설정 키로 바꿔 읽는다(relaxed binding): `SPRINGDOC_SWAGGER_UI_ENABLED` → `springdoc.swagger-ui.enabled`. 그래서 코드·이미지를 고치지 않고 prod 프로필의 값만 덮어쓴다.
  - Swagger: prod 프로필은 끄지만 학습용 클러스터라 켰다. 실제 운영이라면 끄거나 인증 뒤에 둔다.
- Secret: 3단계의 `mysql-coupon`(host, database, username, password)과 4단계 `redis`(password)를 env로 연결. 값은 매니페스트에 없다.
- ConfigMap 내용의 해시를 파드 어노테이션에 넣어, 설정만 바꿔도 롤링 업데이트가 일어난다.

### 무중단을 위한 설정

- `replicas: 2` + `topologySpreadConstraints`(노드별로 나눔, `ScheduleAnyway`): worker1, worker2에 1대씩. 노드 하나가 죽어도 1대는 남는다.
- `RollingUpdate maxSurge 1, maxUnavailable 0`: 새 파드가 Ready가 된 뒤 옛 파드를 내린다 → 배포 중에도 항상 2대가 받는다.
- `preStop: sleep 10초`: 종료 신호를 보내기 전에 기다린다. 그 사이 Service와 Traefik이 이 파드를 목록에서 뺀다. 없으면 이미 종료 중인 파드로 요청이 가서 502가 난다.
- `server.shutdown: graceful`(prod 프로필): 처리 중인 요청은 끝내고 종료. `terminationGracePeriodSeconds: 45` = preStop 10 + graceful 최대 30 + 여유.
- `PodDisruptionBudget minAvailable 1`: `kubectl drain` 같은 점검 작업이 2대를 한꺼번에 내리지 못한다.
- `enableServiceLinks: false`: docs/redis-kafka.md의 함정 참고.

### Probe (Actuator, 관리 포트 8081)

- **startupProbe** `/actuator/health/liveness`, 5초 × 36번(최대 3분): 스프링 시작(실측 6초, CPU가 몰리면 더 걸림)이 끝날 때까지 다른 검사를 미룬다.
- **livenessProbe** `/actuator/health/liveness`: 앱 자체가 살아 있나. DB나 Redis는 보지 않는다.
  DB가 죽었다고 쿠폰 서버를 재시작해 봐야 DB가 살아나지 않고, 두 대가 동시에 재시작을 반복하며 상황만 나빠진다.
- **readinessProbe** `/actuator/health/readiness`: 요청을 받을 준비가 됐나. 시작 중이거나 종료(graceful shutdown) 중이면 실패 → Service에서 빠진다.
- 관리 포트는 Service에 없다: 맥에서 `http://<노드IP>/actuator/health`는 404. 지표·상태는 클러스터 안에서만 본다.

### 자원과 JVM

- requests = limits = 메모리 640Mi, CPU request 200m, CPU limit 없음 (JVM 시작 때 CPU를 많이 쓴다. limit이 있으면 시작이 몇 배 느려진다)
- 메모리를 requests = limits로 두는 이유: JVM은 시작할 때 힙 상한을 정한다. 노드가 붐빌 때 약속보다 적게 받으면 OOMKilled가 난다.
- `JAVA_TOOL_OPTIONS`:
  - `-XX:MaxRAMPercentage=40` → 힙 최대 256MB (640Mi의 40%). 이미지 기본값 75%를 덮어쓴다
  - `-XX:MaxMetaspaceSize=192m`, `-Xss512k`, `-XX:+ExitOnOutOfMemoryError`, `-Duser.timezone=Asia/Seoul`
  - GC: 메모리가 작고(1792MB 미만) JVM이 스스로 SerialGC를 고른다 (`UseSerialGC=true` 확인). 작은 힙에서는 G1보다 메모리를 덜 쓴다
- **처음에 512Mi로 정했다가 640Mi로 올렸다** (아래 "겪은 문제")

## 3. 검증 기록 (2026-10-20)

### 배포

- `ansible-playbook coupon.yml`: 23초 만에 2대 Ready, worker1·worker2에 1대씩. 스프링 시작 6.2초
- prod 프로필이 `schema.sql`로 `coupon`, `coupon_issue` 테이블을 만들고, 앱이 Kafka 토픽 `coupon-issue`(파티션 3, 복제본 1)와 DLT를 만들었다
- `site.yml`, `mysql.yml`, `redis.yml`, `kafka.yml`, `coupon.yml` 다시 실행: 모두 changed=0

### Swagger와 API (맥에서 `http://192.168.252.2`)

- `/swagger-ui.html` → 302 → `/swagger-ui/index.html` 200, `/v3/api-docs` 200 (API 4개 경로)
- 쿠폰 생성(수량 5) → 201, `Location: /coupons/1`
- 7명 발급: 5명 202, 6·7번째 409 `COUPON_SOLD_OUT`, 같은 사람 다시 409 `COUPON_ALREADY_ISSUED`
- MySQL `coupon_issue`에 5건 (발급 시각 KST). 컨슈머 그룹 `coupon-issue-saver` lag 0, 파티션 3개를 두 파드가 나눠 처리

### 파드 삭제 중 발급

- 수량 10만 쿠폰에 맥에서 40초 동안 4개 연결로 계속 발급, 10초째에 파드 하나 삭제
- **10,856건 전부 202, 실패 0건** (초당 약 270건). 새 파드는 약 20초 뒤 Ready
- MySQL 10,856건 (user_id 1~10,856 빠짐·중복 없음) = Redis 카운터 10,856 = Redis 발급 목록 10,856명, Kafka lag 0, ERROR 로그 0

### 배포(롤링 업데이트) 중 발급

- 1차 (메모리 512→640 변경 배포): 32,540건 중 **4건 `IncompleteRead`** (응답을 받다가 연결이 끊김). 나머지는 정상
  - DB를 보니 4건도 서버에서는 발급·저장됐다 (그 쿠폰의 user_id 1~32,540 전부 저장). 클라이언트가 다시 요청하면 409(이미 발급)라 중복 발급은 없다
  - 원인은 확정하지 못했다. 옛 파드 종료 시점의 Traefik ↔ Tomcat 연결 정리 경합으로 추정. 2차·3차에서는 재현되지 않았다 → Traefik 접근 로그를 켜고 다시 볼 과제로 남김
- 2차 (`rollout restart`): **27,558건 전부 202**, 이때 새 파드 하나가 한 번 재시작 → 아래 "겪은 문제 2"
- 3차 (연결 상한 수정 후 설정 변경 배포, 39초): **30,833건 전부 202, 재시작 0회**
  - 직후 DB는 30,731건 → 15초 뒤 30,833건. 파드가 바뀌며 Kafka 컨슈머 그룹이 파티션을 다시 나누는(리밸런스) 동안 저장이 잠깐 멈춘 것. 잃은 메시지 없음(lag 0, DLT 0)
  - 발급(202)과 저장이 분리된 구조라, 배포 중에는 "발급됐지만 아직 DB에 없는" 시간이 10~20초 생길 수 있다

### 메모리 (부하 직후)

- 쿠폰 서버: 423~494Mi / 640Mi (66~77%)
  - JVM 내역(512Mi 때): 힙 확보 144MB(사용 63), 힙 밖 211MB(Metaspace 145, 코드 캐시 47, 클래스 19), 스레드 108개
- Kafka 423Mi / 768Mi, MySQL 187Mi / 768Mi, Redis 15Mi / 192Mi (1만 명 발급 기록이 약 3MB)
- 노드: worker1 used 1184MB(available 2716), worker2 used 1368MB(available 2533), cp1 used 916MB
- 계획과 비교는 [memory-plan.md](memory-plan.md)

## 겪은 문제

### 1. 512Mi로는 모자랐다

- 1만 건 부하 뒤 421~447Mi (limit의 87%). Actuator 지표로 나눠 보니 힙 밖이 211MB였고, Metaspace 145MB가 상한 160m에 거의 닿아 있었다.
- 힙이 최대(256MB)까지 크면 256 + 211 + 스레드 등 85 ≈ 552Mi → 512Mi를 넘어 OOMKilled 위험.
- limit 640Mi, `MaxRAMPercentage=40`(힙은 256MB 그대로), Metaspace 상한 192m로 바꿨다. 다른 Spring 서비스의 예산도 448 → 512MB로 올렸다.

### 2. 배포 중 3번째 파드가 DB 연결 상한에 걸림

- `rollout restart` 중 새 파드가 `User 'coupon' has exceeded the 'max_user_connections' resource (current value: 25)`로 시작에 실패하고, 옛 파드가 내려간 뒤 재시작해서 떴다.
- 원인: 3단계에서 계정 상한을 "커넥션 풀 10 × 2대 + 여유 = 25"로 잡았는데, 롤링 업데이트 중에는 **maxSurge 1 때문에 잠깐 3대**(30개)가 된다.
- 해결: coupon 계정 상한 35 = (replicas 2 + maxSurge 1) × 풀 10 + 여유 5 (`mysql_service_max_connections_overrides`). 풀 크기 10은 ConfigMap에 명시해 두 값이 짝이라는 걸 남겼다.
  전체 `max_connections` 120 안에 들어간다 (35 + 25 × 3 + 백업 2 = 112).

### 3. zsh에서 셸 변수 이름 함정 (검증 스크립트)

- `for path in ...`: zsh에서 `path`는 `PATH`와 연결된 특수 변수라 반복문이 PATH를 덮어써 `curl: command not found`.
- `$CID:count`: zsh가 `:c`를 변수 수정자로 해석. `${CID}:count`로 감싼다.
