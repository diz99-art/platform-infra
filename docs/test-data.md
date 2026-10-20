# 시험 데이터 규칙과 정리

부하 시험·검증이 남긴 데이터가 실제 사용자 데이터와 섞이지 않게 하는 규칙. 8단계에서 만들었다.

## 왜 필요했나

- 7단계 전까지 발급 API는 요청 본문의 `userId`를 그대로 믿었다. 부하 시험은 userId 1, 2, 3 … 987654321 같은 **임의 숫자**로 발급했다
- 7단계에서 인증 서버가 생기자 계정 id도 1, 2, 3 …으로 붙었다 → 예전 시험의 발급 기록이 **같은 id를 받은 실제 계정의 "내 발급 내역"**에 보였다
  (관리자 계정 id 1의 내역에 시험 발급 4건, 계정 id와 겹치는 인증 전 기록 2,812건)
- 7단계 부하 시험의 계정(`load…@example.com`)과 쿠폰(`부하0` …)도 이름만 보고는 시험용인지 알기 어려웠다

## 규칙 (앞으로 모든 부하 시험)

- **시험 계정**: 이메일을 `@loadtest.invalid`로 끝낸다 (예: `k6-1@loadtest.invalid`)
  - `.invalid`는 RFC 2606이 "실제로 쓰일 수 없다"고 예약한 최상위 도메인이다 → 실제 사용자 이메일과 절대 겹치지 않는다
- **시험 쿠폰**: 이름을 `[LOAD]`로 시작한다 (예: `[LOAD] k6 1`). 만들 때는 관리자 토큰을 쓴다
- 시험 계정은 시험 쿠폰만 발급받는다. 실제 쿠폰에 부하를 걸지 않는다
- 시험이 끝나면 `scripts/cleanup-test-data.sh`로 지운다. 표시(marker)로만 고르므로 실제 데이터는 건드리지 않는다
- 이 규칙을 따르는 스크립트: coupon-system `bench/issue-auth.js`(k6), platform-infra `scripts/load/rotation-load.py`
- 예외: coupon-system의 `bench/issue.js` 등 bench 프로필 비교 API는 로컬 docker compose 전용이다(운영 prod에는 그 API가 없다)

## 정리 스크립트 `scripts/cleanup-test-data.sh`

```bash
kubectl -n data create job --from=cronjob/mysql-backup before-cleanup   # 먼저 백업
scripts/cleanup-test-data.sh -n     # 지울 개수만 보기
scripts/cleanup-test-data.sh        # 확인 후 지우기 (-y: 묻지 않음)
```

지우는 것:

- MySQL `coupon`: `[LOAD]` 쿠폰, 그 쿠폰의 발급 기록, 시험 계정의 발급 기록(어느 쿠폰이든). 5만 줄씩 나눠 지운다 (트랜잭션 하나가 커지지 않게)
- MySQL `auth`: 시험 계정 (역할 USER만. ADMIN은 이메일이 맞아도 지우지 않는다)
- Redis: 시험 쿠폰의 판정 키(`coupon:{id}:users|count|info|not-found`), 다른 쿠폰의 발급자 집합에서 시험 계정 id,
  시험 계정의 리프레시 토큰(`auth:refresh:*`), 로그인 실패·잠금 기록(`auth:login:*`)
  - 교체된 리프레시 토큰(`auth:refresh:used:{해시}`)은 값(사용자 id)으로만 찾을 수 있어 Redis 안에서 Lua로 훑는다
- 지운 계정의 id는 다시 쓰이지 않는다 (MySQL AUTO_INCREMENT는 재시작해도 이어진다) → 나중에 가입한 사람이 지운 기록과 겹치지 않는다
- 시험 직후에는 Kafka에 남은 발급 이벤트가 DB에 다 들어간 뒤(몇 초) 실행한다

## 8단계의 한 번 정리 (예전 시험 데이터)

기준:

1. **인증 전(2026-10-20 17:45:55 이전) 발급 기록은 모두 시험 데이터**: user_id가 토큰이 아니라 시험 스크립트가 고른 숫자다. 계정과 겹치든 아니든 믿을 수 없다 → 쿠폰 1~6과 그 발급 313,154건
2. **7단계 검증·부하 시험 데이터**: 쿠폰 7~1007(`인증 연동 기념`, `부하N`), 계정 id 2~702(`e2e-…`, `load…@example.com`)와 그 발급
3. 남기는 것: 관리자 계정(id 1). 관리자의 시험 발급 4건(쿠폰 1~4)은 1번에 들어가 지워진다

방법: 위 데이터에 표시를 붙이고(쿠폰 이름 앞에 `[LOAD] `, 계정 이메일을 `@loadtest.invalid`로) 같은 정리 스크립트로 지운다.
따로 만든 SQL 대신 앞으로 쓸 스크립트를 실제 데이터로 한 번 시험하는 셈이다.

```bash
# 표시 붙이기 (MySQL root, 파드 안 환경변수 사용)
echo "UPDATE coupon.coupon SET name = CONCAT('[LOAD] ', name) WHERE name NOT LIKE '[LOAD]%';
      UPDATE auth.users SET email = CONCAT(SUBSTRING_INDEX(email, '@', 1), '@loadtest.invalid')
      WHERE role = 'USER' AND email LIKE '%@example.com';" \
  | kubectl -n data exec -i mysql-0 -- sh -c 'MYSQL_PWD="$MYSQL_ROOT_PASSWORD" exec mysql -uroot --default-character-set=utf8mb4'
scripts/cleanup-test-data.sh -n && scripts/cleanup-test-data.sh
```

백업 (지우기 전, 2026-10-20 22:14):

- MySQL: `~/platform-backups/mysql/20261020-221440/` (coupon 3.2MB, auth 41KB). 복구: `scripts/mysql-restore.sh coupon <폴더>`
- Redis: `~/platform-backups/redis/20261020-221452/dump.rdb` (`BGSAVE` 스냅숏, 키 10,643개)
  - 복구는 Redis를 멈추고 `/data`의 AOF를 치운 뒤 이 파일을 넣고 띄운다 (AOF가 켜져 있으면 AOF가 우선이다)
