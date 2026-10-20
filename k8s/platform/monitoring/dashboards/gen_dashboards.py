#!/usr/bin/env python3
"""Grafana 대시보드 JSON 생성기. 패널을 고치려면 이 파일을 고치고 실행한 뒤 JSON까지 커밋한다.
    python3 k8s/platform/monitoring/dashboards/gen_dashboards.py
결과: platform-overview.json, coupon.json (같은 폴더). ArgoCD가 ConfigMap으로 올리고 Grafana가 30초 안에 다시 읽는다.
"""
import json
from pathlib import Path

DS = {"type": "prometheus", "uid": "vm"}
OUT = Path(__file__).parent


class Board:
    def __init__(self, uid, title, description):
        self.uid, self.title, self.description = uid, title, description
        self.panels, self.y, self.x, self.row_h, self.next_id = [], 0, 0, 0, 1

    def row(self, title):
        self._newline()
        self.panels.append({"type": "row", "title": title, "id": self._id(), "collapsed": False,
                            "gridPos": {"x": 0, "y": self.y, "w": 24, "h": 1}, "panels": []})
        self.y += 1

    def panel(self, title, targets, unit="short", w=12, h=8, kind="timeseries", description="",
              thresholds=None, stack=False, max_=None):
        if self.x + w > 24:
            self._newline()
        fc = {"defaults": {"unit": unit, "custom": {}}, "overrides": []}
        if kind == "timeseries":
            fc["defaults"]["custom"] = {"lineWidth": 1, "fillOpacity": 10, "showPoints": "never",
                                        "stacking": {"mode": "normal" if stack else "none"}}
        if max_ is not None:
            fc["defaults"]["max"] = max_
        if thresholds:
            fc["defaults"]["thresholds"] = {"mode": "absolute", "steps": [{"color": "green", "value": None}] +
                                            [{"color": c, "value": v} for v, c in thresholds]}
            if kind == "timeseries":
                fc["defaults"]["custom"]["thresholdsStyle"] = {"mode": "dashed"}
        p = {"type": kind, "title": title, "description": description, "id": self._id(), "datasource": DS,
             "gridPos": {"x": self.x, "y": self.y, "w": w, "h": h}, "fieldConfig": fc,
             "targets": [{"refId": chr(65 + i), "datasource": DS, "expr": e, "legendFormat": l}
                         for i, (e, l) in enumerate(targets)],
             "options": {"legend": {"displayMode": "table", "placement": "right", "calcs": ["lastNotNull", "max"]},
                         "tooltip": {"mode": "multi", "sort": "desc"}} if kind == "timeseries" else
                        {"reduceOptions": {"calcs": ["lastNotNull"]}, "colorMode": "background"}}
        self.panels.append(p)
        self.x += w
        self.row_h = max(self.row_h, h)

    def _newline(self):
        if self.x:
            self.y += self.row_h
        self.x, self.row_h = 0, 0

    def _id(self):
        self.next_id += 1
        return self.next_id

    def write(self, name):
        doc = {"uid": self.uid, "title": self.title, "description": self.description, "schemaVersion": 39,
               "time": {"from": "now-3h", "to": "now"}, "refresh": "30s", "timezone": "browser",
               "tags": ["platform"], "editable": False, "panels": self.panels, "templating": {"list": []}}
        (OUT / name).write_text(json.dumps(doc, ensure_ascii=False, indent=1) + "\n")


WS = 'container_memory_working_set_bytes'
LIM = 'container_spec_memory_limit_bytes'

# ── 플랫폼 개요 ──
b = Board("platform-overview", "플랫폼 개요", "노드·컨테이너 메모리, 재시작, 데이터 계층, 알림")
b.row("노드")
b.panel("노드 메모리 사용률", [('1 - node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes', '{{node}}')],
        unit="percentunit", thresholds=[(0.85, "red")], max_=1,
        description="free -m의 available 기준. 85% 넘게 5분이면 NodeMemoryHigh 알림")
