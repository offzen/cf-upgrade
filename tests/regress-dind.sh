#!/bin/sh
unset DOCKER_HOST DOCKER_TLS_VERIFY DOCKER_CERT_PATH
dockerd --host=unix:///var/run/docker.sock >/var/log/dockerd.log 2>&1 &
i=0; while [ $i -lt 60 ]; do docker info >/dev/null 2>&1 && break; i=$((i+1)); sleep 2; done
docker info >/dev/null 2>&1 || exit 1
echo "被测脚本 sha256=$(sha256sum /t/cloudflared-upgrade.sh | cut -c1-16)"
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
make_img 2026.10.3 /t/cf-2026.10.3
PASS=0; FAIL=0
chk() { if [ "$2" = "$3" ]; then echo "  [PASS] $1 = $2"; PASS=$((PASS+1)); else echo "  [FAIL] $1 = '$2' 期望 '$3'"; FAIL=$((FAIL+1)); fi; }

echo ""; echo "### T1 非 compose 保真性"
docker run -d --name t1 --restart unless-stopped -e TUNNEL_TOKEN=dummy -e X=1 \
  -p 18080:8080 -v /tmp/cfdata:/data --entrypoint sleep \
  localhost:5000/cloudflared:2025.2.1 infinity >/dev/null; sleep 2
/t/cloudflared-upgrade.sh --only container --version 2025.5.0 >/tmp/t1.log 2>&1; rc=$?
chk "退出码" "$rc" "0"
chk "版本" "$(docker exec t1 cloudflared version 2>/dev/null | grep -o '2025\.[0-9.]*' | head -1)" "2025.5.0"
chk "端口" "$(docker inspect -f '{{json .HostConfig.PortBindings}}' t1)" '{"8080/tcp":[{"HostIp":"","HostPort":"18080"}]}'
chk "卷" "$(docker inspect -f '{{json .HostConfig.Binds}}' t1)" '["/tmp/cfdata:/data"]'
chk "重启策略" "$(docker inspect -f '{{.HostConfig.RestartPolicy.Name}}' t1)" "unless-stopped"
chk "状态" "$(docker inspect -f '{{.State.Status}}' t1)" "running"
chk "env X=1" "$(docker inspect -f '{{json .Config.Env}}' t1 | grep -c 'X=1')" "1"
chk "bak 残留" "$(docker ps -aq -f 'name=t1.bak-' | wc -l)" "0"

echo ""; echo "### T2 --keep-old"
/t/cloudflared-upgrade.sh --only container --version 2026.10.3 --keep-old >/tmp/t2.log 2>&1; rc=$?
chk "退出码" "$rc" "0"
chk "版本" "$(docker exec t1 cloudflared version 2>/dev/null | grep -o '2026\.[0-9.]*' | head -1)" "2026.10.3"
chk "旧容器保留" "$(docker ps -aq -f 'name=t1.bak-' | wc -l)" "1"

echo ""; echo "### T2b 备份容器不被当生产容器"
/t/cloudflared-upgrade.sh --only container --version 2026.10.3 >/tmp/t2b.log 2>&1; rc=$?
chk "退出码" "$rc" "0"
chk "跳过备份容器" "$(grep -c '跳过备份容器' /tmp/t2b.log)" "1"
chk "无 FAIL" "$(grep -c 'FAIL' /tmp/t2b.log)" "0"

echo ""; echo "### T3 compose --allow-retag"
mkdir -p /opt/stack && cd /opt/stack
cat > docker-compose.yml <<'YML'
services:
  cloudflared:
    image: localhost:5000/cloudflared:2025.2.1
    container_name: stack-cf-1
    restart: unless-stopped
    entrypoint: ["sleep"]
    command: ["infinity"]
YML
docker compose up -d >/dev/null 2>&1; sleep 2
/t/cloudflared-upgrade.sh --only container --version 2025.5.0 --allow-retag >/tmp/t3.log 2>&1; rc=$?
chk "退出码" "$rc" "0"
chk "版本" "$(docker exec stack-cf-1 cloudflared version 2>/dev/null | grep -o '2025\.[0-9.]*' | head -1)" "2025.5.0"
chk "跳过 pull" "$(grep -c '跳过 compose pull' /tmp/t3.log)" "1"
chk "状态" "$(docker inspect -f '{{.State.Status}}' stack-cf-1)" "running"

