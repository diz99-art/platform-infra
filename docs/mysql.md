# 3단계 설계: MySQL

클러스터에 MySQL 8.4 서버 하나를 두고, 서비스(coupon, auth, notification, file)마다 DB와 전용 계정을 나눈다.

## 구조

```
맥 (ansible-playbook mysql.yml)
 ├─ vault.yml(암호화) ──풀어서──▶ Secret 생성 (kubernetes.core.k8s, API 서버로 바로)
 │
 ▼
k3s 클러스터
 ├─ namespace data
 │   ├─ Secret mysql-root, mysql-backup
 │   ├─ ConfigMap mysql-config (my.cnf)
 │   ├─ Service mysql (ClusterIP)        ← 앱 접속 주소 mysql.data.svc.cluster.local:3306
 │   ├─ Service mysql-headless           ← StatefulSet 파드 고정 이름 mysql-0.mysql-headless...
 │   ├─ StatefulSet mysql (1개, worker1 고정)
 │   │    └─ PVC data-mysql-0 ──▶ PV mysql-data (Retain) ──▶ worker1:/srv/data/mysql
 │   └─ CronJob mysql-backup (매일 03:00 KST)
 │        └─ PVC mysql-backup ──▶ PV mysql-backup (Retain) ──▶ worker1:/srv/backup/mysql
 │                                                     │
 │                                 scripts/fetch-mysql-backups.sh (rsync)
 │                                                     ▼
 │                                       맥 ~/platform-backups/mysql (30일 보관)
 └─ namespace apps
     └─ Secret mysql-coupon, mysql-auth, mysql-notification, mysql-file
          (username, password, database, host, port, jdbc-url) ← 앱 파드가 env로 받는다

MySQL 안
 ├─ DB coupon        ← 계정 coupon        (coupon.* 에만 권한)
 ├─ DB auth          ← 계정 auth
 ├─ DB notification  ← 계정 notification
 ├─ DB file          ← 계정 file
 └─ 계정 backup: 4개 DB 읽기 전용 (SELECT, SHOW VIEW, TRIGGER, LOCK TABLES, EVENT)
```

파일 위치:
- `ansible/mysql.yml`: 플레이북 (데이터 노드 폴더 → 쿠버네티스 배포 → DB·계정)
- `ansible/roles/mysql/`: defaults(설정값), tasks(storage, k8s, schema), templates(매니페스트 4개)
- `ansible/group_vars/all/vault.yml`: 비밀번호 (암호화), `main.yml`: vault 값을 일반 변수 이름으로 연결
- `scripts/fetch-mysql-backups.sh`, `scripts/mysql-restore.sh`, `scripts/check-secrets.sh`(커밋 전 검사)
- `k8s/examples/mysql-client.yaml`: 앱처럼 Secret으로 접속해보는 시험용 파드

## 1. 비밀 관리

### Ansible Vault와 쿠버네티스 Secret은 무엇이 다른가

- **Ansible Vault**: 비밀을 **저장소(Git)에 보관**하기 위한 도구. AES256으로 파일을 암호화한다.
  비밀번호 파일(`ansible/.vault-pass`) 없이는 아무도 못 연다. 그래서 암호화된 `vault.yml`은 public 저장소에 올려도 된다.
  쓰는 때: 플레이북을 실행하는 순간 맥의 메모리에서만 풀린다.
- **쿠버네티스 Secret**: 비밀을 **실행 중인 파드에 전달**하기 위한 객체. 파드가 환경변수나 파일로 받는다.
  값은 base64로 **인코딩**되어 있을 뿐 **암호화가 아니다** (`echo 값 | base64 -d`면 바로 보인다).
  보호는 접근 권한(RBAC: 누가 Secret을 읽을 수 있나)과 네임스페이스 분리에 기대고 있다.
- 정리: Vault = "보관용 금고", Secret = "배달용 봉투". 금고에서 꺼내 봉투에 넣는 일을 Ansible이 한다.
  그래서 Secret 매니페스트(YAML 파일)는 저장소에 아예 없다. `check-secrets.sh`가 `kind: Secret` 파일 커밋을 막는다.

### 한 일

