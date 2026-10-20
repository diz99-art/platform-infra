#!/usr/bin/env bash
# vault.yml의 값 하나를 바꾼다. 입력은 화면에 보이지 않고, 평문 파일은 잠깐만 만들었다가 지운다.
#   사용: scripts/set-vault-secret.sh vault_discord_webhook_url
# 터미널(맥의 터미널 앱)에서 직접 실행한다. 값을 대화창이나 다른 곳에 붙여넣지 않는다.
set -euo pipefail
key="${1:?바꿀 키 이름 (예: vault_discord_webhook_url)}"
cd "$(dirname "$0")/../ansible"
read -r -s -p "$key 값 (입력이 보이지 않습니다): " value; echo
[[ -n "$value" ]] || { echo "빈 값입니다. 취소"; exit 1; }
tmp="$(mktemp)"; trap 'rm -f "$tmp"' EXIT; chmod 600 "$tmp"
ansible-vault decrypt group_vars/all/vault.yml --output "$tmp"
KEY="$key" VALUE="$value" python3 - "$tmp" <<'PY'
import os, re, sys
p, k, v = sys.argv[1], os.environ["KEY"], os.environ["VALUE"].replace("'", "''")
s = open(p).read()
line = f"{k}: '{v}'"
s = re.sub(rf"^{re.escape(k)}:.*$", lambda m: line, s, flags=re.M) if re.search(rf"^{re.escape(k)}:", s, re.M) else s + line + "\n"
open(p, "w").write(s)
PY
ansible-vault encrypt "$tmp" --output group_vars/all/vault.yml
echo "$key 를 바꿨습니다. 적용: cd ansible && ansible-playbook monitoring.yml"
