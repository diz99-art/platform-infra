#!/usr/bin/env bash
# 통신 확인: 맥 → VM, VM ↔ VM(이름으로), VM → 인터넷
set -uo pipefail
source "$(dirname "$0")/common.sh"

require_multipass

ok()   { printf '  \033[32mOK\033[0m   %s\n' "$1"; }
fail() { printf '  \033[31mFAIL\033[0m %s\n' "$1"; failed=1; }
failed=0
names=$(vm_names)

echo "1) 맥 → VM (ping, ssh 별칭)"
for name in $names; do
  ip="$(vm_ip "$name")"
  ping -c 1 -t 2 "$ip" >/dev/null 2>&1 && ok "ping $name ($ip)" || fail "ping $name ($ip)"
  ssh -o BatchMode=yes -o ConnectTimeout=5 "$name" true 2>/dev/null && ok "ssh $name" || fail "ssh $name"
done

echo "2) VM ↔ VM (/etc/hosts의 이름으로 ping)"
for from in $names; do
  for to in $names; do
    [[ "$from" == "$to" ]] && continue
    ssh -o BatchMode=yes "$from" "ping -c 1 -W 2 $to" >/dev/null 2>&1 \
      && ok "$from → $to" || fail "$from → $to"
  done
done

echo "3) VM → 인터넷 (NAT를 거쳐 밖으로 나가는지, DNS가 되는지)"
for name in $names; do
  ssh -o BatchMode=yes "$name" "curl -s -o /dev/null -m 5 -w '%{http_code}' https://github.com" 2>/dev/null | grep -q '^[23]' \
    && ok "$name → https://github.com" || fail "$name → https://github.com"
done

echo "4) 참고: cp1의 네트워크 정보"
ssh -o BatchMode=yes cp1 "ip -4 -brief addr show; ip route" 2>/dev/null | sed 's/^/  /'

exit $failed
