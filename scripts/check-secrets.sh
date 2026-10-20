#!/usr/bin/env bash
# 커밋 직전에 비밀이 평문으로 들어가는지 검사한다. .git/hooks/pre-commit 에서 부른다.
#   설치: ln -sf ../../scripts/check-secrets.sh .git/hooks/pre-commit
# 걸리면 커밋을 멈춘다. 우회(--no-verify)하지 말고 원인을 고친다.
set -euo pipefail

fail=0
staged=$(git diff --cached --name-only --diff-filter=ACM)

for f in $staged; do
  # 1) vault 파일은 반드시 암호화된 상태여야 한다
  if [[ "$(basename "$f")" == vault*.yml ]]; then
    if ! git show ":$f" | head -1 | grep -q '^\$ANSIBLE_VAULT;'; then
      echo "평문 vault 파일: $f  → ansible-vault encrypt $f" >&2
      fail=1
    fi
  fi
  # 2) Vault 비밀번호 파일
  if [[ "$(basename "$f")" == ".vault-pass" ]]; then
    echo "Vault 비밀번호 파일은 올리면 안 됩니다: $f" >&2
    fail=1
  fi
done

# 3) 쿠버네티스 Secret 매니페스트 (kubectl apply 용 YAML)
#    ansible/ 안은 제외: 롤이 vault 변수("{{ ... }}")로 Secret을 만드는 작업 정의라 값이 들어 있지 않다
if git diff --cached -U0 -- '*.yaml' '*.yml' ':(exclude)ansible/**' | grep -E '^\+\s*kind:\s*Secret' >/dev/null; then
  echo "kind: Secret 매니페스트가 커밋에 있습니다. Secret은 Ansible이 vault 값으로 만듭니다." >&2
  fail=1
fi

# 4) 개인키, k3s 조인 토큰
if git diff --cached -U0 | grep -E '^\+.*(BEGIN [A-Z ]*PRIVATE KEY|K10[0-9a-f]{20,})' >/dev/null; then
  echo "개인키나 k3s 토큰으로 보이는 값이 있습니다." >&2
  fail=1
fi

exit $fail
