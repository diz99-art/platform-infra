# 6단계: 모니터링과 알림

## 구조

```
                         (30초마다 가져감 = scrape)
 kubelet cAdvisor ──────────┐  컨테이너 메모리·CPU (노드 3대)
 node-exporter (DaemonSet) ─┤  노드 메모리·CPU·디스크 (cp1 포함 3대)
 kube-state-metrics ────────┤  파드 재시작 수, 노드 Ready, Deployment 상태
 쿠폰 서버 :8081/actuator ──┤  JVM(힙·힙 밖·GC), HTTP, 쿠폰 커스텀 지표
 Traefik :9100 ─────────────┤  요청 수·응답 코드 (앞단)
 mysqld / redis / kafka ────┤  exporter 3개 (data 파드를 건드리지 않고 따로 띄움)
   exporter                 ▼
                    VictoriaMetrics (수집 + 저장 15일 + PromQL 조회)
                     │            │
                     ▼            ▼
                  Grafana       vmalert (30초마다 규칙 평가)
             /grafana/ 대시보드    │
                                  ▼
                            Alertmanager (묶기·중복 제거)  /alertmanager/
                                  │
                                  ▼
                              디스코드 웹훅
```

## 누가 무엇을 관리하나

- **ArgoCD (Git)**: 모니터링 구성요소 전부
  - `k8s/platform/monitoring/` (Kustomize): VictoriaMetrics, vmalert, Alertmanager, exporter 3개, 대시보드 ConfigMap, Ingress
    - `scrape.yml` 수집 대상, `alerts.yml` 알림 규칙, `dashboards/*.json` 대시보드 (`gen_dashboards.py`로 생성)
  - `k8s/argocd/apps/grafana.yaml`, `kube-state-metrics.yaml`, `node-exporter.yaml` (Helm 차트, 값은 Application 안에)
  - AppProject `platform`: platform 네임스페이스에만, ClusterRole·ClusterRoleBinding만 클러스터 범위 허용, **Secret 금지**
- **Ansible** (`ansible-playbook monitoring.yml`): Git에 둘 수 없는 것과 kube-system
  - Secret: `grafana-admin`, `alertmanager-config`(디스코드 웹훅), `mysql-exporter`, `redis-exporter` (값은 vault)
  - Traefik 설정(HelmChartConfig): 접근 로그(JSON), 지표 수집 어노테이션
  - MySQL `exporter` 계정 (`mysql.yml`): `PROCESS, REPLICATION CLIENT`와 `performance_schema` 읽기만. 서비스 DB는 못 읽는다

## 설계 결정

- **VictoriaMetrics 단일 실행 (Prometheus 대신)**: Prometheus와 같은 수집 설정·PromQL을 쓰면서 메모리·디스크를 덜 쓴다. 수집도 직접 해서 vmagent가 필요 없다. 실측 최대 115Mi (시계열 약 1만 개)
- **수집 간격 30초**, cAdvisor 지표는 쓰는 것 6개만 남김: 저장할 점이 줄어든다
- **exporter를 sidecar가 아니라 별도 Deployment로**: MySQL·Redis·Kafka를 재시작하지 않고, Ansible이 관리하는 data 네임스페이스도 건드리지 않는다
- **Grafana 대시보드는 파일(Git)**: sidecar 컨테이너(ConfigMap을 찾아다니는 보조 프로그램, 50~80MB) 없이 ConfigMap을 바로 마운트. 화면에서 고쳐도 저장되지 않는다(`allowUiUpdates: false`). 고치려면 `gen_dashboards.py` → JSON → push
- **Grafana 저장소 없음 (persistence off)**: 데이터 소스·대시보드를 다 파일로 넣으니 지킬 상태가 없다
- **Grafana 보기 전용 익명 접속**: 맥 안 사설망 학습용이라 대시보드는 로그인 없이 본다. 수정은 admin 로그인 (비밀번호는 vault의 `vault_grafana_admin_password`)
- **Grafana 차트는 grafana-community**: Grafana 공식 Helm 차트는 grafana-community 저장소로 옮겨갔다 (grafana 저장소의 마지막 버전은 Grafana 12.3)
- **kube-state-metrics는 필요한 객체만**: `secrets`, `configmaps`를 빼서 Secret 목록을 읽는 권한 자체가 없다
- **메모리 알림은 RSS 기준**: working set은 실행 파일을 읽어 둔 파일 캐시까지 센다. Grafana는 working set 305Mi 중 캐시가 100Mi라 working set 기준이면 늘 95%로 울린다. RSS(돌려받을 수 없는 메모리)는 211Mi = 66%

