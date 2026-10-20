# 3단계 검증 기록: MySQL (2026-10-20)

환경: k3s v1.36.5+k3s1, MySQL 8.4.11 (worker1), ansible-core 2.21.5, ansible.mysql 5.2.0, kubernetes.core 6.6.0

## 1. 배포와 멱등성

- `ansible-playbook mysql.yml` 첫 실행: Secret 6개, PV 2개, StatefulSet, CronJob 생성 → MySQL Ready까지 포함해 약 30초
- 계정 생성에서 한 번 실패 → 고친 뒤 성공 (아래 "겪은 문제")
- 다시 실행 (11초):
  ```
  cp1        : ok=6  changed=0
  localhost  : ok=7  changed=0
  worker1    : ok=1  changed=0
  ```
- 2단계 `site.yml`도 함께 다시 실행: changed=0 (group_vars를 폴더로 바꾸고 vault를 넣은 뒤에도 문제없음)
- 적용된 설정 확인: `innodb_buffer_pool_size` 256MB, `max_connections` 120, `performance_schema` OFF, `utf8mb4`, `skip_name_resolve` ON
- 계정 5개 모두 `caching_sha2_password`, `max_user_connections` 서비스 25 / 백업 2

## 2. 최소 권한 테스트

`apps` 네임스페이스에 Secret `mysql-coupon`을 env로 받는 파드(`k8s/examples/mysql-client.yaml`)를 띄워 coupon 계정으로 시험했다. 앱이 붙는 방식과 같다.

허용되는 것:
- `SELECT CURRENT_USER()` → `coupon@%`
- `SHOW DATABASES` → `coupon`, `information_schema`, `performance_schema`만 보인다 (auth, notification, file은 존재조차 안 보임)
- `coupon` DB에서 CREATE TABLE, INSERT, SELECT → 성공

거부되는 것:
- `USE auth` → `ERROR 1044: Access denied for user 'coupon'@'%' to database 'auth'`
- `CREATE TABLE auth.hack` → `ERROR 1142: CREATE command denied`
- `SELECT * FROM notification.anything` → `ERROR 1142: SELECT command denied`
- `CREATE DATABASE evil` → `ERROR 1044`
- `CREATE USER` → `ERROR 1227: you need the CREATE USER privilege`
- `GRANT SELECT ON coupon.* TO auth` → `ERROR 1044` (GRANT OPTION 없음)
- `DROP TABLE coupon.perm_test` (자기 DB인데도) → `ERROR 1142: DROP command denied`
- 틀린 비밀번호 → `ERROR 1045: Access denied (using password: YES)`

## 3. 데이터 보존

시험 테이블 `coupon.persist_check`에 3줄을 넣고:

- **파드 삭제** (`kubectl delete pod mysql-0`): 새 `mysql-0`이 같은 worker1에 **8초** 만에 Ready → 3줄 그대로
- **worker1 VM 재부팅** (`multipass restart worker1`, 11:21:25 부팅 확인): 컨테이너가 다시 시작됨(Last State: Terminated, Exit 255) → **27초** 뒤 쿼리 가능, 4줄 그대로
  - 노드가 꺼진 걸 쿠버네티스가 알아채기까지 약 40초가 걸려서, 그 사이 `kubectl get node`는 예전 상태(Ready)를 보여줬다
- **k3s 전체 제거 → 재설치** (`k3s-uninstall.yml` → `site.yml` → `mysql.yml`, 합계 77초):
  쿠버네티스 쪽 객체(PV, PVC, Secret, StatefulSet)는 전부 지워졌다가 다시 만들어졌지만, `/srv/data/mysql`이 남아 있어
  MySQL이 기존 데이터 폴더를 그대로 열었다 → 시험 데이터와 계정 5개가 그대로, 앱 계정으로 바로 접속됨. DB·계정 단계는 changed=0

## 4. 백업

