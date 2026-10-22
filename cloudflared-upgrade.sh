#!/bin/sh
# cloudflared-upgrade.sh — 在 Alpine / Debian 11-13 上升级 cloudflared
#
# 检测并升级：
#   1) 宿主二进制（dpkg 包 / apk 包 / 裸二进制，含不在 PATH 上的情形）
#   2) Docker 容器（compose 管理的用 compose 重建；非 compose 的按 inspect 还原参数重建）
# 升级后回读版本验证，最后输出「组件 | 旧版本 | 新版本 | 结果 | 说明」。
#
# 只用 POSIX sh（Alpine 的 ash、Debian 的 dash 均可），不依赖 bash / jq / python。
#
# 退出码：0 成功或无需处理；1 有失败项；2 用法错误；3 未检测到 cloudflared。

set -u

SCRIPT_VERSION="1.0.0"
PROG=$(basename "$0")

TARGET_VERSION="${CF_TARGET_VERSION:-}"
DRY_RUN=0
PULL_ONLY=0
NO_RESTART=0
RESTART_BARE=0
ALLOW_RETAG=0
KEEP_OLD=0
ONLY=""
BACKUP_ROOT="${CF_BACKUP_DIR:-/var/backups/cloudflared-upgrade}"

FAILED=0
FOUND=0

# ------------------------------------------------------------------ 输出
say()  { printf '%s\n' "$*"; }
info() { printf '[INFO] %s\n' "$*"; }
ok()   { printf '[ OK ] %s\n' "$*"; }
warn() { printf '[WARN] %s\n' "$*" >&2; }
err()  { printf '[FAIL] %s\n' "$*" >&2; FAILED=$((FAILED + 1)); }
have() { command -v "$1" >/dev/null 2>&1; }

usage() {
	cat <<EOF
$PROG $SCRIPT_VERSION — cloudflared 自动升级（Alpine / Debian 11-13）

用法: $PROG [选项]

选项:
  --version VER       升级到指定版本（如 2026.10.3）；默认取 GitHub 最新稳定版
  --dry-run           只检测并打印将要执行的动作，不做任何修改
  --pull-only         容器只拉取新镜像，不重建容器
  --no-restart        只替换二进制，不重启 systemd / OpenRC 服务
  --restart-bare      对没有服务管理器托管的裸进程也重启（默认只告警）
  --allow-retag       compose 里镜像 tag 固定为具体版本时，拉新镜像后本地 retag
  --keep-old          重建容器后保留旧容器（改名为 <name>.bak-<时间戳>）
  --only host|container   只处理宿主二进制 / 只处理容器
  -h, --help          显示本帮助

环境变量:
  CF_TARGET_VERSION   同 --version
  CF_BACKUP_DIR       备份目录，默认 $BACKUP_ROOT
  GITHUB_TOKEN        可选，提高 GitHub API 速率上限

示例:
  $PROG --dry-run
  $PROG --version 2026.10.3
  $PROG --only container --pull-only
EOF
}

while [ $# -gt 0 ]; do
	case "$1" in
		--version)      [ $# -ge 2 ] || { say "--version 需要参数" >&2; exit 2; }; TARGET_VERSION="$2"; shift 2 ;;
		--version=*)    TARGET_VERSION="${1#*=}"; shift ;;
		--dry-run)      DRY_RUN=1; shift ;;
		--yes|-y)       shift ;;
		--pull-only)    PULL_ONLY=1; shift ;;
		--no-restart)   NO_RESTART=1; shift ;;
		--restart-bare) RESTART_BARE=1; shift ;;
		--allow-retag)  ALLOW_RETAG=1; shift ;;
		--keep-old)     KEEP_OLD=1; shift ;;
		--only)         [ $# -ge 2 ] || { say "--only 需要参数" >&2; exit 2; }; ONLY="$2"; shift 2 ;;
		--only=*)       ONLY="${1#*=}"; shift ;;
		-h|--help)      usage; exit 0 ;;
		*)              say "未知参数: $1" >&2; usage; exit 2 ;;
	esac
done

case "$ONLY" in ""|host|container) ;; *) say "--only 只能是 host 或 container" >&2; exit 2 ;; esac

TMPD=$(mktemp -d 2>/dev/null) || { say "无法创建临时目录" >&2; exit 1; }
RESULTS="$TMPD/results.tsv"
: > "$RESULTS"
trap 'rm -rf "$TMPD"' EXIT INT TERM

add_result() { # name old new status note
	printf '%s\t%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4" "$5" >> "$RESULTS"
}

# ------------------------------------------------------------------ 通用工具
fetch_to() { # url outfile
	if have curl; then curl -fsSL --max-time 600 -o "$2" "$1"
	elif have wget; then wget -q -O "$2" --timeout=600 "$1"
	else return 127; fi
}

http_get() { # url
	if have curl; then curl -fsSL --max-time 30 "$1"
	elif have wget; then wget -q -O - --timeout=30 "$1"
	else return 127; fi
}

http_final_url() { # url
	have curl || return 1
	curl -sIL --max-time 20 -o /dev/null -w '%{url_effective}' "$1" 2>/dev/null
}

ver_cmp() { # a b -> -1|0|1
	awk -v a="$1" -v b="$2" 'BEGIN{
		n=split(a,x,/[^0-9]+/); m=split(b,y,/[^0-9]+/);
		k=(n>m?n:m);
		for(i=1;i<=k;i++){
			ai=(i<=n?x[i]+0:0); bi=(i<=m?y[i]+0:0);
			if(ai<bi){print -1; exit}
			if(ai>bi){print 1; exit}
		}
		print 0
	}'
}