## 메모리 (6단계 실측)

- 모니터링 limit 합 912Mi (워커 기준), 실측 최대 합 약 420Mi: VictoriaMetrics 115, Grafana RSS 211(working set 305), vmalert·Alertmanager·exporter·kube-state-metrics·node-exporter 각 9~16
- 자세한 예산과 15% 목표 판단: [memory-plan.md](memory-plan.md)

## 알림 규칙 (`k8s/platform/monitoring/alerts.yml`)

- `ContainerMemoryHigh`: 컨테이너 RSS / limit > 85% 5분
- `NodeMemoryHigh`: 노드 사용 메모리 > 85% 5분
- `PodRestarted`: 최근 10분 안에 컨테이너 재시작
- `KafkaDeadLetter`: `*.DLT` 토픽에 메시지가 들어옴 (발급 저장이 재시도까지 실패)
- `NodeDown`: node-exporter에 1분 넘게 접속 안 됨 / `NodeNotReady`: 쿠버네티스가 보는 노드 상태 NotReady 1분

### 디스코드 웹훅 설정 (직접 할 일)

1. 디스코드에서 알림 받을 서버의 채널 옆 톱니바퀴(채널 편집) → **연동(Integrations)** → **웹후크(Webhooks)** → **새 웹후크**
2. 이름(예: platform-alert)을 정하고 **웹후크 URL 복사**
3. 맥의 터미널 앱에서 (이 대화창이 아니라):
   ```bash
   cd ~/Projects/platform-infra
   scripts/set-vault-secret.sh vault_discord_webhook_url   # 붙여넣어도 화면에 보이지 않는다
   cd ansible && ansible-playbook monitoring.yml           # Secret을 바꾸고 Alertmanager를 다시 띄운다
   ```
4. 시험 알림 보내기:
   ```bash
   kubectl -n platform port-forward svc/alertmanager 9093:9093 &
   curl -XPOST localhost:9093/alertmanager/api/v2/alerts -H 'Content-Type: application/json' \
     -d '[{"labels":{"alertname":"시험","namespace":"platform"},"annotations":{"summary":"알림 시험","description":"디스코드로 오면 성공"}}]'
   ```
   30초 안에 디스코드에 메시지가 온다 (`group_wait: 30s`)

웹훅 URL은 그 채널에 아무나 글을 쓸 수 있는 열쇠라 비밀이다 → vault에만 두고, 대화창·Git·로그에 남기지 않는다.

## 응답 끊김 조사 (4단계의 IncompleteRead)

### 결과 요약

- **배포와 무관했다.** 배포 없이 409 응답만 보내도 재현됐다
- **chunked 응답(409 같은 오류 응답)에서만 난다.** 202 응답(`Content-Length`)은 수십만 건 중 0건
- **맥이 클라이언트일 때만 난다.** 클러스터 안에서는 0건
- 서버에서는 처리가 끝난 요청이라(발급이면 저장까지), 다시 요청하면 같은 결과(409)가 와서 데이터 문제는 없다
- 원인 위치: 맥 ↔ VM 네트워크(macOS vmnet 브리지·NAT) 구간 + chunked 응답. 정확한 원인(패킷 단위)은 확정하지 못했다

### 과정

1. Traefik 접근 로그(JSON)를 켰다 (`ansible/roles/monitoring/templates/traefik-config.yaml.j2`)
2. 롤링 업데이트 3번 + 부하: 666,717건 중 **23건 IncompleteRead**. Traefik 로그에서 정확히 23건이 `DownstreamStatus 409, OriginStatus 0, OriginContentSize 0, DownstreamContentSize 99`
   - 시각이 배포 순간에 몰리지 않고 10분 내내 퍼져 있었고, 교체되지 않은 파드에서도 났다 → 배포와 무관
   - (이 시험의 응답이 전부 409였던 것은 VM 시계가 51분 늦어서다. 아래 "VM 시계" 참고)
