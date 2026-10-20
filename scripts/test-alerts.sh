#!/usr/bin/env bash
# 알림 규칙 단위 테스트. vmalert-tool을 처음 한 번 내려받아 캐시해 두고 k8s/platform/monitoring/alerts-test.yml을 실행한다.
set -euo pipefail
VER=v1.154.0
DIR="$HOME/.cache/platform-infra/vmutils-$VER"
case "$(uname -s)-$(uname -m)" in
  Darwin-arm64) OS=darwin-arm64 ;; Darwin-x86_64) OS=darwin-amd64 ;; Linux-x86_64) OS=linux-amd64 ;; Linux-aarch64) OS=linux-arm64 ;;
  *) echo "지원하지 않는 OS"; exit 1 ;;
esac
if [[ ! -x "$DIR/vmalert-tool-prod" ]]; then
  mkdir -p "$DIR"
  curl -sSL "https://github.com/VictoriaMetrics/VictoriaMetrics/releases/download/$VER/vmutils-$OS-$VER.tar.gz" | tar -xz -C "$DIR" vmalert-tool-prod
fi
cd "$(dirname "$0")/../k8s/platform/monitoring"
"$DIR/vmalert-tool-prod" unittest --files alerts-test.yml
