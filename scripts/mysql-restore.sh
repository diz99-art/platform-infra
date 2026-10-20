#!/usr/bin/env bash
# 맥에 있는 백업 파일로 DB 하나를 복구한다. 그 DB의 지금 내용은 지워지고 백업 시점으로 돌아간다.
#   사용: scripts/mysql-restore.sh <DB> <백업 폴더 또는 .sql.gz 파일> [-y]
#   예:   scripts/mysql-restore.sh coupon ~/platform-backups/mysql/20261020-112205
# 계정과 권한(mysql.user, mysql.db)은 DB를 지워도 남으므로 다시 만들 필요가 없다.
set -euo pipefail

usage() { echo "사용: $0 <coupon|auth|notification> <백업 폴더|파일> [-y]" >&2; exit 1; }
[[ $# -ge 2 ]] || usage
db="$1"; src="$2"; yes="${3:-}"

case "$db" in coupon|auth|notification) ;; *) echo "모르는 DB: $db" >&2; usage ;; esac
[[ -d "$src" ]] && src="$src/$db.sql.gz"
[[ -f "$src" ]] || { echo "백업 파일이 없습니다: $src" >&2; exit 1; }
# 끝까지 온전한 파일인지 먼저 확인 (gzip 검사 + mysqldump 완료 표시)
gunzip -t "$src"
gunzip -c "$src" | tail -1 | grep -q 'Dump completed' || { echo "덤프가 끝까지 기록되지 않은 파일입니다: $src" >&2; exit 1; }

export KUBECONFIG="${KUBECONFIG:-$HOME/.kube/platform-infra.yaml}"

if [[ "$yes" != "-y" ]]; then
  read -r -p "DB '$db'를 지우고 $src 로 되돌립니다. 계속할까요? [y/N] " a
  [[ "$a" == "y" || "$a" == "Y" ]] || { echo "취소했습니다."; exit 0; }
fi

start=$(date +%s)
# DROP 뒤에 덤프를 흘려 넣는다. 덤프에 CREATE DATABASE와 USE가 들어 있다(--databases로 떴기 때문).
# root 비밀번호는 맥에 꺼내지 않고, 파드 안의 환경변수(Secret에서 옴)를 그대로 쓴다.
{ echo "DROP DATABASE IF EXISTS \`$db\`;"; gunzip -c "$src"; } \
  | kubectl -n data exec -i mysql-0 -- sh -c 'MYSQL_PWD="$MYSQL_ROOT_PASSWORD" exec mysql -uroot'

echo "복구 완료: $db ← $src ($(( $(date +%s) - start ))초)"
kubectl -n data exec mysql-0 -- sh -c "MYSQL_PWD=\"\$MYSQL_ROOT_PASSWORD\" mysql -uroot -e \"SELECT table_name, table_rows FROM information_schema.tables WHERE table_schema='$db'\""
