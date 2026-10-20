#!/usr/bin/env bash
# 지금 VM IP를 읽어서 두 곳을 다시 쓴다. IP가 바뀌었을 때 이것만 실행하면 된다.
#   1) 맥: ~/.ssh/config.d/platform-infra  → ssh cp1 처럼 별칭으로 접속
#   2) 각 VM: /etc/hosts의 platform-infra 구간 → VM끼리 ping worker1 처럼 이름으로 통신
set -euo pipefail
source "$(dirname "$0")/common.sh"

require_multipass

BEGIN_MARK="# >>> platform-infra (update-hosts.sh가 관리) >>>"
END_MARK="# <<< platform-infra <<<"

hosts_block="$BEGIN_MARK"$'\n'
ssh_entries=""
running=()

for name in $(vm_names); do
  ip="$(vm_ip "$name")"
  if [[ -z "$ip" || "$ip" == "--" ]]; then
    echo "[$name] 꺼져 있거나 IP가 없어 건너뜁니다."
    continue
  fi
  echo "[$name] $ip"
  running+=("$name")
  hosts_block+="$ip $name"$'\n'
  # HostKeyAlias: VM의 호스트 키를 IP가 아니라 이름으로 기억한다.
  #   → IP가 바뀌어도 "호스트 키가 달라졌다"는 경고가 나지 않는다.
  ssh_entries+="Host $name
  HostName $ip
  User ubuntu
  IdentityFile $SSH_KEY
  IdentitiesOnly yes
  HostKeyAlias $name
  UserKnownHostsFile $SSH_KNOWN_HOSTS
  StrictHostKeyChecking accept-new

"
done
hosts_block+="$END_MARK"

# 1) 맥의 ssh 설정
mkdir -p "$(dirname "$SSH_INCLUDE_FILE")"
{
  echo "# update-hosts.sh가 만든 파일. 직접 고치지 말고 스크립트를 다시 실행하세요."
  echo
  printf '%s' "$ssh_entries"
} > "$SSH_INCLUDE_FILE"
chmod 600 "$SSH_INCLUDE_FILE"

# ~/.ssh/config 맨 위에 Include 한 줄을 넣는다 (Include는 다른 Host 설정보다 앞에 있어야 한다).
include_line="Include config.d/platform-infra"
touch "$HOME/.ssh/config" && chmod 600 "$HOME/.ssh/config"
if ! grep -qxF "$include_line" "$HOME/.ssh/config"; then
  { echo "$include_line"; echo; cat "$HOME/.ssh/config"; } > "$HOME/.ssh/config.tmp"
  mv "$HOME/.ssh/config.tmp" "$HOME/.ssh/config"
  echo "~/.ssh/config에 '$include_line'을 추가했습니다."
fi

# 2) 각 VM의 /etc/hosts: 예전 구간을 지우고 새 구간을 붙인다.
# 새 구간은 표준 입력(파이프)이 아니라 인자($1)로 넘긴다. multipass exec에 파이프로 넘기면 끝나지 않는 문제가 있다.
for name in "${running[@]}"; do
  multipass exec "$name" -- sudo bash -c '
    sed -i "/^# >>> platform-infra/,/^# <<< platform-infra/d" /etc/hosts
    printf "%s\n" "$1" >> /etc/hosts
  ' _ "$hosts_block"
done

echo "ssh 설정과 VM의 /etc/hosts를 갱신했습니다."
