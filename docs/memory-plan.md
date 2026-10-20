# 메모리 계획

전체 플랫폼(쿠폰·인증·Gateway·알림·파일 서버 + 공용 미들웨어)이 다 올라갔을 때를 기준으로 세운 예산이다.
새 구성요소를 넣을 때는 아래 목록을 먼저 고치고, 합계가 VM 메모리를 넘지 않는지 확인한다.

## 맥 사양 (2026-10-20 확인)

- Apple M2 Pro, CPU 10코어, 메모리 16GB, 디스크 남은 공간 89GB
- Docker Desktop: 할당 메모리 약 7.75GB (기본값, 전체의 절반)

## 맥 메모리 16GB 나누기

- macOS + 브라우저 + IDE: 약 5GB
- VM 3대: 8GB (cp1 2GB, worker1 3GB, worker2 3GB)
- Docker Desktop: 3GB로 줄인다 (지금 7.75GB)
- 합계 16GB. 여유가 거의 없으므로 클러스터 작업을 할 때는 Docker Desktop을 꺼두는 것이 가장 좋다.

참고: Multipass(QEMU)는 VM에 준 메모리를 처음부터 다 잡지 않고 VM 안에서 쓰는 만큼 가져간다.
그래서 클러스터가 비어 있을 때는 실제 사용량이 8GB보다 훨씬 적다. 하지만 서비스가 다 올라가면 거의 다 쓰게 되므로 예산은 최대치로 잡는다.

## VM 안에서의 예산 (서비스가 다 올라갔을 때)

### cp1 (2GB): 컨트롤 플레인 + 가벼운 공용 요소

- Ubuntu 기본: 250MB
- k3s server (API 서버, 스케줄러, 내장 DB, kubelet 포함): 700MB
- CoreDNS, Traefik(Ingress), metrics-server: 200MB
- 남는 여유: 약 850MB → 나중에 모니터링(Prometheus·Grafana를 작게) 후보

### worker1 (3GB): 데이터 계층

- Ubuntu 기본 + k3s agent: 550MB
- MySQL 8.4 하나 (DB 4개: coupon, auth, notification, file): 메모리 제한 768MB, innodb_buffer_pool_size 256MB
- Redis 7 (쿠폰 재고·락): 128MB
- Kafka 4.x 1대, KRaft (쿠폰 발급 큐): 메모리 제한 768MB, 힙 512MB
- 합계 약 2.2GB, 여유 800MB

### worker2 (3GB): 애플리케이션 계층

Spring Boot 앱 하나당 메모리 제한 448MB, 힙 약 224MB (`-XX:MaxRAMPercentage=50`)로 잡는다.

- Ubuntu 기본 + k3s agent: 550MB
- Gateway, 인증, 쿠폰, 알림, 파일 서버 5개 × 448MB: 2.2GB
- 합계 약 2.75GB, 여유 250MB

쿠폰 서버를 2대로 늘리는 실습은 worker1의 여유 공간에 띄운다.

## MySQL을 하나만 두는 이유

- MySQL 서버 하나는 아무것도 안 해도 300~400MB를 쓴다. 서비스마다 따로 두면 4개 × 400MB = 1.6GB가 들고, 하나로 합치면 768MB면 된다.
- 대신 서비스끼리 데이터를 섞지 않도록 DB를 나누고, 계정마다 자기 DB에만 권한을 준다 (예: `coupon` 계정은 `coupon` DB만).
  → 실무의 "서비스별 DB 분리" 원칙을 지키면서 물리 서버만 공유하는 방식이다.
- 단점: MySQL이 죽으면 모든 서비스가 같이 멈춘다. 학습용이므로 받아들이고, 나중에 이 단점을 직접 겪어보는 것도 공부다.

## VM을 3대로 하는 이유 (2대와 비교)

- 2대(컨트롤 플레인 1 + 워커 1)면 VM 하나만큼 운영체제·k3s 오버헤드(약 300MB)를 아낄 수 있다.
- 하지만 워커가 1대면 "파드를 여러 노드에 나눠 배치", "노드 하나를 비우고(drain) 다른 노드로 옮기기", "노드 장애" 같은 쿠버네티스의 핵심 실습을 할 수 없다.
- 16GB 맥에서 3대가 감당 가능하므로 3대로 한다.

## 디스크

- cp1 15GB, worker1·worker2 각 20GB = 최대 55GB. 실제로는 쓴 만큼만 늘어난다 (thin provisioning).
- 남은 89GB 중 VM이 다 차면 34GB가 남는다. 컨테이너 이미지와 MySQL 데이터가 쌓이면 `df -h`로 가끔 확인한다.