ver_ge() { [ "$(ver_cmp "$1" "$2")" -ge 0 ]; }

extract_version() { # 从文本抽出形如 2026.10.3 的版本
	printf '%s' "$1" | grep -oE '[0-9]{4}\.[0-9]{1,2}\.[0-9]{1,2}(-beta[0-9]*)?' | head -1
}

run() { # dry-run 时只打印
	if [ "$DRY_RUN" -eq 1 ]; then say "[dry-run] $*"; return 0; fi
	"$@"
}

ensure_dir() { [ -d "$1" ] && return 0; run mkdir -p "$1"; }

# ------------------------------------------------------------------ 环境探测
detect_os() {
	OS_ID="unknown"; OS_VER=""; OS_NAME="unknown"
	if [ -r /etc/os-release ]; then
		# shellcheck disable=SC1091
		. /etc/os-release 2>/dev/null || true
		OS_ID="${ID:-unknown}"
		OS_VER="${VERSION_ID:-}"
		OS_NAME="${PRETTY_NAME:-$OS_ID $OS_VER}"
	fi
	ARCH_RAW=$(uname -m 2>/dev/null || echo unknown)
	case "$ARCH_RAW" in
		x86_64|amd64)        CF_ARCH="amd64" ;;
		aarch64|arm64)       CF_ARCH="arm64" ;;
		armv7l|armv8l)       CF_ARCH="armhf" ;;
		armv6l)              CF_ARCH="arm" ;;
		i386|i486|i586|i686) CF_ARCH="386" ;;
		*)                   CF_ARCH="" ;;
	esac
}

check_distro_support() {
	case "$OS_ID" in
		alpine) : ;;
		debian)
			case "$OS_VER" in
				11|12|13) : ;;
				*) warn "Debian ${OS_VER:-?} 未经测试（目标为 11/12/13），按通用路径继续" ;;
			esac ;;
		*) warn "未识别的发行版 $OS_NAME，按通用路径继续（官方验证范围为 Alpine / Debian 11-13）" ;;
	esac
	[ -n "$CF_ARCH" ] || warn "未识别的架构 $ARCH_RAW，二进制下载可能失败"
}

# ------------------------------------------------------------------ 目标版本
resolve_target_version() {
	if [ -n "$TARGET_VERSION" ]; then
		TARGET_VERSION=$(extract_version "$TARGET_VERSION")
		[ -n "$TARGET_VERSION" ] || { err "无法解析 --version 参数"; return 1; }
		info "目标版本（手动指定）: $TARGET_VERSION"
		return 0
	fi
	info "查询 GitHub 最新稳定版 ..."
	body=""
	if [ -n "${GITHUB_TOKEN:-}" ] && have curl; then
		body=$(curl -fsSL --max-time 20 -H "Authorization: Bearer $GITHUB_TOKEN" \
			"https://api.github.com/repos/cloudflare/cloudflared/releases/latest" 2>/dev/null || true)
	fi
	[ -n "$body" ] || body=$(http_get "https://api.github.com/repos/cloudflare/cloudflared/releases/latest" 2>/dev/null || true)
	TARGET_VERSION=$(printf '%s' "$body" | grep -o '"tag_name"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1 | sed 's/.*"\([^"]*\)"$/\1/')
	if [ -z "$TARGET_VERSION" ]; then
		final=$(http_final_url "https://github.com/cloudflare/cloudflared/releases/latest" || true)
		case "$final" in */tag/*) TARGET_VERSION="${final##*/}" ;; esac
	fi
	TARGET_VERSION=$(extract_version "$TARGET_VERSION")
	if [ -z "$TARGET_VERSION" ]; then
		err "无法获取最新版本（网络受限？）请用 --version 指定目标版本"
		return 1
	fi
	info "目标版本: $TARGET_VERSION"
	return 0
}

# ------------------------------------------------------------------ 宿主二进制
find_binary() {
	p=$(command -v cloudflared 2>/dev/null || true)
	if [ -n "$p" ] && [ -x "$p" ]; then printf '%s\n' "$p"; return 0; fi
	for p in /usr/bin/cloudflared /usr/local/bin/cloudflared /opt/cloudflared/cloudflared /root/cloudflared /usr/sbin/cloudflared; do
		[ -x "$p" ] && { printf '%s\n' "$p"; return 0; }
	done
	for d in /proc/[0-9]*; do
		[ -r "$d/comm" ] || continue
		[ "$(cat "$d/comm" 2>/dev/null)" = "cloudflared" ] || continue
		exe=$(readlink "$d/exe" 2>/dev/null || true)
		exe=${exe% (deleted)}
		if [ -n "$exe" ] && [ -x "$exe" ]; then printf '%s\n' "$exe"; return 0; fi
	done
	return 1
}

real_path() {
	r=$(readlink -f "$1" 2>/dev/null || true)
	[ -n "$r" ] && { printf '%s\n' "$r"; return 0; }
	printf '%s\n' "$1"
}

binary_version() {
	[ -x "$1" ] || return 1
	out=$("$1" --version 2>/dev/null || true)
	[ -n "$out" ] || out=$("$1" version 2>/dev/null || true)
	extract_version "$out"
}

dpkg_owner() {
	have dpkg-query || return 0
	dpkg-query -S "$1" 2>/dev/null | head -1 | sed 's/:.*//' | grep -x 'cloudflared' || true
}

apk_has_pkg() { have apk && apk info -e cloudflared >/dev/null 2>&1; }

