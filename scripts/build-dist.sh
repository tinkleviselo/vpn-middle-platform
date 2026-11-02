#!/usr/bin/env bash
# 构建发布包: vpn.zip(节点) / central.zip(中台)
#   ./scripts/build-dist.sh            产物落在 dist-out/
#   中台分发用的 dist/vpn.zip 会自动带上
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
out="$root/dist-out"
rm -rf "$out" && mkdir -p "$out"

stage="$(mktemp -d)"
trap 'rm -rf "$stage"' EXIT

# 节点包: 脚本 + 测试 + 关键文档
mkdir -p "$stage/node/docs"
for p in vpnx.sh lib tools tests; do cp -a "$root/$p" "$stage/node/"; done
cp -a "$root/docs/QUICKSTART.md" "$stage/node/docs/" 2>/dev/null || true
( cd "$stage/node" && zip -qr "$out/vpn.zip" . )

# 中台包: 整个 central/ (自带 dist/vpn.zip)
mkdir -p "$root/central/dist"
cp -f "$out/vpn.zip" "$root/central/dist/vpn.zip"
( cd "$root" && zip -qr "$out/central.zip" central )

echo "== 产物 =="
for f in "$out/vpn.zip" "$out/central.zip"; do
  printf '%s  %s bytes  sha256=%s\n' "$(basename "$f")" "$(stat -c%s "$f")" "$(sha256sum "$f" | cut -d' ' -f1)"
done