- 수동 실행 `kubectl -n data create job --from=cronjob/mysql-backup ...`: **3초**, DB별 `.sql.gz` 4개 (각 1KB 미만)
- 덤프 안에 `CREATE DATABASE`, 시험 데이터 `INSERT`, `-- Dump completed` 표시 확인
- 보관 기간: 10일 전 날짜의 폴더를 일부러 만들고 백업을 돌리자 `/backup/20261010-030000`이 지워짐 (오늘 백업 3개는 유지)
- 맥으로 가져오기 `scripts/fetch-mysql-backups.sh`: `~/platform-backups/mysql/<날짜-시각>/` (권한 700/600)

## 5. 복구 훈련

### 훈련 1: 작은 데이터

1. 마지막 백업 뒤에 `after-last-backup` 한 줄 추가 (총 5줄)
2. 사고 흉내: `DROP DATABASE coupon` → 앱 계정 `ERROR 1049: Unknown database 'coupon'`
   - 이때도 `mysql.db`에는 coupon·backup 계정의 coupon 권한이 남아 있었다 → 복구 후 권한을 다시 줄 필요 없음
3. `scripts/mysql-restore.sh coupon ~/platform-backups/mysql/20261020-112228 -y`
4. 결과: 4줄 복구, `after-last-backup`은 **사라짐** → 마지막 백업 이후 데이터는 잃는다 (RPO = 백업 간격, 지금은 최대 24시간)

시간 (같은 훈련을 한 번 더, 밀리초 측정): 맥으로 가져오기 184ms + 복구 195ms + 앱 계정 확인 92ms = **0.47초**

### 훈련 2: 100만 줄 (쿠폰 발급 기록 흉내)

- `drill_issue` 테이블 100만 줄 (user_id 인덱스 포함, .ibd 파일 80MB) 넣기: 5.0초
- 백업 Job: 4.4초, `coupon.sql.gz` 7.5MB
- `DROP DATABASE coupon` 후:
  - 맥으로 가져오기 313ms
  - 복구 6,251ms
  - 앱 계정으로 확인 175ms (`COUNT(*)` = 1,000,000)
  - **합계 6.7초**
- 복구 시간은 데이터 크기에 거의 비례한다 (80MB 테이블 ≈ 6초 → 1GB면 1분 남짓으로 예상). 더 커지면 mysqldump 대신 물리 백업(Percona XtraBackup 등)을 검토한다.

훈련 뒤 시험 테이블은 모두 지웠다 (coupon DB는 빈 상태).

## 6. 메모리 실측

- MySQL 파드 cgroup: 재시작 직후 151MiB, 100만 줄 직후 620MiB (anon 403 + 파일 캐시 209), limit 768Mi
- 노드 (free -m, 100만 줄 직후): cp1 used 870 / worker1 751 / worker2 401 MB
- 예산표와 판단: [memory-plan.md](memory-plan.md)

## 겪은 문제

- **`Plugin 'mysql_native_password' is not loaded` (1524)**: 모듈에 `password:`만 주면 옛 인증 방식으로 계정을 만들려 한다. MySQL 8.4는 그 방식을 기본으로 꺼두었다.
  `plugin: caching_sha2_password` + `plugin_auth_string`으로 바꿨다. `no_log` 때문에 오류가 가려져서, 가짜 계정(probe_test)으로 같은 옵션을 넣어 원인을 찾고 지웠다.
- **계정 작업이 매번 changed**: caching_sha2 해시는 같은 비밀번호도 매번 달라 모듈이 비교하지 못한다 → `update_password: on_create`. 비밀번호 교체는 `-e mysql_rotate_passwords=true`로 따로 한다.
- **community.mysql 사용 중단 경고**: 후속 컬렉션 `ansible.mysql`(이미 설치돼 있음)로 바꿨다.
- **남은 경고 1개**: `Direct access to the environment attribute is deprecated` — kubernetes.core 컬렉션 내부에서 나는 경고. 우리 코드 문제가 아니고 컬렉션 업데이트를 기다린다.
- **`sudo -u "#999"`가 `unknown user`**: VM에 999번 사용자 이름이 없어서다. `sudo install -d -o 999 -g 999`처럼 숫자로 주인을 정했다.
- **100만 줄을 넣었는데 테이블 크기가 0.0MB로 나옴**: `information_schema.tables`의 크기는 통계 값이라 대량 INSERT 직후에는 갱신이 안 돼 있다. 실제 크기는 `.ibd` 파일로 확인했다.