echo ""; echo "### T3b compose tag 固定未加 --allow-retag → SKIPPED，退出码 0"
docker compose down >/dev/null 2>&1
sed -i 's|2025.2.1|2025.2.1|' docker-compose.yml
docker compose up -d >/dev/null 2>&1; sleep 2
/t/cloudflared-upgrade.sh --only container --version 2025.5.0 >/tmp/t3b.log 2>&1; rc=$?
chk "退出码" "$rc" "0"
chk "SKIPPED 行" "$(grep -c 'SKIPPED' /tmp/t3b.log)" "1"
chk "未重建(版本仍旧)" "$(docker exec stack-cf-1 cloudflared version 2>/dev/null | grep -o '2025\.[0-9.]*' | head -1)" "2025.2.1"

echo ""; echo "### T4 幂等（t1 已是 2026.10.3，应 SKIP）"
/t/cloudflared-upgrade.sh --only container --version 2026.10.3 >/tmp/t4.log 2>&1
chk "t1 SKIP" "$(grep -c 'container:t1 .*SKIP' /tmp/t4.log)" "1"

echo ""; echo "### T5 tag 不存在回退 latest"
docker tag localhost:5000/cloudflared:2025.5.0 localhost:5000/cloudflared:latest
docker push -q localhost:5000/cloudflared:latest >/dev/null
/t/cloudflared-upgrade.sh --only container --version 9999.9.9 >/tmp/t5.log 2>&1
chk "回退警告" "$(grep -c '回退到 localhost:5000/cloudflared:latest' /tmp/t5.log)" "2"

echo ""; echo "### T6 宿主二进制"
cp /t/cf-2025.2.1 /usr/local/bin/cloudflared; chmod +x /usr/local/bin/cloudflared
/t/cloudflared-upgrade.sh --only host --version 2025.5.0 >/tmp/t6.log 2>&1; rc=$?
chk "退出码" "$rc" "0"
chk "版本" "$(cloudflared version 2>/dev/null | grep -o '2025\.[0-9.]*' | head -1)" "2025.5.0"
chk "备份文件" "$(ls /usr/local/bin/cloudflared.bak-* 2>/dev/null | wc -l)" "1"

echo ""; echo "### T7 dry-run 零副作用"
b1=$(docker inspect -f '{{.State.StartedAt}}' t1)
cp /t/cf-2025.2.1 /usr/local/bin/cloudflared; chmod +x /usr/local/bin/cloudflared
/t/cloudflared-upgrade.sh --dry-run --version 2025.5.0 >/tmp/t7.log 2>&1
chk "宿主未变" "$(cloudflared version 2>/dev/null | grep -o '2025\.[0-9.]*' | head -1)" "2025.2.1"
chk "容器未重启" "$(docker inspect -f '{{.State.StartedAt}}' t1)" "$b1"

echo ""; echo "### T8 退出码契约"
/t/cloudflared-upgrade.sh --bogus >/dev/null 2>&1; chk "--bogus=2" "$?" "2"
/t/cloudflared-upgrade.sh --version >/dev/null 2>&1; chk "缺参=2" "$?" "2"
/t/cloudflared-upgrade.sh --only foo >/dev/null 2>&1; chk "--only非法=2" "$?" "2"
docker rm -f $(docker ps -aq -f 'name=t1') $(docker ps -aq -f 'name=t1.bak-') $(docker ps -aq -f 'name=stack-cf-1') >/dev/null 2>&1
rm -f /usr/local/bin/cloudflared
/t/cloudflared-upgrade.sh --only host >/dev/null 2>&1; chk "无cloudflared=3" "$?" "3"

echo ""; echo "============ PASS=$PASS FAIL=$FAIL ============"
[ "$FAIL" -eq 0 ] && echo ALL_PASS || echo HAS_FAIL
