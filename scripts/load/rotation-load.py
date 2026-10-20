# 서명 키 교체 중 부하 (클러스터 안 일회용 파드에서 Traefik을 거쳐 실행). docs/key-rotation.md
#   kubectl -n apps run rotload --restart=Never --image=python:3.13-alpine \
#     --overrides='{"spec":{"enableServiceLinks":false}}' -i -- python - <관리자 토큰> <분> < scripts/load/rotation-load.py
# 시험 데이터 규칙(docs/test-data.md): 계정 rot-<번호>@loadtest.invalid, 쿠폰 [LOAD] 키 교체 <번호>
# 하는 일: 사용자 50명이 로그인 → 각자 토큰으로 발급(쿠폰 서버가 JWKS 공개키로 검증)과 /auth/me(인증 서버가 검증)를 계속 부른다.
#   토큰은 REFRESH_SEC마다 /auth/refresh로 새로 받는다 → 활성 키를 바꾼 뒤에는 새 키로 서명된 토큰이 섞여 들어온다
# 1분마다 응답 코드 수를 찍는다. 401이 하나라도 있으면 키 교체 절차에 빈틈이 있다는 뜻
# Gateway 요청 제한을 지킨다: 로그인 IP당 분당 60회(429면 기다렸다 재시도), 발급 토큰당 초당 5회(전체 초당 RATE회로 제한)
import http.client, json, sys, time, threading, collections, datetime, random

HOST = "traefik.kube-system.svc.cluster.local"
admin, minutes = sys.argv[1], float(sys.argv[2])
USERS, COUPONS, RATE, THREADS, REFRESH_SEC = 50, 20, 80, 6, 300
tag = str(int(time.time()))


def call(conn, method, path, body=None, token=None):
    h = {"Content-Type": "application/json"}
    if token:
        h["Authorization"] = "Bearer " + token
    conn.request(method, path, json.dumps(body) if body is not None else None, h)
    r = conn.getresponse()
    return r.status, r.read(), r.getheader("Retry-After")


def paced(conn, method, path, body, ok):
    while True:
        s, d, retry = call(conn, method, path, body)
        if s == 429:
            time.sleep(float(retry or 1))
            continue
        assert s in ok, (path, s, d[:200])
        return s, d


c = http.client.HTTPConnection(HOST, 80, timeout=30)
emails = [f"rot{tag}-{i}@loadtest.invalid" for i in range(USERS)]
for e in emails:
    paced(c, "POST", "/auth/signup", {"email": e, "password": "Passw0rd!", "name": "키교체"}, (201,))
tokens, refresh = [], []
for e in emails:
    _, d = paced(c, "POST", "/auth/login", {"email": e, "password": "Passw0rd!"}, (200,))
    d = json.loads(d)
    tokens.append(d["accessToken"])
    refresh.append(d["refreshToken"])
now = datetime.datetime.utcnow() + datetime.timedelta(hours=9)
coupons = []
for i in range(COUPONS):
    s, d, _ = call(c, "POST", "/coupons", {"name": f"[LOAD] 키 교체 {i}", "totalQuantity": 100000,
        "issueStartAt": (now - datetime.timedelta(minutes=2)).strftime("%Y-%m-%dT%H:%M:%S"),
        "issueEndAt": (now + datetime.timedelta(days=1)).strftime("%Y-%m-%dT%H:%M:%S")}, admin)
    assert s == 201, (s, d)
    coupons.append(json.loads(d)["id"])
print(f"준비 끝 {datetime.datetime.now().strftime('%H:%M:%S')} (UTC): 사용자 {USERS}, 쿠폰 {COUPONS}", flush=True)

lock = threading.Lock()
minute = collections.Counter()
total = collections.Counter()
errors = []
kids = collections.Counter()
end = time.time() + minutes * 60


def kid_of(token):
    import base64
    h = token.split(".")[0]
    return json.loads(base64.urlsafe_b64decode(h + "=" * (-len(h) % 4)))["kid"]


def record(key, detail=None):
    with lock:
        minute[key] += 1
        total[key] += 1
        if detail and len(errors) < 30:
            errors.append((datetime.datetime.now().strftime("%H:%M:%S"), key, detail))


def refresher():
    conn = http.client.HTTPConnection(HOST, 80, timeout=30)
    while time.time() < end:
        time.sleep(REFRESH_SEC)
        for i in range(USERS):
            try:
                while True:
                    s, d, retry = call(conn, "POST", "/auth/refresh", {"refreshToken": refresh[i]})
                    if s != 429:
                        break
                    time.sleep(float(retry or 1))
            except Exception as e:
                conn = http.client.HTTPConnection(HOST, 80, timeout=30)
                record(f"refresh {type(e).__name__}", str(e)[:100])
                continue
            if s == 200:
                d = json.loads(d)
                with lock:
                    tokens[i], refresh[i] = d["accessToken"], d["refreshToken"]
                    kids[kid_of(d["accessToken"])] += 1
            record(f"refresh {s}", None if s == 200 else d[:120].decode(errors="replace"))


def worker():
    conn = None
    interval = THREADS / RATE
    while time.time() < end:
        t0 = time.time()
        u = random.randrange(USERS)
        with lock:
            tok = tokens[u]
        me = random.random() < 0.1   # /auth/me는 IP당 초당 20회 제한(auth-per-ip)을 재발급과 나눠 쓴다
        try:
            if conn is None:
                conn = http.client.HTTPConnection(HOST, 80, timeout=30)
            if me:
                s, d, _ = call(conn, "GET", "/auth/me", None, tok)
                ok = s == 200
            else:
                s, d, _ = call(conn, "POST", f"/coupons/{random.choice(coupons)}/issue", None, tok)
                ok = s in (202, 409)
            record(f"{'me' if me else 'issue'} {s}", None if ok else f"kid={kid_of(tok)} " + d[:100].decode(errors="replace"))
        except Exception as e:
            conn = None
            record(f"{'me' if me else 'issue'} {type(e).__name__}", str(e)[:100])
        time.sleep(max(0, interval - (time.time() - t0)))


def reporter():
    while time.time() < end:
        time.sleep(60)
        with lock:
            snap = dict(minute)
            minute.clear()
            k = dict(kids)
        print(datetime.datetime.now().strftime("%H:%M:%S"), json.dumps(snap), "토큰 kid", json.dumps(k), flush=True)


ts = [threading.Thread(target=worker) for _ in range(THREADS)] + [threading.Thread(target=refresher), threading.Thread(target=reporter)]
for t in ts:
    t.start()
for t in ts:
    t.join()
bad = sum(v for k, v in total.items() if " 401" in k)
print(json.dumps({"total": total, "401": bad, "errors": errors, "coupons": [coupons[0], coupons[-1]]}, ensure_ascii=False))
