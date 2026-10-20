# Gateway (Traefik 미들웨어)

8단계. 별도 Gateway 서버(Spring Cloud Gateway)를 만들지 않고, 이미 모든 요청이 지나가는 **Traefik**에 Gateway 기능을 넣었다.

```
맥 ─▶ 192.168.252.2:80 (cp1, ServiceLB, externalTrafficPolicy: Local → 클라이언트 IP 그대로)
        │
        ▼ Traefik (kube-system, 1대)  ── 정적 설정: Ansible traefik 역할 (헤더 32KiB, 요청 ID 플러그인, 메모리)
        │   IngressRoute gateway + Middleware ── Git k8s/apps/gateway → ArgoCD
        │
        │  request-id → security-headers → [요청 제한] → body-limit
        ├─ POST /auth/login    (login-per-ip   IP당 분당 60, 몰림 20)   ─▶ auth
        ├─ POST /auth/signup   (signup-per-ip  IP당 분당 60, 몰림 20)   ─▶ auth
        ├─ /auth, /auth/...    (auth-per-ip    IP당 초당 20, 몰림 50)   ─▶ auth
        ├─ POST /coupons/{id}/issue (issue-per-token 토큰당 초당 5, 몰림 10) ─▶ coupon
        ├─ /coupons, /coupons/..., /users/(me|{id})/coupons             ─▶ coupon
        ├─ /swagger-ui..., /v3/api-docs... (쿠폰 서버 Swagger)          ─▶ coupon
        └─ 그 밖 (/, /actuator, /bench, /authx …)                       ─▶ 404 (앱까지 가지 않는다)
```

## 왜 Spring Cloud Gateway를 따로 두지 않았나

- **메모리**: Spring Cloud Gateway도 JVM 서비스다. 인증 서버 실측(RSS 약 350MiB, limit 512Mi)과 비슷하게 잡으면 2대에 약 1GiB인데,
  워커의 15% 여유를 지키며 남은 예산은 472MiB뿐이었다 (docs/memory-plan.md). Traefik에 넣으면 추가 비용은 Traefik 메모리 약 +25MiB(cp1)
- **이미 있는 길목**: 모든 요청이 이미 Traefik을 지난다. Gateway 서버를 두면 Traefik → Gateway → 앱으로 한 단계(네트워크 왕복, 장애 지점)가 늘어난다
- **필요한 기능이 Traefik에 있다**: 경로 라우팅, 요청 제한(rateLimit), 보안 헤더(headers), 본문 크기 제한(buffering), 헤더 크기 제한. 없는 것(요청 ID)은 작은 플러그인으로
- **토큰 검증은 각 서비스가 한다**: 쿠폰 서버가 JWKS 공개키로 직접 검증한다 (7단계). Gateway에서 한 번 더 검증할 필요가 없다. 서비스가 스스로 검증하는 편이 내부 통신을 믿지 않는다는 점(zero trust)에서도 낫다

### Gateway 서버가 필요해지는 조건

- **요청 내용을 보고 바꿔야 할 때**: 여러 서비스 응답을 합치기(API 조합, BFF), 요청·응답 본문 변환, 버전별 응답 바꾸기
- **토큰 내용 기준의 정책**: 사용자 id(`sub`)·역할·요금제별 요청 제한, 토큰 교환(외부 토큰 → 내부 토큰). Traefik은 헤더 값 전체를 키로 쓸 뿐 JWT를 풀지 않는다
- **Traefik이 여러 대가 될 때의 요청 제한**: 지금 요청 제한 카운터는 Traefik 메모리에 있다. 2대가 되면 각자 센다(실제 한도가 2배). Traefik의 `rateLimit.redis`(공유 카운터)로 풀 수 있지만, 정책이 복잡해지면 Gateway 서버가 낫다
- **서킷 브레이커·재시도·폴백을 서비스별로 세밀하게**, 사용량 집계(과금), 외부 공개 API 키 관리
- 그때도 Traefik은 앞단(TLS, 기본 제한)에 남고 Gateway 서버는 그 뒤에 둔다

## 미들웨어

### 요청 제한 (rateLimit)