b.panel("노드 CPU 사용률", [('1 - avg by (node) (rate(node_cpu_seconds_total{mode="idle"}[2m]))', '{{node}}')],
        unit="percentunit", max_=1)
b.panel("워커 limit 합 / 메모리 총량",
        [(f'sum({LIM}{{node=~"worker.*"}}) / sum(node_memory_MemTotal_bytes{{node=~"worker.*"}})', 'limit 합'),
         (f'sum({WS}{{node=~"worker.*"}}) / sum(node_memory_MemTotal_bytes{{node=~"worker.*"}})', '실제 사용(working set)')],
        unit="percentunit", w=8, kind="stat", thresholds=[(0.75, "orange"), (0.85, "red")],
        description="지금 떠 있는 컨테이너 기준. 계획 전체의 예산은 docs/memory-plan.md")
b.panel("노드가 응답하나 (node-exporter up)", [('up{job="node-exporter"}', '{{node}}')], w=8, kind="stat",
        thresholds=[(1, "green")], description="0이면 NodeDown 알림")
b.panel("최근 1시간 재시작", [('sum by (namespace, pod) (increase(kube_pod_container_status_restarts_total[1h])) > 0', '{{namespace}}/{{pod}}')],
        w=8, kind="stat", thresholds=[(1, "red")])
b.row("컨테이너 메모리")
b.panel("컨테이너 메모리(RSS) / limit", [(f'max by (namespace, pod, container) (container_memory_rss) / on (namespace, pod, container) max by (namespace, pod, container) ({LIM} > 0)',
                                    '{{namespace}}/{{pod}}')],
        unit="percentunit", w=24, h=10, thresholds=[(0.85, "red")], max_=1,
        description="RSS(돌려받을 수 없는 메모리) / limit. 85% 넘게 5분이면 ContainerMemoryHigh 알림. working set은 파일 캐시를 포함해 더 크게 보인다")
b.panel("컨테이너 메모리 (working set)", [(f'sum by (namespace, pod) ({WS})', '{{namespace}}/{{pod}}')],
        unit="bytes", w=24, h=10, stack=True)
b.row("데이터 계층")
b.panel("MySQL", [('mysql_up', 'up'), ('mysql_global_status_threads_connected', '연결 수'),
                  ('rate(mysql_global_status_queries[1m])', '쿼리/초')], w=8)
b.panel("Redis", [('redis_memory_used_bytes / 1024 / 1024', '메모리 MiB'), ('redis_connected_clients', '연결 수'),
                  ('rate(redis_commands_processed_total[1m])', '명령/초')], w=8)
b.panel("Kafka", [('kafka_brokers', '브로커 수'), ('sum by (consumergroup) (kafka_consumergroup_lag)', 'lag {{consumergroup}}'),
                  ('sum by (topic) (kafka_topic_partition_current_offset{topic=~".+\\\\.DLT"})', 'DLT 메시지 {{topic}}')], w=8,
        description="lag: 컨슈머가 아직 처리하지 않은 메시지. DLT가 늘면 KafkaDeadLetter 알림")
b.row("알림")
b.panel("울리는 알림", [('sum by (alertname, alertstate) (ALERTS)', '{{alertname}} {{alertstate}}')], w=24, h=6,
        description="vmalert가 평가 결과를 ALERTS 지표로 VictoriaMetrics에 남긴다. pending = 조건은 맞고 for 기간을 기다리는 중")
b.write("platform-overview.json")

# ── 쿠폰 서버 ──
c = Board("coupon", "쿠폰 서버", "발급, Kafka 저장 지연, 대사 보정, HTTP, JVM 메모리, Traefik")
c.row("발급")
c.panel("발급 성공·거절 (초당)", [('sum(rate(coupon_issue_success_total[1m]))', '성공'),
                              ('sum by (reason) (rate(coupon_issue_rejected_total[1m]))', '거절 {{reason}}')], stack=True)
