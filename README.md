# cloudflared-upgrade.sh

在 Alpine / Debian 11 / 12 / 13 上自动检测并升级 **cloudflared**（Cloudflare Tunnel 守护进程），
覆盖「宿主二进制」与「Docker 容器」两类安装形态，升级后回读版本并输出新旧版本对比表。

纯 POSIX `sh`，无 bash / jq / python 依赖，Alpine 的 `ash` 与 Debian 的 `dash` 均可直接运行。

---

## 直接运行（无需 clone）

在目标机上执行下面这一行即可。它会自动选用 `curl` 或 `wget` 下载脚本（Alpine 默认只有 busybox `wget`，Debian 最小镜像两者皆无），然后以 `--dry-run` 先给出计划：

```sh
URL=https://raw.githubusercontent.com/offzen/cf-upgrade/main/cloudflared-upgrade.sh; F=/tmp/cfu.sh; \
if command -v curl >/dev/null 2>&1; then curl -fsSL "$URL" -o "$F"; \
elif command -v wget >/dev/null 2>&1; then wget -qO "$F" "$URL"; \
else echo "需要 curl 或 wget：apt-get install -y curl  或  apk add curl" >&2; exit 1; fi; \
sh "$F" --dry-run
```

确认计划无误后，去掉 `--dry-run` 再跑一次即真正执行：

```sh
URL=https://raw.githubusercontent.com/offzen/cf-upgrade/main/cloudflared-upgrade.sh; F=/tmp/cfu.sh; \
if command -v curl >/dev/null 2>&1; then curl -fsSL "$URL" -o "$F"; \
elif command -v wget >/dev/null 2>&1; then wget -qO "$F" "$URL"; \
else echo "需要 curl 或 wget：apt-get install -y curl  或  apk add curl" >&2; exit 1; fi; \
sh "$F"
```

> 提示：极简 Debian 镜像可能既无 `curl` 也无 `wget`，先 `apt-get install -y curl`。
> 需要锁定版本时在命令末尾加 `--version 2026.10.3`。

## 用途

1. **检测**本机所有 cloudflared：
   - 宿主二进制：PATH 上的、常见路径，以及从 `/proc/*/exe` 反查（不在 PATH 上也能找到）；
   - Docker 容器：遍历所有容器（含已停止），按镜像名 / entrypoint / cmd 含 `cloudflared` 判定。
2. **升级**到指定版本（默认 GitHub 最新稳定版），按安装方式分流处理。
3. **验证**：升级后回读真实版本号（不只信命令返回码），并重启对应服务。
4. **报告**：输出「组件 | 旧版本 | 新版本 | 结果 | 说明」对比表，退出码表达整体成败。

## 特点

- **按安装方式精准升级**：

  | 安装形态 | 处理方式 |
  | --- | --- |
  | dpkg 包（Debian） | 下载官方 `.deb` 用 `dpkg -i`，保持包元数据一致；失败回退静态二进制 |
  | apk 包（Alpine） | 仓库版本够新就用 `apk upgrade`；否则替换为官方静态二进制 |
  | 裸二进制 | 先试 `cloudflared update --version`（原地写入、保留路径与权限）；失败回退下载 |
  | compose 容器 | 从 label 还原 `-f / -p / --project-directory`，`pull` + `up -d --force-recreate --no-deps` |
  | 非 compose 容器 | 先备份 `inspect` JSON，再逐项还原 env/user/workdir/entrypoint/cmd/ports/binds/cap/security-opt/network 重建；失败自动回滚旧容器 |

- **尊重原状态（关键安全设计）**：
  - 升级前**未 active** 的 systemd / OpenRC 服务**不会**被误启动（`systemctl restart` 对 inactive 单元等于启动，已规避）；
  - 升级前**未 running** 的容器，重建后会停回原 `exited` 状态，绝不擅自把隧道拉上线。