3. 응답 헤더 비교: 202는 `Content-Length: 70`, 409는 `Transfer-Encoding: chunked`
4. 가설 1 "Tomcat이 연결당 100번째 요청 뒤 연결을 닫을 때 chunked 응답의 끝 조각이 잘린다" → A/B 시험
   - A (기본 `maxKeepAliveRequests=100`): 409 298,188건 중 **8건**, Traefik `OriginStatus 0` 8건 (배포 없음)
   - B (`SERVER_TOMCAT_MAX_KEEP_ALIVE_REQUESTS=-1`): 283,197건 중 **7건** → **가설 기각**, 설정은 되돌림
5. 구간 나누기 (409만, 각 2~3분):
   - 클러스터 안 파드 → 쿠폰 파드 직접: 659,938건 **0건**
   - 클러스터 안 파드 → Traefik: 315,473건 **0건**
   - worker1 VM → cp1 노드 IP(ServiceLB → Traefik): 207,060건 **0건**
   - 맥 → worker2 노드 IP: 201,386건 중 **1건**
   - 맥 → cp1 노드 IP: 231,853건 중 **3건**
6. cp1에서 TCP RST 패킷을 잡으며 맥에서 2분 부하: 이번엔 끊김 0건, RST도 없음 (드물게 무작위로 나서 한 번에 잡히지 않음)

### 다음 관찰 방법

- 맥에서 `sudo tcpdump -i bridge100 'tcp port 80 and (tcp[tcpflags] & (tcp-rst|tcp-fin) != 0)'`를 켜고 409 부하를 오래 건다 → 끊긴 클라이언트 포트(부하 도구가 남김)의 패킷을 본다
- 앱 쪽 대안: 오류 응답도 `Content-Length`로 보내게 한다(예: 예외 처리기에서 본문 길이를 정해 보내거나 응답 버퍼링 필터). 실제 원인이 vmnet이라면 운영(클라우드 로드밸런서)에서는 필요 없을 수 있다
- 대시보드 "Traefik → 쿠폰 서버 응답 코드"와 Traefik 접근 로그의 `OriginStatus 0`을 계속 본다

## VM 시계가 51분 늦어진 문제

- 증상: 맥에서 "1분 전 시작"으로 만든 쿠폰이 전부 `COUPON_NOT_IN_ISSUE_PERIOD`(409)
- 원인: 맥이 잠든 동안(`pmset -g log`: 13:25~14:03, 14:10~14:26 유휴 절전) VM도 멈췄고, 깨어난 뒤 VM 시계가 멈춘 시간(약 54분)만큼 뒤처졌다.
  systemd-timesyncd는 다음 확인까지 최대 34분을 기다리고, 그 34분도 멈췄던 VM의 시계로 세서 바로잡지 못했다 (`Offset: +38ms`는 오래된 값)
- 해결: common 롤에서 **chrony**로 바꿈. 16~64초마다 확인, 1초 넘게 어긋나면 언제든 바로 맞춤(`makestep 1 -1`)
- 확인: 이후 14:50~15:06 절전(Thermal Emergency)에서 깨어난 뒤 세 VM 모두 1ms 안으로 맞춰져 있었다
- Grafana 그래프에도 맥이 잠든 구간이 빈칸으로 보인다
- 오래 시험할 때는 맥이 잠들지 않게: `caffeinate -is -t 7200` (2시간) 또는 시스템 설정 → 배터리 → "전원 어댑터 연결 시 디스플레이가 꺼져 있을 때 자동으로 잠자기 방지"
- 4단계 이후 기록 중 시각이 이상해 보이는 것이 있다면 이 문제를 의심한다

## 검증 기록 (2026-10-20)

