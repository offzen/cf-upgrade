#!/bin/sh
unset DOCKER_HOST DOCKER_TLS_VERIFY DOCKER_CERT_PATH
dockerd --host=unix:///var/run/docker.sock >/var/log/dockerd.log 2>&1 &
i=0; while [ $i -lt 60 ]; do docker info >/dev/null 2>&1 && break; i=$((i+1)); sleep 2; done
docker info >/dev/null 2>&1 || exit 1
docker run -d --name reg -p 5000:5000 registry:2 >/dev/null; sleep 3
docker pull -q alpine:3.20 >/dev/null
make_img() {
  docker run -d --name bld alpine:3.20 sleep 300 >/dev/null
  docker cp "$2" bld:/usr/local/bin/cloudflared >/dev/null
  docker exec bld chmod +x /usr/local/bin/cloudflared
  docker commit --change 'ENTRYPOINT ["sleep"]' --change 'CMD ["infinity"]' bld "localhost:5000/cloudflared:$1" >/dev/null
  docker rm -f bld >/dev/null; docker push -q "localhost:5000/cloudflared:$1" >/dev/null
}
make_img 2025.2.1 /t/cf-2025.2.1
make_img 2025.5.0 /t/cf-2025.5.0
PASS=0; FAIL=0
chk() { if [ "$2" = "$3" ]; then echo "  [PASS] $1 = $2"; PASS=$((PASS+1)); else echo "  [FAIL] $1 = '$2' 期望 '$3'"; FAIL=$((FAIL+1)); fi; }

echo "### T3b compose tag=2025.2.1 固定，未加 --allow-retag，目标 2025.5.0"
mkdir -p /opt/s4 && cd /opt/s4
cat > docker-compose.yml <<'YML'
services:
  cloudflared:
    image: localhost:5000/cloudflared:2025.2.1
    container_name: s4-cf-1
    restart: unless-stopped
    entrypoint: ["sleep"]
    command: ["infinity"]
YML
docker compose up -d >/dev/null 2>&1; sleep 2
echo "  旧版本: $(docker exec s4-cf-1 cloudflared version)"
/t/cloudflared-upgrade.sh --only container --version 2025.5.0 >/tmp/x.log 2>&1; rc=$?
chk "退出码" "$rc" "0"
chk "SKIPPED 行" "$(grep -c 'SKIPPED' /tmp/x.log)" "1"
chk "未重建" "$(docker exec s4-cf-1 cloudflared version 2>/dev/null | grep -o '2025\.[0-9.]*' | head -1)" "2025.2.1"

echo ""
echo "### T3c 同容器加 --allow-retag → 应升级"
/t/cloudflared-upgrade.sh --only container --version 2025.5.0 --allow-retag >/tmp/y.log 2>&1; rc=$?
chk "退出码" "$rc" "0"
chk "已升级" "$(docker exec s4-cf-1 cloudflared version 2>/dev/null | grep -o '2025\.[0-9.]*' | head -1)" "2025.5.0"
chk "跳过 pull" "$(grep -c '跳过 compose pull' /tmp/y.log)" "1"
chk "状态 running" "$(docker inspect -f '{{.State.Status}}' s4-cf-1)" "running"
grep -E 'container:' /tmp/x.log /tmp/y.log
echo "============ PASS=$PASS FAIL=$FAIL ============"
