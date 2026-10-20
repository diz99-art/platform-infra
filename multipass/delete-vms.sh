#!/usr/bin/env bash
# vms.conf의 VM을 완전히 지운다 (디스크 포함, 되돌릴 수 없다).
# -y 를 붙이면 확인 없이 지운다.
set -euo pipefail
source "$(dirname "$0")/common.sh"

require_multipass

names=$(vm_names | tr '\n' ' ')
if [[ "${1:-}" != "-y" ]]; then
  read -r -p "다음 VM을 디스크까지 지웁니다: $names. 계속할까요? [y/N] " answer
  [[ "$answer" == "y" || "$answer" == "Y" ]] || { echo "취소했습니다."; exit 0; }
fi

for name in $names; do
  if multipass info "$name" >/dev/null 2>&1; then
    multipass delete "$name"
    echo "[$name] 삭제"
  fi
done
# delete는 휴지통에 넣는 것, purge가 실제로 비우는 것
multipass purge

# 다시 만들면 호스트 키가 새로 생기므로 예전 기록과 ssh 별칭을 지운다.
rm -f "$SSH_KNOWN_HOSTS" "$SSH_INCLUDE_FILE"
echo "ssh 별칭과 known_hosts 기록도 지웠습니다. (~/.ssh/config의 Include 줄은 남겨둡니다)"