- **升级后回读验证**：二进制读 `--version`，容器读 `docker exec` 或一次性 `docker run --network none`。

- **幂等**：已是最新时全部 `SKIP`，退出码 0，可安全反复执行。

## 用法

```sh
./cloudflared-upgrade.sh                 # 升级到 GitHub 最新稳定版
./cloudflared-upgrade.sh --dry-run       # 只检测并打印计划，不做任何修改
./cloudflared-upgrade.sh --version 2026.10.3   # 锁定到指定版本
./cloudflared-upgrade.sh --only host     # 只处理宿主二进制
./cloudflared-upgrade.sh --only container --pull-only   # 容器只拉镜像，不重建
./cloudflared-upgrade.sh --no-restart    # 只替换二进制，不重启服务
./cloudflared-upgrade.sh --restart-bare  # 对无服务管理器托管的裸进程也重启
./cloudflared-upgrade.sh --keep-old      # 重建后保留旧容器（改名 <name>.bak-<时间戳>）
```

环境变量：

| 变量 | 作用 |
| --- | --- |
| `CF_TARGET_VERSION` | 等价 `--version` |
| `CF_BACKUP_DIR` | 备份目录，默认 `/var/backups/cloudflared-upgrade` |
| `GITHUB_TOKEN` | 可选，提高 GitHub API 速率上限 |

退出码：`0` 成功或无需处理；`1` 有失败项；`2` 用法错误；`3` 未检测到 cloudflared。

## 局限（边界）

1. **平台范围**：官方验证范围 = Alpine + Debian 11/12/13。其它发行版会打 WARN 按通用路径继续，不保证。
2. **架构**：仅 `amd64 / arm64 / armhf / arm / 386` 有官方静态二进制；未识别架构会告警且下载可能失败。
3. **版本来源**：默认取 GitHub 最新稳定版，依赖能访问 `github.com`（含 API 限流，可用 `--version` 或 `GITHUB_TOKEN` 规避）。
4. **Alpine 的 apk 仓库**：3.18–3.23 均无 cloudflared 包（仅 edge 有）。故 Alpine 上基本走「替换为官方静态二进制」，`apk info` 仍显示旧版本号——脚本会打 WARN，实际执行的是新二进制。
5. **compose 镜像 tag 固定**：若 compose 里镜像 tag 是具体版本（非 `latest`），`pull` 不会生效。脚本默认报 `SKIPPED` 并提示改 compose，或加 `--allow-retag` 本地重打标签强推。
6. **非 compose 容器**：按 `docker inspect` 还原参数重建，尽力保真但非 100% 覆盖所有边缘选项（如极少用到的 `--userns` / `--ipc` / `--ulimit` 未逐项还原）；关键项（env/挂载/端口/cap/security-opt/网络）已覆盖，且每次重建前会先备份 `inspect` JSON 以便回滚。
7. **裸进程重启**：默认**不**自动重启无服务管理器托管的裸进程（只告警），需显式加 `--restart-bare`。
8. **中断容忍**：对正在 running 的容器，`up -d --force-recreate` 会使其对外隧道**闪断几秒**。无中断诉求时用 `--pull-only` 或 `--no-restart`。

---

## 校验

下载后可核对完整性（与发布时一致）：

```sh
sha256sum /tmp/cfu.sh
# 771039434dc97f7c599c5a2c617424f5d0e10e7d6aed3c1c4a487089eb70cef6
```

## 仓库

本仓是公开发布快照。开发与去敏镜像存放在内部私有 Gitea 实例（不对外公开）。
如需报告问题或提交改进，请在本仓开 issue；维护者会同步回私有源仓后重新发布。

> 修 bug 请勿直接在本仓提交 PR 后等待合并——本仓由发布流水线单向派生，
> 直接在内部源仓修改才会被保留。

---

**声明**：本脚本为运维辅助工具。执行前请先 `--dry-run` 查看计划；对生产隧道升级请评估中断影响并做好回滚准备。