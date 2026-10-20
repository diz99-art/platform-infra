#!/usr/bin/env bash
# worker1에 쌓인 MySQL 백업을 맥으로 복사한다. 이미 받은 파일은 건너뛴다 (rsync).
# 노드 디스크가 망가지면 노드 안의 백업도 같이 잃으므로, 다른 곳(맥)에 한 벌 더 둔다.
#   사용: scripts/fetch-mysql-backups.sh [받을 폴더]   (기본: ~/platform-backups/mysql)
set -euo pipefail

NODE="${MYSQL_NODE:-worker1}"
SRC=/srv/backup/mysql/
DEST="${1:-$HOME/platform-backups/mysql}"
# 맥 쪽 보관 기간. 노드(7일)보다 길게 둔다
KEEP_DAYS="${KEEP_DAYS:-30}"

mkdir -p "$DEST" && chmod 700 "$DEST"

# 백업 폴더는 컨테이너 사용자(999)만 읽을 수 있으므로 VM 쪽 rsync를 sudo로 실행한다
# --exclude: 아직 만드는 중인 임시 폴더는 받지 않는다
# --delete를 쓰지 않는다: 노드에서 7일이 지나 지워진 백업도 맥에는 남겨 둔다
rsync -a --rsync-path="sudo rsync" --exclude='.tmp-*' "$NODE:$SRC" "$DEST/"

find "$DEST" -mindepth 1 -maxdepth 1 -type d -name '20*' -mtime +"$KEEP_DAYS" -print -exec rm -rf {} +

echo "맥에 있는 백업 (최근 5개):"
ls -1 "$DEST" | tail -5 | sed "s|^|  $DEST/|"
