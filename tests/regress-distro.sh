#!/bin/sh
# 两个发行版各自跑宿主二进制升级 + 幂等 + dry-run
DISTRO="$1"
case "$DISTRO" in
  alpine) apk add -q --no-progress curl ca-certificates >/dev/null 2>&1 ;;
  debian) apt-get update -qq >/dev/null 2>&1; apt-get install -y -qq curl ca-certificates >/dev/null 2>&1 ;;
esac
curl -sSL --max-time 90 -o /usr/local/bin/cloudflared \
  https://github.com/cloudflare/cloudflared/releases/download/2025.2.1/cloudflared-linux-amd64
chmod +x /usr/local/bin/cloudflared
echo "  shell=$(readlink -f /bin/sh)  旧=$(cloudflared version)"
PASS=0; FAIL=0
chk() { if [ "$2" = "$3" ]; then echo "  [PASS] $1 = $2"; PASS=$((PASS+1)); else echo "  [FAIL] $1 = '$2' 期望 '$3'"; FAIL=$((FAIL+1)); fi; }
/t/cloudflared-upgrade.sh --dry-run --only host --version 2025.5.0 >/tmp/d1.log 2>&1
chk "dry-run 未改" "$(cloudflared version 2>/dev/null | grep -o '2025\.[0-9.]*' | head -1)" "2025.2.1"
/t/cloudflared-upgrade.sh --only host --version 2025.5.0 >/tmp/d2.log 2>&1; rc=$?
chk "升级退出码" "$rc" "0"
chk "升级后版本" "$(cloudflared version 2>/dev/null | grep -o '2025\.[0-9.]*' | head -1)" "2025.5.0"
chk "备份文件" "$(ls /usr/local/bin/cloudflared.bak-* 2>/dev/null | wc -l)" "1"
/t/cloudflared-upgrade.sh --only host --version 2025.5.0 >/tmp/d3.log 2>&1
chk "幂等 SKIP" "$(grep -c 'SKIP' /tmp/d3.log)" "1"
chk "幂等退出码" "$?" "0"
echo "  ---- $DISTRO: PASS=$PASS FAIL=$FAIL ----"