- 비밀번호 6개(root, backup, 서비스 4개)를 32자 무작위로 만들어 `ansible-vault encrypt`로 암호화. 평문 파일은 바로 지웠다. 특수문자는 뺐다(JDBC URL·셸 따옴표 문제 방지, 길이로 강도를 확보).
- `ansible.cfg`의 `vault_password_file = .vault-pass` → 플레이북 실행 때 자동으로 풀린다. `.vault-pass`는 `.gitignore`에 있다.
- `vault_` 접두사 관례: vault.yml 안에는 `vault_mysql_root_password`, 일반 변수 파일(main.yml)에는 `mysql_root_password: "{{ vault_mysql_root_password }}"`.
  암호화된 파일은 grep이 안 되므로, "어떤 비밀이 있는지"를 평문 쪽에서 찾을 수 있게 하는 것이다.
- 비밀이 다뤄지는 작업에는 전부 `no_log: true` → 실행 로그에 값이 찍히지 않는다.
- pre-commit hook(`scripts/check-secrets.sh`): 평문 vault 파일, `.vault-pass`, `kind: Secret` 매니페스트, 개인키, k3s 토큰이 커밋에 들어가면 멈춘다.
- **Vault 비밀번호 파일을 잃으면 vault.yml을 영원히 못 연다.** 비밀번호 관리자(예: macOS 암호 앱)에 따로 적어둔다.

명령:
```bash
cd ansible
ansible-vault view group_vars/all/vault.yml     # 보기
ansible-vault edit group_vars/all/vault.yml     # 고치기 (저장하면 다시 암호화)
ansible-playbook mysql.yml -e mysql_rotate_passwords=true   # vault의 새 비밀번호로 계정 비밀번호 교체 (그 뒤 앱 재시작)
kubectl -n apps get secret mysql-coupon -o jsonpath='{.data.password}' | base64 -d   # Secret이 암호화가 아님을 직접 확인
```

한계와 다음 단계:
- k3s는 Secret을 내장 DB(cp1의 `/var/lib/rancher/k3s/server/db`)에 base64로 저장한다. k3s의 `secrets-encryption` 옵션을 켜면 저장할 때 암호화한다 (다음 개선 후보).
- root 계정은 `root@'%'`라 클러스터 안 어디서든 붙을 수 있다 (Ansible이 cp1에서 접속하기 위해). NetworkPolicy로 data 네임스페이스에 들어오는 연결을 apps 네임스페이스와 노드로만 제한하는 것이 다음 개선 후보.

## 2. StatefulSet으로 배포한 이유 (Deployment와 비교)

- **이름이 고정된다**: 파드 이름이 항상 `mysql-0`. Deployment는 `mysql-7c9f...-x2k4` 처럼 다시 뜰 때마다 바뀐다.
  복구 스크립트·백업이 `mysql-0`을 그대로 가리킬 수 있고, 나중에 복제(replica)를 붙이면 `mysql-1`이 "두 번째"라는 순서가 생긴다.
- **저장소가 파드에 묶인다**: `volumeClaimTemplates`로 파드마다 자기 PVC(`data-mysql-0`)를 갖는다. 파드를 지워도 PVC는 남고, 새 `mysql-0`이 같은 PVC를 다시 쓴다.
  Deployment는 모든 복제본이 PVC 하나를 같이 쓰려고 해서, 같은 데이터 폴더를 MySQL 두 개가 동시에 열어 깨질 수 있다.
- **한 번에 하나씩**: 교체할 때 옛 파드가 완전히 끝난 뒤 새 파드를 띄운다. Deployment의 롤링 업데이트는 새 파드를 먼저 띄우므로 잠깐 MySQL 두 개가 같은 데이터 폴더를 노린다.
- **headless Service**: `mysql-0.mysql-headless.data.svc.cluster.local` 처럼 파드별 DNS 이름을 준다. 앱은 보통 Service `mysql`을 쓰지만, 복제 구성에서는 "쓰기는 0번에만" 같은 지정이 가능해진다.

## 3. 저장소: 고정 경로 PV + Retain + 노드 고정

