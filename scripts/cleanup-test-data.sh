#!/usr/bin/env bash
# 부하 시험이 남긴 시험 데이터를 지운다. 기준은 표시(marker)뿐이다 (docs/test-data.md):
#   시험 계정 = 이메일이 @loadtest.invalid 로 끝남   (.invalid는 실제로 쓸 수 없는 예약 도메인)
#   시험 쿠폰 = 이름이 [LOAD] 로 시작
# 지우는 것: 시험 쿠폰과 그 발급 기록, 시험 계정과 그 발급 기록(어느 쿠폰이든),
#            Redis의 쿠폰 판정 키(coupon:{id}:*)와 시험 계정의 리프레시 토큰·로그인 실패 기록
#   사용: scripts/cleanup-test-data.sh [-y]      (-n: 지울 개수만 보기)
# 먼저 백업: kubectl -n data create job --from=cronjob/mysql-backup <이름>
# 시험 직후라면 Kafka에 남은 발급 이벤트가 DB에 다 들어간 뒤(몇 초) 실행한다
set -euo pipefail

mode="${1:-}"
export KUBECONFIG="${KUBECONFIG:-$HOME/.kube/platform-infra.yaml}"
USER_WHERE="email LIKE '%@loadtest.invalid'"
COUPON_WHERE="name LIKE '[LOAD]%'"

sql() { kubectl -n data exec -i mysql-0 -- sh -c 'MYSQL_PWD="$MYSQL_ROOT_PASSWORD" exec mysql -uroot --default-character-set=utf8mb4 -N -B' 2>/dev/null; }
redis() { kubectl -n data exec -i redis-0 -- redis-cli "$@"; }

coupon_ids=$(echo "SELECT id FROM coupon.coupon WHERE $COUPON_WHERE" | sql | tr '\n' ' ')
user_ids=$(echo "SELECT id FROM auth.users WHERE $USER_WHERE AND role = 'USER'" | sql | tr '\n' ' ')
emails=$(echo "SELECT email FROM auth.users WHERE $USER_WHERE AND role = 'USER'" | sql | tr '\n' ' ')
csv() { local s; s=$(echo "$1" | xargs | tr ' ' ','); echo "${s:-0}"; }
issues=$(echo "SELECT COUNT(*) FROM coupon.coupon_issue WHERE coupon_id IN ($(csv "$coupon_ids")) OR user_id IN ($(csv "$user_ids"))" | sql)

echo "시험 쿠폰 $(echo $coupon_ids | wc -w | xargs)개, 시험 계정 $(echo $user_ids | wc -w | xargs)개, 발급 기록 ${issues}건"
[[ "$mode" == "-n" ]] && exit 0
if [[ "$mode" != "-y" ]]; then
  read -r -p "지울까요? [y/N] " a; [[ "$a" == "y" || "$a" == "Y" ]] || { echo "취소했습니다."; exit 0; }
fi

# 발급 기록은 많을 수 있어 5만 줄씩 지운다 (트랜잭션 하나가 너무 커지지 않게)
for where in "coupon_id IN ($(csv "$coupon_ids"))" "user_id IN ($(csv "$user_ids"))"; do
  while :; do
    n=$(echo "DELETE FROM coupon.coupon_issue WHERE $where LIMIT 50000; SELECT ROW_COUNT();" | sql)
    [[ "$n" -gt 0 ]] || break
  done
done
echo "DELETE FROM coupon.coupon WHERE $COUPON_WHERE; DELETE FROM auth.users WHERE $USER_WHERE AND role = 'USER';" | sql

# Redis: 쿠폰 판정 키 (발급자 집합, 발급 수, 쿠폰 정보, 없는 쿠폰 표시)
for id in $coupon_ids; do echo "UNLINK coupon:$id:users coupon:$id:count coupon:$id:info coupon:$id:not-found"; done | redis >/dev/null
# 시험 계정이 다른(실제) 쿠폰에서 받은 발급도 판정 집합에서 뺀다
real_coupons=$(redis --scan --pattern 'coupon:*:users' | sed -E 's/coupon:([0-9]+):users/\1/')
for c in $real_coupons; do for u in $user_ids; do echo "SREM coupon:$c:users $u"; done; done | redis >/dev/null
# 리프레시 토큰: 사용자별 목록 → 토큰 해시, 교체된 토큰(used)은 값(사용자 id)으로 찾는다
for u in $user_ids; do
  for h in $(redis smembers "auth:refresh:user:$u"); do echo "UNLINK auth:refresh:$h"; done
  echo "UNLINK auth:refresh:user:$u"
done | redis >/dev/null
# (Redis 안에서 Lua로 훑는다: 키를 꺼내 맥에서 비교하는 것보다 빠르고, 훑는 사이 키가 바뀌어도 짝이 어긋나지 않는다)
if [[ -n "${user_ids// /}" ]]; then
  redis eval "
    local ids = {} for _, v in ipairs(ARGV) do ids[v] = true end
    local cursor, n = '0', 0
    repeat
      local r = redis.call('SCAN', cursor, 'MATCH', 'auth:refresh:used:*', 'COUNT', 1000)
      cursor = r[1]
      for _, k in ipairs(r[2]) do
        if ids[redis.call('GET', k)] then redis.call('UNLINK', k) n = n + 1 end
      end
    until cursor == '0'
    return n" 0 $user_ids >/dev/null
fi
for e in $emails; do echo "UNLINK auth:login:fail:$e auth:login:lock:$e"; done | redis >/dev/null

echo "정리 끝. 남은 것: 쿠폰 $(echo 'SELECT COUNT(*) FROM coupon.coupon' | sql)개, 계정 $(echo 'SELECT COUNT(*) FROM auth.users' | sql)개, 발급 기록 $(echo 'SELECT COUNT(*) FROM coupon.coupon_issue' | sql)건"