- 동작: 토큰 버킷. `average`만큼 계속 채워지고 `burst`만큼 담긴다. 비면 429 + `Retry-After`(초) + `X-Retry-In`
- **로그인·가입은 IP 기준**: 무차별 대입(brute force)·크리덴셜 스터핑(유출된 아이디·비밀번호 목록을 여러 계정에 대입) 방지
  - 인증 서버의 계정별 잠금(15분 안에 5번 → 5분)은 **한 계정**을, IP 제한은 **한 IP가 여러 계정**을 훑는 공격을 늦춘다. 둘이 서로 보완한다
  - 분당 60회: 사람은 넘을 일이 없다. 공격자는 IP 하나로 시간당 3,600번 → 계정당 잠금까지 더하면 사실상 막힌다
  - 한계: 같은 공인 IP(회사·학교 NAT) 뒤의 사람들이 한도를 나눠 쓴다. IP를 여러 개 가진 공격자(봇넷)는 못 막는다 → CAPTCHA, 장치 지문 등이 다음 단계
- **발급은 토큰 기준** (`requestHeaderName: Authorization`): NAT 뒤의 사용자끼리 영향을 주지 않는다 (IP 기준이면 회사 하나가 한도를 나눠 쓴다)
  - 토큰을 새로 받으면 새 버킷이다 → 그래도 토큰 받기(로그인)가 IP당 분당 60회라 무한히 늘릴 수 없다
  - 사용자 id(`sub`) 기준이 더 정확하지만, Traefik에서 JWT를 서명 검증 없이 풀어 쓰면 남의 id를 넣어 그 사람의 한도를 소진시킬 수 있다 → 토큰 문자열 전체를 키로 쓴다(위조 토큰은 자기 버킷만 쓰고 401)
- **IP는 TCP 연결의 주소**(`ipStrategy: {}`)만 믿는다. `X-Forwarded-For`는 클라이언트가 마음대로 넣을 수 있다 (Traefik 앞에 다른 프록시가 생기면 `depth`로 그 프록시만 믿게 바꾼다)

### 클라이언트 IP 보존 (`externalTrafficPolicy: Local`)

- 처음 시험에서 맥의 요청이 Traefik에 `10.42.0.1`로 보였다: ServiceLB(klipper-lb)가 다른 노드로도 넘길 수 있게 출발지 주소를 바꾸기(SNAT) 때문
- 그대로면 **모든 외부 사용자가 한 IP** → IP 기준 제한이 모두를 한 버킷에 넣는다 (한 명이 로그인을 막아 버릴 수 있다)
- `Local`: Traefik 파드가 있는 노드(cp1)로 온 요청만 받고 출발지 IP를 바꾸지 않는다 → 맥이 `192.168.252.1`로 보인다
- 대가: worker1·2의 IP(:80)로는 더 이상 접속되지 않는다 (지금은 cp1 주소만 쓴다). Traefik이 다른 노드로 옮기면 접속 주소도 바뀐다

### 보안 헤더 (headers)

- `X-Frame-Options: DENY`, `Content-Security-Policy: frame-ancestors 'none'`: 다른 사이트가 iframe으로 감싸 클릭을 가로채는 공격(clickjacking) 방지
- `X-Content-Type-Options: nosniff`: 브라우저가 JSON을 스크립트로 추측해 실행하지 않게
- `Referrer-Policy: no-referrer`: 다른 사이트로 이동할 때 주소를 보내지 않게
- `Permissions-Policy`: 카메라·마이크·위치 사용 금지
- `X-Powered-By` 제거. HSTS는 HTTPS 단계에서 (HTTP에서는 의미 없음)
- Spring Security도 일부(nosniff, X-Frame-Options)를 넣지만 Gateway에서 넣으면 **모든 서비스에 같은 정책**이 걸린다 (새 서비스가 빠뜨려도)

### 요청 ID (로컬 플러그인 `requestid`)

- Traefik 3.7에는 요청 ID를 만드는 미들웨어가 없다 → Go로 60줄짜리 플러그인을 썼다 (`ansible/roles/traefik/files/requestid/requestid.go`)
  - Traefik은 플러그인을 컴파일하지 않고 **Yaegi**(Go 인터프리터)로 소스를 그대로 실행한다
  - 차트의 `experimental.localPlugins.<이름>.type: inlinePlugin`: 소스를 ConfigMap으로 만들어 마운트한다. 인터넷(플러그인 카탈로그)에서 받지 않는다
