#!/usr/bin/env bash
# 인증 서버 서명 키를 vault에 추가하거나 빼고, Secret auth-jwt-keys에 반영한다 (키 교체 1·5단계).
#   새 키 추가:  scripts/rotate-jwt-key.sh add <kid>      (예: 2026-10-20b)
#   옛 키 삭제:  scripts/rotate-jwt-key.sh remove <kid>
# 개인키는 화면·파일에 남지 않는다 (임시 파일은 끝나면 지운다). 맥의 터미널이나 `! scripts/...`로 직접 실행한다.
# Secret만 바뀌고 앱은 아직 옛 키 목록으로 돈다 → 다음에 k8s/apps/auth/deployment.yaml의
# platform-infra/jwt-keys 어노테이션을 바꿔 push해야 파드가 다시 떠서 키를 읽는다 (platform-services의 docs/auth.md)
set -euo pipefail
action="${1:?add 또는 remove}"; kid="${2:?키 id (예: 2026-10-20b)}"
[[ "$kid" =~ ^[A-Za-z0-9._-]+$ ]] || { echo "kid는 영문·숫자·.-_ 만"; exit 1; }
cd "$(dirname "$0")/../ansible"

tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT; chmod 700 "$tmp"
ansible-vault decrypt group_vars/all/vault.yml --output "$tmp/vault.yml"
if [[ "$action" == add ]]; then
  openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 -out "$tmp/key.pem" 2>/dev/null
fi
ACTION="$action" KID="$kid" python3 - "$tmp" <<'PY'
import os, re, sys
d = sys.argv[1]; action, kid = os.environ["ACTION"], os.environ["KID"]
p = f"{d}/vault.yml"; s = open(p).read()
m = re.search(r"^vault_auth_jwt_keys:\n((?:  .*\n|    .*\n)+)", s, re.M)
if not m: sys.exit("vault_auth_jwt_keys를 찾지 못했습니다")
body = m.group(1)
# kid 하나 = '  "<kid>": |' 줄 + 4칸 들여쓴 PEM 줄들
blocks = re.findall(r'(  "([^"]+)": \|\n(?:    .*\n)+)', body)
kids = [k for _, k in blocks]
if action == "add":
    if kid in kids: sys.exit(f"이미 있는 kid: {kid}")
    pem = open(f"{d}/key.pem").read().strip().splitlines()
    body += f'  "{kid}": |\n' + "".join(f"    {l}\n" for l in pem)
elif action == "remove":
    if kid not in kids: sys.exit(f"없는 kid: {kid}")
    if len(kids) == 1: sys.exit("마지막 키는 지울 수 없습니다")
    body = "".join(b for b, k in blocks if k != kid)
else:
    sys.exit("add 또는 remove")
open(p, "w").write(s[:m.start(1)] + body + s[m.end(1):])
print("vault의 키 목록:", [k for _, k in re.findall(r'(  "([^"]+)": \|\n(?:    .*\n)+)', body)])
PY
ansible-vault encrypt "$tmp/vault.yml" --output group_vars/all/vault.yml
ansible-playbook auth.yml | grep -E "^ok=|changed=|failed=" | tail -1 || true
echo "Secret auth-jwt-keys 반영 끝. 다음: deployment.yaml의 platform-infra/jwt-keys 어노테이션을 바꿔 push"
