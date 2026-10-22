# 回归测试

三个脚本都需要 `docker`。**全部在隔离容器内执行，不触碰宿主的生产服务与配置。**

| 脚本 | 覆盖 | 运行 |
|---|---|---|
| `regress-dind.sh` | 容器分支全量：非 compose 保真性（端口/卷/env/重启策略）、`--keep-old`、备份容器跳过、compose `--allow-retag`、compose tag 固定 SKIPPED、幂等、tag 缺失回退 latest、宿主二进制、dry-run 零副作用、退出码契约 | `docker run --rm --privileged -v $PWD:/t:ro docker:27-dind sh /t/tests/regress-dind.sh` |
| `regress-compose.sh` | compose 分支专项：tag 固定 → SKIPPED；加 `--allow-retag` → 升级且跳过 `compose pull` | `docker run --rm --privileged -v $PWD:/t:ro docker:27-dind sh /t/tests/regress-compose.sh` |
| `regress-distro.sh` | 宿主二进制在指定发行版上的升级 + 幂等 + dry-run | `docker run --rm -v $PWD:/t:ro alpine:3.20 sh /t/tests/regress-distro.sh alpine`<br>`docker run --rm -v $PWD:/t:ro debian:12 sh /t/tests/regress-distro.sh debian` |

## 前置数据

`regress-dind.sh` / `regress-compose.sh` 需要把真实 cloudflared 二进制放在 `/t/` 下：

```sh
for v in 2025.2.1 2025.5.0 2026.10.3; do
  curl -sSL -o cf-$v https://github.com/cloudflare/cloudflared/releases/download/$v/cloudflared-linux-amd64
  chmod +x cf-$v
done
```

用真实二进制而非伪造版本号，是因为脚本会用 `<二进制> version` 回读实际版本：
tag 写 2025.5.1 但二进制是 2025.5.0 时，脚本会正确判定「已是最新」并 SKIP。

## 已修复的缺陷（回归用例对应）

1. **端口解析**：`{{println $p "|" .HostIp "|" .HostPort}}` 会插入空格，`HostIp` 为空时得到
   `8080/tcp |  | 18080`，解析出 `hip="  "` 非空 → `-p "  : 18080:8080/tcp"` → `invalid IP address`。
   改用 `printf "%s|%s|%s"` 并对字段二次裁剪。→ T1 端口保真
2. **compose `--allow-retag` 被 `compose pull` 覆盖**：retag 后又 pull，把旧 tag 从仓库拉回旧内容，
   重建后仍是旧版本。改为 retag 后跳过 pull。→ T3 / regress-compose
3. **备份容器被当生产容器**：`--keep-old` 留下的 `<name>.bak-<ts>` 在下次运行时被识别为待升级容器，
   必然失败并产生假 FAIL。改为按名字模式识别并跳过。→ T2b