c.panel("Kafka 저장 지연 (발급 응답 → DB 저장)",
        [('sum(rate(coupon_issue_save_delay_seconds_sum[1m])) / sum(rate(coupon_issue_save_delay_seconds_count[1m]))', '평균'),
         ('max(coupon_issue_save_delay_seconds_max)', '최대')], unit="s",
        description="배포 중 컨슈머 리밸런스가 일어나면 잠깐 커진다 (docs/coupon.md)")
c.panel("대사 보정 (5분)", [('sum by (target) (increase(coupon_reconcile_corrected_total[5m]))', '{{target}}에 채움')], w=8,
        description="0이 정상. db = Redis에만 있던 발급을 DB에 저장, redis = DB에만 있던 발급을 Redis에 복구")
c.panel("HTTP 응답 (초당, 상태 코드별)", [('sum by (status) (rate(http_server_requests_seconds_count{job="coupon", uri!~"/actuator.*"}[1m]))', '{{status}}')],
        w=8, stack=True)
c.panel("발급 API 응답 시간 p95", [('histogram_quantile(0.95, sum by (le) (rate(http_server_requests_seconds_bucket{job="coupon", uri="/coupons/{couponId}/issue"}[1m])))', 'p95')],
        unit="s", w=8)
c.row("JVM 메모리 (파드별)")
c.panel("컨테이너 메모리 = 힙 + 힙 밖 + 네이티브",
        [(f'sum by (pod) ({WS}{{namespace="apps", container="coupon"}})', '컨테이너 {{pod}}'),
         ('sum by (pod) (jvm_memory_committed_bytes{job="coupon", area="heap"})', '힙 확보 {{pod}}'),
         ('sum by (pod) (jvm_memory_committed_bytes{job="coupon", area="nonheap"})', '힙 밖 확보 {{pod}}'),
         (f'sum by (pod) ({WS}{{namespace="apps", container="coupon"}}) - sum by (pod) (jvm_memory_committed_bytes{{job="coupon"}})', 'JVM이 모르는 네이티브 {{pod}}'),
         (f'max({LIM}{{namespace="apps", container="coupon"}})', 'limit')],
        unit="bytes", w=24, h=10,
        description="네이티브 = 스레드 스택, GC 자료구조, JIT 컴파일러, malloc. 6단계 실측: 힙 밖 약 186MB, 네이티브 약 100MB로 일정하고 차이는 힙 확보량에서 났다")
c.panel("힙 사용·확보", [('sum by (pod) (jvm_memory_used_bytes{job="coupon", area="heap"})', '사용 {{pod}}'),
                      ('sum by (pod) (jvm_memory_committed_bytes{job="coupon", area="heap"})', '확보 {{pod}}'),
                      ('max(jvm_memory_max_bytes{job="coupon", area="heap", id="Tenured Gen"}) + max(jvm_memory_max_bytes{job="coupon", area="heap", id="Eden Space"}) + max(jvm_memory_max_bytes{job="coupon", area="heap", id="Survivor Space"})', '최대')],
        unit="bytes", w=8)
c.panel("힙 밖 (영역별 확보)", [('sum by (id) (jvm_memory_committed_bytes{job="coupon", area="nonheap"}) / count by (id) (jvm_memory_committed_bytes{job="coupon", area="nonheap"})', '{{id}}')],
        unit="bytes", w=8, stack=True)
c.panel("GC 멈춤 (초당 멈춘 시간)", [('sum by (pod, gc) (rate(jvm_gc_pause_seconds_sum{job="coupon"}[1m]))', '{{pod}} {{gc}}')],
        unit="s", w=8)
c.row("Traefik (앞단)")
c.panel("Traefik → 쿠폰 서버 응답 코드 (초당)", [('sum by (code) (rate(traefik_service_requests_total{service=~"apps-coupon.*"}[1m]))', '{{code}}')],
        stack=True, description="502/504/499가 보이면 배포 중 끊김을 의심한다 (docs/monitoring.md)")
c.panel("Traefik 열린 연결", [('sum by (entrypoint) (traefik_open_connections)', '{{entrypoint}}')])
c.write("coupon.json")
print("생성: platform-overview.json, coupon.json")
