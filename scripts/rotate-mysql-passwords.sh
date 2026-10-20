#!/usr/bin/env bash
# MySQL 서비스 계정(coupon, auth, notification) 비밀번호를 새로 만들어 vault → MySQL 계정 → Secret에 반영한다.
# 비밀번호가 새었을 때 쓴다. 새 값은 화면·파일에 남지 않는다. 맥의 터미널이나 `! scripts/...`로 직접 실행한다.
#   사용: scripts/rotate-mysql-passwords.sh
# 바꾼 뒤 앱 파드는 옛 비밀번호(env)를 들고 있다. 이미 열린 연결은 계속 쓰지만 새 연결은 실패하므로,
# 바로 k8s/apps/<앱>/deployment.yaml의 platform-infra/secret-rev 어노테이션을 올려 push한다 → 파드가 새 Secret으로 다시 뜬다
set -euo pipefail
cd "$(dirname "$0")/../ansible"
tmp="$(mktemp)"; trap 'rm -f "$tmp"' EXIT; chmod 600 "$tmp"
ansible-vault decrypt group_vars/all/vault.yml --output "$tmp"
python3 - "$tmp" <<'PY'
import re, sys, secrets, string
p = sys.argv[1]; s = open(p).read()
alpha = string.ascii_letters + string.digits
m = re.search(r"^vault_mysql_service_passwords:\n((?:  .*\n)+)", s, re.M)
names = [l.split(":")[0].strip() for l in m.group(1).splitlines()]
keep = [n for n in names if n != "file"]   # file DB는 6단계에서 없앴다 → 항목도 지운다
block = "".join(f"  {n}: {''.join(secrets.choice(alpha) for _ in range(32))}\n" for n in keep)
open(p, "w").write(s[:m.start(1)] + block + s[m.end(1):])
print("새 비밀번호를 만든 계정:", keep, "/ 지운 항목:", sorted(set(names) - set(keep)))
PY
ansible-vault encrypt "$tmp" --output group_vars/all/vault.yml
# update_password: always → ALTER USER. 이어서 apps 네임스페이스의 mysql-<서비스> Secret도 새 값으로
ansible-playbook mysql.yml -e mysql_rotate_passwords=true | grep -E "ok=.*changed=" | tail -1
echo "MySQL 계정·Secret 반영 끝. 다음: 앱 파드 다시 띄우기 (secret-rev 어노테이션 push)"