apk_repo_version() {
	apk info cloudflared 2>/dev/null | head -1 | sed 's/.*-\([0-9][0-9.]*\)-r[0-9]*$/\1/' || true
}

download_static_binary() { # version arch dest
	url="https://github.com/cloudflare/cloudflared/releases/download/$1/cloudflared-linux-$2"
	info "下载 $url"
	fetch_to "$url" "$3" || { err "下载失败: $url"; return 1; }
	chmod +x "$3" 2>/dev/null || true
	got=$(binary_version "$3")
	if [ "$got" != "$1" ]; then
		err "下载文件版本校验失败（得到 '${got:-空}'，期望 $1）"
		return 1
	fi
	return 0
}

replace_binary() { # realbin newfile
	bak="$1.bak-$(date +%Y%m%d-%H%M%S)"
	if [ "$DRY_RUN" -eq 1 ]; then say "[dry-run] cp -p $1 $bak && mv $2 $1"; return 0; fi
	cp -p "$1" "$bak" 2>/dev/null || { err "备份 $1 失败"; return 1; }
	if mv -f "$2" "$1" 2>/dev/null; then :; else
		cp -p "$2" "$1" || { err "替换 $1 失败"; return 1; }
		rm -f "$2" 2>/dev/null || true
	fi
	info "旧二进制已备份: $bak"
	return 0
}

upgrade_host_binary() {
	bin=$1
	real=$(real_path "$bin")
	old=$(binary_version "$bin")
	FOUND=$((FOUND + 1))
	if [ -z "$old" ]; then
		err "无法读取 $bin 的当前版本"
		add_result "host:$bin" "?" "$TARGET_VERSION" "FAIL" "版本读取失败"
		return 1
	fi
	info "宿主二进制: $bin -> $real（当前 $old）"

	if [ "$(ver_cmp "$old" "$TARGET_VERSION")" -ge 0 ]; then
		ok "已是 $old，无需升级"
		add_result "host:$bin" "$old" "$old" "SKIP" "已是最新或更新"
		return 0
	fi

	info "开始升级 $old -> $TARGET_VERSION"
	pkg=$(dpkg_owner "$real")

	if [ -n "$pkg" ]; then
		deb="$TMPD/cloudflared.deb"
		url="https://github.com/cloudflare/cloudflared/releases/download/$TARGET_VERSION/cloudflared-linux-$CF_ARCH.deb"
		if [ "$DRY_RUN" -eq 1 ]; then
			say "[dry-run] 下载 $url && dpkg -i cloudflared.deb"
		elif ! { fetch_to "$url" "$deb" && dpkg -i "$deb" >/dev/null 2>&1; }; then
			warn "dpkg 安装失败，回退到静态二进制替换"
			tmpb="$TMPD/cloudflared.new"
			download_static_binary "$TARGET_VERSION" "$CF_ARCH" "$tmpb" || { add_result "host:$bin" "$old" "$TARGET_VERSION" "FAIL" "下载失败"; return 1; }
			replace_binary "$real" "$tmpb" || { add_result "host:$bin" "$old" "$TARGET_VERSION" "FAIL" "替换失败"; return 1; }
		fi
	elif apk_has_pkg; then
		repo_ver=$(apk_repo_version)
		if [ -n "$repo_ver" ] && ver_ge "$repo_ver" "$TARGET_VERSION"; then
			info "apk 仓库版本 $repo_ver 满足目标，使用 apk upgrade"
			run apk add --upgrade --no-cache cloudflared || warn "apk 返回非零，继续回读版本校验"
		else
			info "apk 仓库版本（${repo_ver:-未知}）低于目标，改用官方静态二进制"
			tmpb="$TMPD/cloudflared.new"
			download_static_binary "$TARGET_VERSION" "$CF_ARCH" "$tmpb" || { add_result "host:$bin" "$old" "$TARGET_VERSION" "FAIL" "下载失败"; return 1; }
			replace_binary "$real" "$tmpb" || { add_result "host:$bin" "$old" "$TARGET_VERSION" "FAIL" "替换失败"; return 1; }
			warn "注意：apk 包元数据仍为旧版本，实际执行的是 $real 上的新二进制"
		fi
	else
		if [ "$DRY_RUN" -eq 1 ]; then
			say "[dry-run] $bin update --version $TARGET_VERSION"
		elif "$bin" update --version "$TARGET_VERSION" >/dev/null 2>&1; then
			:
		else
			warn "cloudflared update 失败，回退到下载静态二进制"
			tmpb="$TMPD/cloudflared.new"
			download_static_binary "$TARGET_VERSION" "$CF_ARCH" "$tmpb" || { add_result "host:$bin" "$old" "$TARGET_VERSION" "FAIL" "下载失败"; return 1; }
			replace_binary "$real" "$tmpb" || { add_result "host:$bin" "$old" "$TARGET_VERSION" "FAIL" "替换失败"; return 1; }
		fi
	fi

	if [ "$DRY_RUN" -eq 1 ]; then
		add_result "host:$bin" "$old" "$TARGET_VERSION" "DRYRUN" "计划升级"
		return 0
	fi

	new=$(binary_version "$bin")
	if [ "$new" != "$TARGET_VERSION" ]; then
		err "升级后版本不符：期望 $TARGET_VERSION，实际 '${new:-空}'"
		add_result "host:$bin" "$old" "${new:-?}" "FAIL" "升级后版本不符"
		return 1
	fi
	ok "二进制已升级：$old -> $new"
	restart_services "$real" "$bin"
	add_result "host:$bin" "$old" "$new" "UPGRADED" "${SVC_NOTE:-二进制已更新}"
	return 0
}