- ArgoCD Application 4개(monitoring, grafana, kube-state-metrics, node-exporter) Synced·Healthy, 파드 11개 Running
- 수집 대상 16개 모두 up: cadvisor 3, node-exporter 3, kube-state-metrics 2, coupon 2, traefik, kube-dns, mysqld/redis/kafka exporter, VictoriaMetrics 자신. 시계열 약 9,800개
- 맥 브라우저: `http://192.168.252.2/grafana/` 200, 대시보드 2개(플랫폼 개요, 쿠폰 서버) 자동으로 들어옴, `/alertmanager/`
- 알림 끝까지: DLT 토픽에 시험 메시지 1건(06:37:37 UTC) → 71초 뒤 `KafkaDeadLetter` 울림 → Alertmanager가 받음(지금은 웹훅이 없어 blackhole)
- `ContainerMemoryHigh`는 쿠폰 파드(RSS 88%)에서 실제로 울리는 중
- 규칙 단위 테스트 `scripts/test-alerts.sh` (vmalert-tool): NodeDown(1분 뒤 울림), PodRestarted, ContainerMemoryHigh(90%는 울림, 80%는 안 울림) 통과.
  기대값을 일부러 틀리게 바꾸면 실패하는 것도 확인. NodeDown은 노드를 실제로 끄면 MySQL·Kafka가 멈춰 실제로 끄지는 않았다
- 대사 작업 보정: 15:00 무렵 "redis에 채움 3건"(DB에는 있고 Redis에는 없던 발급). 보정한 파드가 교체돼 로그가 사라져서 어느 쿠폰인지 확인하지 못했다.
  Redis 재시작(limit 변경) 또는 맥 절전과 시각이 겹친다. 안전망이 동작한 것은 확인. 파드 로그가 교체와 함께 사라지는 것 자체가 관찰의 빈틈 → 로그 수집(Loki 등)이 다음 후보

## 겪은 문제

- **repo-server OOMKilled (128 → 256Mi에서도)**: 44Mi는 Kustomize 앱 하나만 렌더링할 때의 값이었다. Helm 차트는 저장소 목록(index.yaml, 수십 MB)을 내려받아 해석한다.
  동시 렌더링 2개에서는 256Mi도 넘었다 → `reposerver.parallelism.limit: 1` + 320Mi (앱 5개 강제 렌더링 최대 202Mi). **측정 조건이 실제 사용 조건을 대표하는지 먼저 확인할 것**
- **Grafana OOMKilled (192Mi)**: Grafana 13은 처음 뜰 때 내장 DB 초기화에 메모리를 많이 쓴다 → 320Mi. 자체 알림 엔진·플러그인 자동 설치를 꺼도 RSS 211Mi로 비슷했다
- **VictoriaMetrics CrashLoop**: 플래그 이름을 틀림(`-promscrape.config.checkInterval` → `-promscrape.configCheckInterval`). 이미지에 `-help`를 돌려 모든 플래그를 확인했다.
  고친 뒤에도 그대로였던 이유: StatefulSet은 Ready가 아닌 파드를 새 정의로 바꾸지 않고 기다린다 → 파드를 직접 지웠다
- **kube-state-metrics 지표의 pod 라벨이 덮어써짐**: 수집 쪽에서 붙인 `pod`(= kube-state-metrics 자신)가 지표의 원래 `pod`를 이겨 `exported_pod`로 밀려났다 → `honor_labels: true`
- **메모리 알림이 Grafana에서 늘 울림**: working set은 실행 파일을 읽어 둔 파일 캐시(100Mi)까지 센다 → 알림·패널을 RSS / limit으로
- **시험 스크립트의 `git commit -a`가 커밋 안 된 다른 수정을 담음**: chrony 변경 일부가 `9fd8253`("끊김 재조사: 롤링 업데이트 4")에 들어갔다. 이력을 고쳐 쓰지 않고 다음 커밋 메시지에 밝혔다. 시험 스크립트는 작업 트리가 깨끗할 때만 돌게 고쳤다
- **zsh에서 `pkill -f <패턴>`이 자기 명령까지 끝냄**, `port`라는 변수 이름 충돌로 부하 도구가 80번 포트로 접속 → 시험 도구의 실수. 결과를 믿기 전에 도구부터 의심할 것

## 운영 명령

```bash
open http://192.168.252.2/grafana/                 # 대시보드 (보기는 로그인 없이)
open http://192.168.252.2/alertmanager/            # 울리는 알림, 침묵(silence) 설정
scripts/test-alerts.sh                             # 알림 규칙 단위 테스트
python3 k8s/platform/monitoring/dashboards/gen_dashboards.py   # 대시보드 JSON 다시 만들기 → 커밋·push
kubectl -n kube-system logs deploy/traefik | grep '"OriginStatus":0'   # 끊긴 응답 찾기
```