- 2단계에서 정한 대로 기본 local-path(동적)를 쓰지 않고 PV를 직접 만들었다 (`templates/storage.yaml.j2`).
  - `local.path: /srv/data/mysql`: k3s 폴더 밖 → `k3s-uninstall.yml`을 실행해도 남는다
  - `persistentVolumeReclaimPolicy: Retain`: PVC를 지워도 PV와 데이터는 그대로 (Released 상태가 됨)
  - `claimRef: data/data-mysql-0`: 이 PV는 MySQL의 PVC에만 묶인다
  - `nodeAffinity` (PV와 StatefulSet 둘 다): worker1에만. 디스크가 worker1에 있으므로 다른 노드로 옮기면 데이터가 없다
  - StorageClass `local-static` (`no-provisioner`, `WaitForFirstConsumer`): 자동 생성 없이 미리 만든 PV에서 고른다
- 폴더 주인은 숫자 999(컨테이너 안의 mysql 사용자). VM에서 `ls -l`하면 그룹이 `systemd-journal`로 보이는데, 같은 숫자 999가 Ubuntu에서는 그 그룹 이름이라서다. 권한은 숫자로 판단하므로 문제없다.
- 주의: local PV의 용량(5Gi)은 표시일 뿐 강제되지 않는다. 실제 한도는 worker1 디스크(20GB) 전체다.
- 다시 붙이는 법 (k3s를 지우고 다시 설치했을 때): `ansible-playbook site.yml && ansible-playbook mysql.yml` → 같은 경로의 PV가 다시 만들어지고, MySQL이 기존 데이터 폴더를 그대로 연다 (비밀번호는 기존 데이터의 것이 유지된다).
  PVC만 지웠다면 PV가 Released 상태로 남으므로 `kubectl patch pv mysql-data -p '{"spec":{"claimRef":{"uid":null,"resourceVersion":null}}}'`로 다시 묶을 수 있게 한다.

## 4. 자원과 메모리 설정

- requests: CPU 250m, 메모리 512Mi (스케줄러가 이만큼 자리를 예약한다)
- limits: 메모리 768Mi (넘으면 OOMKilled). **CPU limit은 두지 않았다**: CPU limit을 넘으면 강제로 느려져(스로틀링) 쿼리 응답이 튄다. 노드 CPU가 남으면 쓰게 둔다.
- my.cnf (`templates/config.yaml.j2`): MySQL 기본값은 메모리가 수 GB인 서버 기준이라 줄였다
  - `innodb_buffer_pool_size = 256M`: 데이터·인덱스 캐시. 가장 큰 메모리 사용처. 768Mi 한도에서 연결·임시 테이블·OS 캐시 몫을 남긴 크기
  - `performance_schema = OFF`: 켜두면 고정으로 100~200MB. 지금은 끄고, 모니터링(mysqld_exporter) 단계에서 필요하면 켠다
  - `max_connections = 120`, 계정마다 `MAX_USER_CONNECTIONS` (기본 25, coupon 35, 백업 2): 서비스 하나가 연결을 다 잡아먹어 다른 서비스가 못 붙는 상황을 막는다.
    계산: (replicas + 롤링 업데이트 maxSurge) × 커넥션 풀(HikariCP 10) + 여유. coupon = (2 + 1) × 10 + 5 = 35
    (처음에는 maxSurge를 빼먹고 25로 잡아, 4단계에서 배포 중 3번째 파드가 연결 상한에 걸렸다 → docs/coupon.md)
  - `innodb_log_buffer_size 16M`, `table_open_cache 400`, `tmp_table_size 16M`, `mysqlx = OFF`
  - `skip_name_resolve`: 접속마다 IP→이름 DNS 조회를 안 한다 (계정 host가 `%`라 필요 없음)
  - `slow_query_log`: 1초 넘는 쿼리를 데이터 폴더의 로그에 남긴다
- 설정을 바꾸면: ConfigMap 내용의 해시를 파드 어노테이션(`platform-infra/config-hash`)에 넣어 두었다. 내용이 바뀌면 해시가 바뀌어 파드가 자동으로 다시 뜬다.
- 시간대: MySQL 서버는 UTC로 둔다 (`created_at`이 한국 시각보다 9시간 이르게 보인다). 서버는 UTC, 화면에 보여줄 때 KST로 바꾸는 것이 일반적인 관례다.

## 5. Probe (상태 검사)

- **startupProbe** `mysqladmin ping` 5초마다 최대 60번(5분): 처음 데이터 폴더를 만들 때(초기화) 오래 걸린다. 이게 성공할 때까지 아래 두 검사를 미룬다.
  없으면 초기화 도중 liveness가 실패해 컨테이너를 죽이고, 초기화가 영원히 끝나지 않는 일이 생긴다.
