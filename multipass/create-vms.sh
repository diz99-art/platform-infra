#!/usr/bin/env bash
# vms.conf에 적힌 VM을 만든다. 이미 있는 VM은 건너뛰므로 여러 번 실행해도 안전하다.
# 마지막에 update-hosts.sh를 불러 ssh 별칭과 /etc/hosts를 맞춘다.
set -euo pipefail
source "$(dirname "$0")/common.sh"

require_multipass

if [[ ! -f "$SSH_KEY.pub" ]]; then
  echo "SSH 키가 없어 새로 만듭니다: $SSH_KEY"
  mkdir -p "$HOME/.ssh" && chmod 700 "$HOME/.ssh"
  ssh-keygen -t ed25519 -N "" -C "platform-infra" -f "$SSH_KEY"
fi

# cloud-init.yaml의 자리표시자를 실제 공개키로 바꾼 임시 파일을 만든다.
# 공개키 문자열에 '/'가 들어 있으므로 sed 구분자로 '|'를 쓴다.
rendered="$(mktemp -t cloud-init)"
trap 'rm -f "$rendered"' EXIT
sed "s|__SSH_PUBLIC_KEY__|$(cat "$SSH_KEY.pub")|" "$SCRIPT_DIR/cloud-init.yaml" > "$rendered"

# vms.conf를 먼저 배열로 읽어둔다. while read 루프 안에서 multipass를 부르면
# multipass가 루프의 입력(vms.conf)을 먹어버릴 수 있기 때문이다.
vm_lines=()
while read -r line; do vm_lines+=("$line"); done < <(grep -vE '^\s*(#|$)' "$VMS_CONF")

for line in "${vm_lines[@]}"; do
  read -r name cpus mem disk <<< "$line"
  if multipass info "$name" >/dev/null 2>&1; then
    echo "[$name] 이미 있어 건너뜁니다."
    continue
  fi
  echo "[$name] 만드는 중... (CPU $cpus, 메모리 $mem, 디스크 $disk)"
  # launch는 cloud-init이 끝날 때까지("Waiting for initialization to complete") 기다린다.
  # (multipass exec로 'cloud-init status --wait'를 따로 부르면 터미널이 없을 때 끝나지 않는 문제가 있어 쓰지 않는다)
  multipass launch "$UBUNTU_RELEASE" \
    --name "$name" --cpus "$cpus" --memory "$mem" --disk "$disk" \
    --cloud-init "$rendered" --timeout 900
  echo "[$name] 완료: $(vm_ip "$name")"
done

"$SCRIPT_DIR/update-hosts.sh"

echo
multipass list