- 동작: `X-Request-Id`가 형식(영문·숫자·`-_.`, 8~64자)에 맞으면 그대로, 아니면 새 UUID. 백엔드 요청 헤더와 응답 헤더에 같은 값
- **로그 연결**: Traefik 접근 로그에 `request_X-Request-Id`만 남기고(다른 요청 헤더는 계속 버림), 앱은 `RequestIdFilter`가 MDC에 넣어
  로그 줄마다 `[요청 ID]`를 붙인다 (`logging.pattern.correlation`). 예:
  ```
  Traefik  trace-…-login-5 192.168.252.1 /auth/login 429
  auth     2026-10-20T22:38:04.511+09:00 [trace-…-login-5] LoginAttemptService : 로그인 잠금 v***@loadtest.invalid (5번 실패, 300초)
  ```
- 인증 서버는 로그인 실패·잠금을 로그로 남긴다 (이메일은 `v***@도메인`으로 가림)
- 별칭 헤더 삭제(`aliasHeadersStrategy=delete`): `X_Request_Id`처럼 다른 헤더로 읽힐 수 있는 이름을 지운다 (Traefik이 정한 헤더를 흉내 내지 못하게)

### 크기 제한

- 본문: `buffering.maxRequestBodyBytes` 1MiB → 413. 본문을 다 받은 뒤 앱으로 보내므로, 아주 느리게 보내는 클라이언트(slowloris)가 앱 스레드를 오래 잡지 못한다
- 헤더: 정적 설정 `entryPoints.web.http.maxHeaderBytes=32768` (기본 1MiB) → 431

### 경로 정리

- 라우팅을 `k8s/apps/gateway/routes.yaml` 한곳에 모았다. 서비스별 Ingress(`/`를 통째로 쿠폰 서버에 주던 것)는 지웠다
- 등록하지 않은 주소는 Traefik이 404 → 앱의 숨은 주소(`/bench`, 관리용)가 우연히 밖에 열리지 않는다 (actuator는 원래 8081 포트라 밖에 없다)
- `PathPrefix(/auth)`는 `/authx`도 맞으므로 `Path(/auth) || PathPrefix(/auth/)`로 쓴다
- `priority`: 숫자가 큰 규칙부터 본다. `POST /auth/login`(100)이 `/auth/...`(50)보다 먼저 맞아야 로그인 제한이 걸린다

## 검증 (2026-10-20)

- 라우팅: `/` · `/authx` · `/actuator/health` · `/users/abc/coupons` → 404, `/coupons/7` 200, JWKS 200, 두 Swagger 302
- 보안 헤더 6개, 2MB 본문 413, 40KB 헤더 431
- 요청 ID: 없으면 UUID, `my-trace-12345`는 그대로, `bad id<script>`는 새 UUID. 접근 로그·응답·앱 로그에 같은 값
- **발급 제한**: 토큰 A로 30번 동시에 → 11번 통과(202 1, 409 10), 19번 429. 같은 때 토큰 B는 6번 모두 통과(429 0)
- **로그인 제한**: 맥 IP에서 틀린 비밀번호로 40번 → 21번 401, 19번 429. 같은 때 클러스터 안 다른 IP의 정상 사용자 로그인 5/5 성공
- **k6 `issue-auth.js`** (맥, 사용자 100명 × 쿠폰 200장, 토큰당 초당 4회): 발급 20,000건 모두 202, failed 0, limited 0,
  p95 38ms, p99 196ms, 초당 231건. setup의 가입·로그인 94건이 IP 제한에 걸려 `Retry-After` 뒤 재시도됐다 (정상 동작)
- Traefik 메모리: RSS 최대 59MiB (플러그인·버퍼링 전 최대 34MiB) → limit 128Mi(46%). 차트가 `GOMEMLIMIT=115MiB`(90%)를 넣어 Go GC가 limit 전에 회수한다

## 한계와 다음 후보

- 429 본문이 `Too Many Requests` 평문이다 (공통 에러 JSON이 아님). `errors` 미들웨어로 JSON 페이지를 돌려줄 수 있다
- 요청 제한 카운터가 Traefik 메모리에 있어 Traefik이 재시작하면 초기화되고, 여러 대면 각자 센다 (`rateLimit.redis`)
- Traefik이 1대(cp1)뿐이다: 설정을 바꾸면 몇 초 끊긴다
- HTTPS(TLS)가 없다: 토큰이 평문으로 오간다. 학습용 내부망이라 미뤘다 (HSTS도 그때)