- **livenessProbe** `mysqladmin ping` 10초마다, 3번 연속 실패면 재시작: "프로세스가 살아서 응답하나". ping은 비밀번호가 틀려도 서버가 응답하면 성공이라, 비밀번호 문제로 재시작되는 일이 없다.
- **readinessProbe** `mysql -uroot -e 'SELECT 1'` 5초마다: "실제로 쿼리를 받을 수 있나". 실패하면 재시작하지 않고 Service에서만 뺀다 → 앱이 준비 안 된 DB로 연결하지 않는다.
- `terminationGracePeriodSeconds: 60`: 종료할 때 버퍼를 디스크에 쓰고 깨끗이 끝낼 시간.
- `securityContext`: root가 아닌 999로 실행 (`runAsNonRoot`). 컨테이너가 뚫려도 노드 root 권한이 아니다.

## 6. 서비스별 DB와 계정 (최소 권한)

- 계정 이름 = DB 이름, 권한은 `<자기DB>.*`에만:
  `SELECT, INSERT, UPDATE, DELETE, CREATE, ALTER, INDEX, REFERENCES, CREATE TEMPORARY TABLES, LOCK TABLES`
- 일부러 뺀 것: `DROP`(테이블·DB 삭제), `GRANT OPTION`(남에게 권한 주기), 다른 DB, 전역 권한(CREATE USER 등).
  앱이 해킹당하거나 버그가 나도 피해가 자기 DB 안으로 한정되고, 테이블을 통째로 날릴 수는 없다.
  스키마 마이그레이션 도구가 DROP을 요구하면 그때 그 계정에만 추가한다.
- 인증 방식 `caching_sha2_password` (8.4 기본). 비밀번호는 처음 만들 때만 설정(`update_password: on_create`) → 멱등. 바꿀 때는 `-e mysql_rotate_passwords=true`.
- 앱 쪽: `apps` 네임스페이스의 `mysql-<서비스>` Secret을 env로 받는다 (`k8s/examples/mysql-client.yaml` 참고). Spring이라면 `SPRING_DATASOURCE_URL` ← `jdbc-url`, `..._USERNAME` ← `username`, `..._PASSWORD` ← `password`.

## 7. 백업과 복구

- CronJob `mysql-backup`: 매일 03:00 KST (`timeZone: Asia/Seoul`)
  - `mysqldump --single-transaction`: 테이블을 잠그지 않고 한 시점의 일관된 스냅샷 (InnoDB). 서비스 중에도 백업 가능
  - DB별 파일 `<날짜-시각>/<DB>.sql.gz`, `--databases`라 복구 때 CREATE DATABASE가 같이 들어 있다
  - 임시 폴더에 쓰고 다 끝나면 이름을 바꾼다 → 중간에 실패한 백업이 완성본처럼 보이지 않는다
  - `set -o pipefail`: mysqldump가 실패하면 gzip이 성공해도 Job이 실패로 끝난다
  - 비밀번호는 명령줄 대신 옵션 파일로 넘긴다 (명령줄은 `ps`로 다른 프로세스가 볼 수 있다)
  - 7일 지난 백업 자동 삭제, `concurrencyPolicy: Forbid`, 실패 시 2번 재시도, 15분 제한
- 노드 안의 백업은 MySQL 데이터와 **같은 디스크**에 있다. worker1이 망가지면 둘 다 잃는다 → `scripts/fetch-mysql-backups.sh`로 맥에 복사 (맥에서 30일 보관).
- 복구: `scripts/mysql-restore.sh <DB> <백업 폴더>` → 그 DB를 지우고 백업으로 되돌린다. 계정과 권한은 DB를 지워도 남아 있어 다시 만들 필요가 없다.
- 백업은 복구해 봐야 백업이다. 복구 훈련 기록: [mysql-verification.md](mysql-verification.md)

명령:
```bash
kubectl -n data create job --from=cronjob/mysql-backup backup-now   # 지금 백업
kubectl -n data logs job/backup-now
scripts/fetch-mysql-backups.sh                                       # 맥으로 가져오기
scripts/mysql-restore.sh coupon ~/platform-backups/mysql/<날짜-시각>   # 복구
```
