# 스크립트들이 같이 쓰는 값과 함수. 직접 실행하지 않고 source 해서 쓴다.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VMS_CONF="$SCRIPT_DIR/vms.conf"
UBUNTU_RELEASE="24.04"

SSH_KEY="$HOME/.ssh/platform_ed25519"
SSH_INCLUDE_FILE="$HOME/.ssh/config.d/platform-infra"
SSH_KNOWN_HOSTS="$HOME/.ssh/known_hosts_platform"

# vms.conf에서 주석과 빈 줄을 뺀 VM 이름만 출력
vm_names() {
  grep -vE '^\s*(#|$)' "$VMS_CONF" | awk '{print $1}'
}

# VM의 IPv4 주소 (없으면 빈 문자열)
vm_ip() {
  multipass list --format csv | awk -F, -v n="$1" '$1 == n {print $3}'
}

require_multipass() {
  if ! command -v multipass >/dev/null 2>&1; then
    echo "multipass가 없습니다. 먼저 설치하세요: brew install --cask multipass" >&2
    exit 1
  fi
}