find_units_for() { # realbin bin
	{
		for f in /etc/systemd/system/*.service /usr/lib/systemd/system/*.service /lib/systemd/system/*.service; do
			[ -f "$f" ] || continue
			if grep -qF -- "$1" "$f" 2>/dev/null || grep -qF -- "$2" "$f" 2>/dev/null; then
				basename "$f" .service
			fi
		done
	} | sort -u
}

restart_services() {
	real=$1; bin=$2
	SVC_NOTE=""
	if [ "$NO_RESTART" -eq 1 ]; then
		SVC_NOTE="二进制已更新；--no-restart 指定不重启，需手动重启服务"
		warn "$SVC_NOTE"
		return 0
	fi

	units=$(find_units_for "$real" "$bin")
	restarted=""
	skipped_inactive=""
	if [ -n "$units" ] && have systemctl; then
		for u in $units; do
			was=$(systemctl is-active "$u" 2>/dev/null || true)
			if [ "$was" != "active" ]; then
				# 升级前本来就没在跑：只换二进制，不把隧道误启动
				skipped_inactive="$skipped_inactive $u"
				info "单元 $u 升级前非 active（${was:-unknown}），不重启"
				continue
			fi
			info "重启 systemd 单元 $u"
			if [ "$DRY_RUN" -eq 1 ]; then say "[dry-run] systemctl restart $u"; restarted="$restarted $u"; continue; fi
			if systemctl restart "$u" 2>/dev/null; then
				sleep 2
				st=$(systemctl is-active "$u" 2>/dev/null || true)
				if [ "$st" = "active" ]; then
					ok "$u 已重启并处于 active"
					restarted="$restarted $u"
				else
					err "$u 重启后状态为 ${st:-unknown}"
				fi
			else
				err "systemctl restart $u 失败"
			fi
		done
	fi

	if [ -n "$skipped_inactive" ]; then
		SVC_NOTE="二进制已更新；单元$(printf '%s' "$skipped_inactive" | sed 's/^ //')升级前未运行，未启动（保持原状态）"
		warn "$SVC_NOTE"
	fi

	if [ -z "$restarted" ] && [ -z "$skipped_inactive" ] && have rc-service && [ -x /etc/init.d/cloudflared ]; then
		if ! rc-service cloudflared status >/dev/null 2>&1; then
			skipped_inactive=" cloudflared"
			SVC_NOTE="二进制已更新；OpenRC 服务 cloudflared 升级前未运行，未启动（保持原状态）"
			warn "$SVC_NOTE"
		else
			info "重启 OpenRC 服务 cloudflared"
			if [ "$DRY_RUN" -eq 1 ]; then
				say "[dry-run] rc-service cloudflared restart"; restarted="cloudflared"
			elif rc-service cloudflared restart >/dev/null 2>&1; then
				sleep 2
				if rc-service cloudflared status >/dev/null 2>&1; then
					ok "cloudflared 已重启"
					restarted="cloudflared"
				else
					err "cloudflared 重启后未运行"
				fi
			else
				err "rc-service cloudflared restart 失败"
			fi
		fi
	fi

	if [ -n "$restarted" ]; then
		SVC_NOTE="已重启:$(printf '%s' "$restarted" | sed 's/^ //')"
		return 0
	fi

	if [ -z "$units" ] && [ ! -x /etc/init.d/cloudflared ]; then
		pids=$(find_bare_pids)
		if [ -z "$pids" ]; then
			SVC_NOTE="二进制已更新；未发现运行中的进程"
			info "$SVC_NOTE"
			return 0
		fi
		if [ "$RESTART_BARE" -eq 1 ]; then
			restart_bare_pids "$pids"
			SVC_NOTE="已重启裸进程: $(printf '%s' "$pids" | tr ' ' ',')"
		else
			SVC_NOTE="二进制已更新；裸进程 $pids 仍运行旧版本，需手动重启（或加 --restart-bare）"
			warn "$SVC_NOTE"
		fi
	fi
	return 0
}

find_bare_pids() {
	out=""
	for d in /proc/[0-9]*; do
		[ -r "$d/comm" ] || continue
		[ "$(cat "$d/comm" 2>/dev/null)" = "cloudflared" ] || continue
		pid=${d#/proc/}
		[ "$pid" = "$$" ] && continue
		out="$out $pid"
	done
	printf '%s' "$out" | sed 's/^ //'
}

restart_bare_pids() {
	for pid in $1; do
		[ -r "/proc/$pid/cmdline" ] || continue
		cmd=$(tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null | sed 's/ *$//')
		[ -n "$cmd" ] || continue
		info "重启裸进程 $pid: $cmd"
		if [ "$DRY_RUN" -eq 1 ]; then say "[dry-run] kill $pid && (setsid $cmd &)"; continue; fi
		kill "$pid" 2>/dev/null || true
		i=0
		while [ "$i" -lt 10 ] && kill -0 "$pid" 2>/dev/null; do sleep 1; i=$((i + 1)); done
		kill -9 "$pid" 2>/dev/null || true
		( setsid sh -c "$cmd" >>/var/log/cloudflared.log 2>&1 & ) 2>/dev/null || \
			( nohup sh -c "$cmd" >>/var/log/cloudflared.log 2>&1 & ) 2>/dev/null || true
		sleep 2
	done
}

# ------------------------------------------------------------------ 容器
docker_ok() { have docker && docker info >/dev/null 2>&1; }

is_cloudflared_container() {
	desc=$(docker inspect -f '{{.Config.Image}} {{json .Config.Entrypoint}} {{json .Config.Cmd}}' "$1" 2>/dev/null || true)
	case "$desc" in *cloudflared*) return 0 ;; esac
	return 1
}

# --keep-old 留下的备份容器（<name>.bak-<ts>）不是生产容器：它通常已停止，
# 再去「升级」它必然失败并产生假 FAIL。识别并跳过。
is_backup_container() {
	n=$(docker inspect -f '{{.Name}}' "$1" 2>/dev/null | sed 's#^/##')
	case "$n" in
		*.bak-[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]-[0-9][0-9][0-9][0-9][0-9][0-9]) return 0 ;;
	esac
	return 1
}

container_version() { # id image state
	id=$1; img=$2; state=$3
	v=""
	if [ "$state" = "running" ]; then
		v=$(docker exec "$id" cloudflared version 2>/dev/null | head -1 || true)
		[ -n "$v" ] || v=$(docker exec "$id" /usr/local/bin/cloudflared version 2>/dev/null | head -1 || true)
	fi
	if [ -z "$v" ] && docker image inspect "$img" >/dev/null 2>&1; then
		v=$(docker run --rm --network none --entrypoint cloudflared "$img" version 2>/dev/null | head -1 || true)
	fi
	extract_version "$v"
}

image_version_of() { # ref
	docker run --rm --network none --entrypoint cloudflared "$1" version 2>/dev/null | head -1 | { read -r line || true; extract_version "$line"; }
}

image_repo() { printf '%s' "$1" | sed 's/:[^/:]*$//'; }
image_tag()  { case "$1" in *:*) printf '%s' "${1##*:}" ;; *) printf 'latest' ;; esac; }

compose_cmd() {
	if have docker && docker compose version >/dev/null 2>&1; then printf 'docker compose'
	elif have docker-compose; then printf 'docker-compose'
	else return 1; fi
}

upgrade_container() { # id
	id=$1
	name=$(docker inspect -f '{{.Name}}' "$id" 2>/dev/null | sed 's#^/##')
	img=$(docker inspect -f '{{.Config.Image}}' "$id" 2>/dev/null)
	state=$(docker inspect -f '{{.State.Status}}' "$id" 2>/dev/null)
	[ -n "$name" ] && [ -n "$img" ] || { err "无法读取容器 $id 的信息"; return 1; }
	FOUND=$((FOUND + 1))

	old=$(container_version "$id" "$img" "$state")
	[ -n "$old" ] || old="unknown"
	info "容器 $name（镜像 $img）当前版本 $old，状态 $state"

	project=$(docker inspect -f '{{index .Config.Labels "com.docker.compose.project"}}' "$id" 2>/dev/null || true)
	service=$(docker inspect -f '{{index .Config.Labels "com.docker.compose.service"}}' "$id" 2>/dev/null || true)
	cfiles=$(docker inspect -f '{{index .Config.Labels "com.docker.compose.project.config_files"}}' "$id" 2>/dev/null || true)
	cwd=$(docker inspect -f '{{index .Config.Labels "com.docker.compose.project.working_dir"}}' "$id" 2>/dev/null || true)

	repo=$(image_repo "$img")
	tag=$(image_tag "$img")
	pull_ref="$repo:$TARGET_VERSION"

	info "拉取镜像 $pull_ref"
	if [ "$DRY_RUN" -eq 1 ]; then
		say "[dry-run] docker pull $pull_ref"
	elif ! docker pull -q "$pull_ref" >/dev/null 2>&1; then
		warn "目标版本镜像 $pull_ref 拉取失败，回退到 $repo:latest"
		pull_ref="$repo:latest"
		if ! docker pull -q "$pull_ref" >/dev/null 2>&1; then
			err "镜像拉取失败: $pull_ref"
			add_result "container:$name" "$old" "$TARGET_VERSION" "FAIL" "镜像拉取失败"
			return 1
		fi
	fi

	if [ "$DRY_RUN" -eq 1 ]; then
		new="$TARGET_VERSION"
	else
		new=$(image_version_of "$pull_ref")
		[ -n "$new" ] || new="$TARGET_VERSION"
	fi

	if [ "$old" != "unknown" ] && [ "$(ver_cmp "$new" "$old")" -le 0 ]; then
		ok "镜像已是 $old，无需升级"
		add_result "container:$name" "$old" "$old" "SKIP" "镜像已是最新"
		return 0
	fi

	if [ "$PULL_ONLY" -eq 1 ]; then
		warn "已拉取 $pull_ref（$new）；--pull-only 指定不重建容器"
		add_result "container:$name" "$old" "$new" "PULLED" "仅拉取镜像，容器待重建"
		return 0
	fi

	if [ -n "$project" ] && [ -n "$service" ]; then
		upgrade_container_compose "$id" "$name" "$old" "$new" "$project" "$service" "$cfiles" "$cwd" "$img" "$repo" "$tag" "$pull_ref" "$state"
	else
		upgrade_container_plain "$id" "$name" "$old" "$new" "$pull_ref" "$state"
	fi
}

upgrade_container_compose() {
	id=$1 name=$2 old=$3 new=$4 project=$5 service=$6 cfiles=$7 cwd=$8 img=$9 repo=${10} tag=${11} pull_ref=${12} was_state=${13:-}

	cc=$(compose_cmd) || { err "找不到 docker compose / docker-compose，无法重建 $name"; add_result "container:$name" "$old" "$new" "FAIL" "缺少 compose 命令"; return 1; }

	compose_args=""
	if [ -n "$cfiles" ]; then
		oldifs=$IFS
		IFS=','
		for f in $cfiles; do
			[ -n "$f" ] && compose_args="$compose_args -f $f"
		done
		IFS=$oldifs
	fi
	[ -n "$cwd" ] && compose_args="$compose_args --project-directory $cwd"

	did_retag=0
	if [ "$tag" != "latest" ] && [ "$tag" != "$TARGET_VERSION" ]; then
		if [ "$ALLOW_RETAG" -eq 1 ]; then
			info "compose 镜像 tag 固定为 $tag，按 --allow-retag 本地重打标签"
			if [ "$DRY_RUN" -eq 1 ]; then say "[dry-run] docker tag $pull_ref $img"
			elif ! docker tag "$pull_ref" "$img" 2>/dev/null; then
				err "docker tag 失败"
				add_result "container:$name" "$old" "$new" "FAIL" "retag 失败"
				return 1
			fi
			did_retag=1
		else
			warn "compose 镜像 tag 固定为 $tag（非 latest），pull 无法升级到 $new"
			warn "请把 compose 里的 image 改为 $repo:$new 后重跑，或加 --allow-retag"
			add_result "container:$name" "$old" "$new" "SKIPPED" "tag 固定为 $tag，需手工改 compose"
			return 0
		fi
	fi

	if [ "$DRY_RUN" -eq 1 ]; then
		# 已 retag 时不能 pull：pull 会用仓库里的旧内容覆盖刚打好的本地 tag
		[ "$did_retag" -eq 1 ] || say "[dry-run] $cc $compose_args pull $service"
		say "[dry-run] $cc $compose_args up -d --force-recreate --no-deps $service"
		[ "$was_state" != "running" ] && say "[dry-run] docker stop $name   # 升级前状态=$was_state，重建后保持原状态"
		add_result "container:$name" "$old" "$new" "DRYRUN" "计划 compose 重建"
		return 0
	fi

	info "compose 重建服务 $service（project=$project）"
	if [ "$did_retag" -eq 1 ]; then
		# 关键：retag 之后绝不能再 compose pull —— 否则会把 $img 从仓库拉回旧内容，
		# 重建出来的容器仍是旧版本（实测：B3 加了 --allow-retag 仍报 2025.2.1）。
		info "已本地 retag，跳过 compose pull（避免覆盖 $img）"
	else
		# shellcheck disable=SC2086
		$cc $compose_args pull "$service" >/dev/null 2>&1 || warn "compose pull 返回非零，继续用已拉取的镜像重建"
	fi
	# shellcheck disable=SC2086
	if $cc $compose_args up -d --force-recreate --no-deps "$service" >/dev/null 2>&1; then
		if [ "$was_state" != "running" ]; then
			# compose up 会把容器拉起来；升级前不是 running 就恢复原状态
			docker stop "$name" >/dev/null 2>&1 || true
			info "升级前状态为 $was_state，已停止容器以保持原状态"
		fi
		verify_container_after "$name" "$old" "$new" "compose" "$was_state"
	else
		err "compose 重建 $name 失败（旧容器可能仍在运行，请检查 compose 日志）"
		add_result "container:$name" "$old" "$new" "FAIL" "compose 重建失败"
		return 1
	fi
}

upgrade_container_plain() {
	id=$1 name=$2 old=$3 new=$4 pull_ref=$5 was_state=${6:-running}
	ts=$(date +%Y%m%d-%H%M%S)
	insp="$BACKUP_ROOT/${name}-inspect-${ts}.json"

	if [ "$DRY_RUN" -eq 0 ]; then
		ensure_dir "$BACKUP_ROOT" || true
		if docker inspect "$id" > "$insp" 2>/dev/null; then
			chmod 600 "$insp" 2>/dev/null || true
			info "容器配置已备份: $insp"
		else
			warn "容器配置备份失败（继续，但请留意）"
		fi
	fi

	# ---- 收集重建参数
	: > "$TMPD/ep"; : > "$TMPD/cmd"; : > "$TMPD/env"; : > "$TMPD/binds"; : > "$TMPD/ports"
	docker inspect -f '{{range .Config.Entrypoint}}{{println .}}{{end}}' "$id" 2>/dev/null > "$TMPD/ep" || true
	docker inspect -f '{{range .Config.Cmd}}{{println .}}{{end}}' "$id" 2>/dev/null > "$TMPD/cmd" || true
	docker inspect -f '{{range .Config.Env}}{{println .}}{{end}}' "$id" 2>/dev/null > "$TMPD/env" || true
	docker inspect -f '{{range .HostConfig.Binds}}{{println .}}{{end}}' "$id" 2>/dev/null > "$TMPD/binds" || true
	# 注意：必须用 printf 拼装，不能用 {{println $p "|" .HostIp "|" .HostPort}} ——
	# 后者每个参数之间会插入空格，HostIp 为空时会得到 "8080/tcp |  | 18080"，
	# 解析出 hip="  "（非空）→ 拼成 -p "  : 18080:8080/tcp" → docker 报 invalid IP address
	docker inspect -f '{{range $p, $b := .HostConfig.PortBindings}}{{range $b}}{{println (printf "%s|%s|%s" $p .HostIp .HostPort)}}{{end}}{{end}}' "$id" 2>/dev/null > "$TMPD/ports" || true

	restart=$(docker inspect -f '{{.HostConfig.RestartPolicy.Name}}' "$id" 2>/dev/null || true)
	user=$(docker inspect -f '{{.Config.User}}' "$id" 2>/dev/null || true)
	wd=$(docker inspect -f '{{.Config.WorkingDir}}' "$id" 2>/dev/null || true)
	priv=$(docker inspect -f '{{.HostConfig.Privileged}}' "$id" 2>/dev/null || true)
	tty=$(docker inspect -f '{{.Config.Tty}}' "$id" 2>/dev/null || true)
	networks=$(docker inspect -f '{{range $n, $c := .NetworkSettings.Networks}}{{println $n}}{{end}}' "$id" 2>/dev/null || true)

	set --
	[ -n "$restart" ] && [ "$restart" != "no" ] && set -- "$@" --restart "$restart"
	[ -n "$user" ] && set -- "$@" --user "$user"
	[ -n "$wd" ] && set -- "$@" -w "$wd"
	[ "$priv" = "true" ] && set -- "$@" --privileged
	[ "$tty" = "true" ] && set -- "$@" -t
	[ -s "$TMPD/env" ] && set -- "$@" --env-file "$TMPD/env"

	# entrypoint：docker 只支持单值 --entrypoint，多段时把余下元素并入命令参数（语义等价）
	ep_first=$(head -1 "$TMPD/ep" 2>/dev/null || true)
	ep_rest="$TMPD/ep_rest"
	: > "$ep_rest"
	if [ -s "$TMPD/ep" ]; then
		tail -n +2 "$TMPD/ep" > "$ep_rest" 2>/dev/null || true
		[ -n "$ep_first" ] && set -- "$@" --entrypoint "$ep_first"
	fi

	while IFS= read -r b; do [ -n "$b" ] && set -- "$@" -v "$b"; done < "$TMPD/binds"

	while IFS='|' read -r cport hip hport; do
		# IFS='|' 只按竖线切分，不去两端空格；这里再兜底裁一次，防止格式串变动带出空格
		cport=$(printf '%s' "$cport" | tr -d ' \t')
		hip=$(printf '%s' "$hip" | tr -d ' \t')
		hport=$(printf '%s' "$hport" | tr -d ' \t')
		[ -n "$cport" ] || continue
		if [ -n "$hip" ]; then set -- "$@" -p "$hip:$hport:$cport"
		else set -- "$@" -p "$hport:$cport"; fi
	done < "$TMPD/ports"

	for spec in CapAdd:--cap-add CapDrop:--cap-drop SecurityOpt:--security-opt Dns:--dns DnsSearch:--dns-search ExtraHosts:--add-host; do
		field=${spec%%:*}; flag=${spec#*:}
		docker inspect -f "{{range .HostConfig.$field}}{{println .}}{{end}}" "$id" 2>/dev/null > "$TMPD/opt" || true
		while IFS= read -r v; do [ -n "$v" ] && set -- "$@" "$flag" "$v"; done < "$TMPD/opt"
	done

	first_net=""
	if [ -n "$networks" ]; then
		first_net=$(printf '%s\n' "$networks" | head -1)
		[ -n "$first_net" ] && set -- "$@" --network "$first_net"
	fi

	set -- "$@" --name "$name" "$pull_ref"

	# entrypoint 余项 + Cmd
	if [ -s "$ep_rest" ]; then
		while IFS= read -r a; do [ -n "$a" ] && set -- "$@" "$a"; done < "$ep_rest"
	fi
	if [ -s "$TMPD/cmd" ]; then
		while IFS= read -r a; do [ -n "$a" ] && set -- "$@" "$a"; done < "$TMPD/cmd"
	fi

	info "非 compose 容器，按 inspect 参数重建: $name"
	if [ "$DRY_RUN" -eq 1 ]; then
		say "[dry-run] docker stop $id && docker rename $id $name.bak-$ts"
		say "[dry-run] docker run -d $*"
		[ "$was_state" != "running" ] && say "[dry-run] docker stop $name   # 升级前状态=$was_state，重建后保持原状态"
		add_result "container:$name" "$old" "$new" "DRYRUN" "计划按 inspect 重建"
		return 0
	fi

	docker stop "$id" >/dev/null 2>&1 || true
	if ! docker rename "$id" "$name.bak-$ts" >/dev/null 2>&1; then
		err "重命名旧容器失败，中止（未做替换）"
		docker start "$id" >/dev/null 2>&1 || true
		add_result "container:$name" "$old" "$new" "FAIL" "重命名旧容器失败"
		return 1
	fi

	if docker run -d "$@" >/dev/null 2>"$TMPD/run.err"; then
		if [ -n "$networks" ]; then
			idx=0
			while IFS= read -r n; do
				idx=$((idx + 1))
				[ "$idx" -eq 1 ] && continue
				[ -n "$n" ] && { docker network connect "$n" "$name" >/dev/null 2>&1 || warn "附加网络 $n 失败"; }
			done <<EOF
$networks
EOF
		fi
		if [ "$was_state" != "running" ]; then
			# docker run -d 会启动；升级前不是 running 就恢复原状态
			docker stop "$name" >/dev/null 2>&1 || true
			info "升级前状态为 $was_state，已停止容器以保持原状态"
		fi
		verify_container_after "$name" "$old" "$new" "inspect" "$was_state"
	else
		err "重建失败: $(tr '\n' ' ' < "$TMPD/run.err" 2>/dev/null | head -c 300)"
		warn "回滚：恢复旧容器 $name.bak-$ts"
		docker rm -f "$name" >/dev/null 2>&1 || true
		docker rename "$name.bak-$ts" "$name" >/dev/null 2>&1 || true
		[ "$was_state" = "running" ] && docker start "$name" >/dev/null 2>&1 || true
		add_result "container:$name" "$old" "$new" "FAIL" "重建失败，已回滚旧容器"
		return 1
	fi
}

verify_container_after() { # name old new how [was_state]
	name=$1; old=$2; new=$3; how=$4; was_state=${5:-running}
	sleep 3
	# 用 ps -a 找，因为升级前非 running 的容器重建后应保持停止
	cid=$(docker ps -aq -f "name=^/${name}$" 2>/dev/null | head -1)
	if [ -z "$cid" ]; then
		err "重建后找不到容器 $name"
		add_result "container:$name" "$old" "$new" "FAIL" "重建后容器不存在"
		return 1
	fi
	state=$(docker inspect -f '{{.State.Status}}' "$cid" 2>/dev/null)
	img=$(docker inspect -f '{{.Config.Image}}' "$cid" 2>/dev/null)
	got=$(container_version "$cid" "$img" "$state")

	# 状态是否符合升级前
	if [ "$was_state" = "running" ] && [ "$state" != "running" ]; then
		err "容器 $name 期望 running，实际 ${state:-unknown}"
		add_result "container:$name" "$old" "${got:-?}" "FAIL" "期望运行但实际 ${state:-unknown}"
		return 1
	fi
	if [ "$was_state" != "running" ] && [ "$state" = "running" ]; then
		warn "容器 $name 升级前为 $was_state，重建后仍 running（可能 compose 重启策略所致）"
	fi

	if [ "$got" = "$new" ]; then
		ok "容器 $name 已升级：$old -> $got（重建方式: $how，状态: $state）"
		if [ "$KEEP_OLD" -eq 0 ]; then
			for c in $(docker ps -aq -f "name=^/${name}.bak-" 2>/dev/null); do
				docker rm -f "$c" >/dev/null 2>&1 || true
			done
		fi
		note="重建方式: $how"
		[ "$was_state" != "running" ] && note="$note；保持原状态 $state"
		add_result "container:$name" "$old" "$got" "UPGRADED" "$note"
		return 0
	fi

	if [ -n "$got" ] && [ "$old" != "unknown" ] && [ "$(ver_cmp "$got" "$old")" -gt 0 ]; then
		warn "容器 $name 版本 $got（与预期 $new 略有出入，但已高于旧版），状态 $state"
		add_result "container:$name" "$old" "$got" "UPGRADED" "重建方式: $how"
		return 0
	fi

	err "容器 $name 状态 ${state:-unknown}，版本 '${got:-未知}'（期望 $new）"
	add_result "container:$name" "$old" "${got:-?}" "FAIL" "重建后版本/状态不符"
	return 1
}

scan_containers() {
	docker_ok || { info "未检测到可用的 Docker，跳过容器检查"; return 0; }
	ids=$(docker ps -a --format '{{.ID}}' 2>/dev/null || true)
	[ -n "$ids" ] || { info "本机没有容器"; return 0; }
	hit=0
	for cid in $ids; do
		is_cloudflared_container "$cid" || continue
		if is_backup_container "$cid"; then
			bname=$(docker inspect -f '{{.Name}}' "$cid" 2>/dev/null | sed 's#^/##')
			info "跳过备份容器 $bname（--keep-old 保留的旧容器，非生产实例）"
			continue
		fi
		hit=1
		upgrade_container "$cid" || true
	done
	[ "$hit" -eq 1 ] || info "未发现 cloudflared 容器"
	return 0
}

# ------------------------------------------------------------------ 汇总
print_summary() {
	say ""
	say "================= 结果汇总 ================="
	if [ ! -s "$RESULTS" ]; then
		say "没有需要处理的 cloudflared（未检测到宿主二进制或容器）。"
		say "============================================"
		return 0
	fi
	printf '%-34s %-14s %-14s %-9s %s\n' "组件" "旧版本" "新版本" "结果" "说明"
	printf '%-34s %-14s %-14s %-9s %s\n' "----------------------------------" "--------------" "--------------" "---------" "----"
	while IFS='	' read -r n o nw st note; do
		printf '%-34s %-14s %-14s %-9s %s\n' "$n" "$o" "$nw" "$st" "$note"
	done < "$RESULTS"
	say "============================================"
}

main() {
	say "cloudflared 升级脚本 v$SCRIPT_VERSION"
	detect_os
	say "系统: $OS_NAME   架构: $ARCH_RAW${CF_ARCH:+ ($CF_ARCH)}"
	[ "$DRY_RUN" -eq 1 ] && say "模式: DRY-RUN（不修改任何内容）"
	say ""

	check_distro_support
	resolve_target_version || { print_summary; exit 1; }

	if [ -z "$ONLY" ] || [ "$ONLY" = "host" ]; then
		say "--- 宿主二进制 ---"
		if bin=$(find_binary); then
			upgrade_host_binary "$bin" || true
		else
			info "未发现宿主 cloudflared 二进制"
		fi
		say ""
	fi

	if [ -z "$ONLY" ] || [ "$ONLY" = "container" ]; then
		say "--- 容器 ---"
		scan_containers
		say ""
	fi

	print_summary

	if [ "$FOUND" -eq 0 ]; then
		info "未检测到任何 cloudflared（宿主二进制或容器），无需操作。"
		exit 3
	fi
	if [ "$FAILED" -gt 0 ]; then
		err "共有 $FAILED 项失败，请查看上面的 [FAIL] 行"
		exit 1
	fi
	ok "全部处理完成"
	exit 0
}

main "$@"
