#!/usr/bin/env bash
# 在 Debian / Ubuntu 等使用 systemd 的 GCP VM 上安装 Tailscale SOCKS5 代理。
#
# 首次运行（请使用新的、可复用的 Tailscale Auth Key）：
#   sudo env TAILSCALE_AUTH_KEY='tskey-auth-...' bash install.sh
#
# 已加入 Tailnet 的机器可以直接再次运行；此时不需要再提供 Auth Key。
# 重启后由 tailscale-socks5.service 等待 Tailscale IP 可用，再启动容器。

set -Eeuo pipefail

# 可通过环境变量覆盖，不要把 Auth Key 写回此文件或提交到仓库。
TAILSCALE_AUTH_KEY="${TAILSCALE_AUTH_KEY:-}"
PROXY_PORT="${PROXY_PORT:-1080}"
GOST_IMAGE="${GOST_IMAGE:-gogost/gost}"
CONTAINER_NAME="${CONTAINER_NAME:-proxy_socks5}"
# GCP Spot 建议设置，例如：gcp-socks。Windows 端随后使用其 MagicDNS 名称连接。
TAILSCALE_HOSTNAME="${TAILSCALE_HOSTNAME:-}"

SERVICE_NAME="tailscale-socks5"
CONFIG_DIR="/etc/${SERVICE_NAME}"
CONFIG_FILE="${CONFIG_DIR}/config"
RUNNER_PATH="/usr/local/sbin/${SERVICE_NAME}-start"
UNIT_PATH="/etc/systemd/system/${SERVICE_NAME}.service"
STATE_DIR="/var/lib/${SERVICE_NAME}"
STATE_FILE="${STATE_DIR}/install-state"

# 仅在本脚本实际安装了依赖时设为 1；uninstall.sh 会据此避免删除用户原有服务。
TAILSCALE_INSTALLED_BY_SCRIPT=0
DOCKER_INSTALLED_BY_SCRIPT=0
DOCKER_INSTALL_METHOD=''
DOCKER_SERVICE=''

log() {
    printf '[%s] %s\n' "$1" "$2"
}

die() {
    log 'ERROR' "$1" >&2
    exit 1
}

require_root() {
    [ "${EUID}" -eq 0 ] || die "请以 root 身份运行，例如：sudo env TAILSCALE_AUTH_KEY='tskey-auth-...' bash install.sh"
}

validate_config() {
    case "${PROXY_PORT}" in
        ''|*[!0-9]*) die "PROXY_PORT 必须是 1 到 65535 之间的数字" ;;
    esac
    (( PROXY_PORT >= 1 && PROXY_PORT <= 65535 )) || die "PROXY_PORT 必须是 1 到 65535 之间的数字"
    [ -n "${GOST_IMAGE}" ] || die "GOST_IMAGE 不能为空"
    [ -n "${CONTAINER_NAME}" ] || die "CONTAINER_NAME 不能为空"
    if [ -n "${TAILSCALE_HOSTNAME}" ]; then
        [[ "${TAILSCALE_HOSTNAME}" =~ ^[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?$ ]] \
            || die 'TAILSCALE_HOSTNAME 只能包含字母、数字和连字符，且不能以连字符开头或结尾。'
    fi
}

install_curl_if_needed() {
    command -v curl >/dev/null 2>&1 && return

    log '1/6' '未检测到 curl，正在安装…'
    if command -v apt-get >/dev/null 2>&1; then
        apt-get update
        DEBIAN_FRONTEND=noninteractive apt-get install -y curl ca-certificates
    elif command -v dnf >/dev/null 2>&1; then
        dnf install -y curl ca-certificates
    elif command -v yum >/dev/null 2>&1; then
        yum install -y curl ca-certificates
    else
        die '未找到 apt-get、dnf 或 yum；请先安装 curl 后再运行本脚本。'
    fi
}

run_downloaded_script() {
    local url="$1"
    local label="$2"
    local temp_file

    temp_file="$(mktemp)"
    trap 'rm -f "${temp_file}"' RETURN
    log 'INFO' "正在下载 ${label} 安装脚本…"
    curl --fail --show-error --silent --location "${url}" --output "${temp_file}"
    sh "${temp_file}"
    rm -f "${temp_file}"
    trap - RETURN
}

ensure_systemd() {
    command -v systemctl >/dev/null 2>&1 || die '此脚本需要 systemd。GCP 的 Ubuntu、Debian、Rocky Linux 镜像均支持 systemd。'
}

ensure_tailscale() {
    if ! command -v tailscale >/dev/null 2>&1; then
        log '2/6' '未检测到 Tailscale，正在安装…'
        run_downloaded_script 'https://tailscale.com/install.sh' 'Tailscale'
        TAILSCALE_INSTALLED_BY_SCRIPT=1
    else
        log '2/6' 'Tailscale 已安装。'
    fi

    systemctl enable --now tailscaled
}

current_tailscale_ip() {
    tailscale ip -4 2>/dev/null | sed -n '1p' || true
}

wait_for_tailscale_ip() {
    local ip=''
    local attempt

    for attempt in $(seq 1 60); do
        ip="$(current_tailscale_ip)"
        if [ -n "${ip}" ]; then
            printf '%s\n' "${ip}"
            return 0
        fi
        sleep 2
    done

    return 1
}

connect_tailscale() {
    local ts_ip
    local -a up_args

    ts_ip="$(current_tailscale_ip)"
    if [ -n "${ts_ip}" ]; then
        if [ -n "${TAILSCALE_HOSTNAME}" ]; then
            tailscale set --hostname="${TAILSCALE_HOSTNAME}"
        fi
        log '3/6' "Tailscale 已连接，IP: ${ts_ip}"
        return
    fi

    [ -n "${TAILSCALE_AUTH_KEY}" ] || die '本机尚未加入 Tailnet。请设置 TAILSCALE_AUTH_KEY 后重试。'
    log '3/6' '正在使用 Auth Key 加入 Tailscale…'
    up_args=(up "--auth-key=${TAILSCALE_AUTH_KEY}")
    if [ -n "${TAILSCALE_HOSTNAME}" ]; then
        up_args+=("--hostname=${TAILSCALE_HOSTNAME}")
    fi
    tailscale "${up_args[@]}"

    ts_ip="$(wait_for_tailscale_ip)" || die '等待 Tailscale IPv4 地址超时，请检查 Auth Key 和出网连接。'
    log '3/6' "成功分配到 Tailscale IP: ${ts_ip}"
}

install_docker_from_packages() {
    if command -v apt-get >/dev/null 2>&1; then
        apt-get update
        DEBIAN_FRONTEND=noninteractive apt-get install -y docker.io
        DOCKER_INSTALL_METHOD='apt'
    elif command -v dnf >/dev/null 2>&1; then
        dnf install -y docker
        DOCKER_INSTALL_METHOD='dnf'
    elif command -v yum >/dev/null 2>&1; then
        yum install -y docker
        DOCKER_INSTALL_METHOD='yum'
    else
        return 1
    fi
}

detect_docker_service() {
    local unit

    # Snap 版 Docker 的服务名不同；其余常见发行版使用 docker.service。
    for unit in docker.service snap.docker.dockerd.service; do
        if systemctl cat "${unit}" >/dev/null 2>&1; then
            printf '%s\n' "${unit}"
            return 0
        fi
    done
    return 1
}

ensure_docker() {
    local docker_was_present=0

    command -v docker >/dev/null 2>&1 && docker_was_present=1
    DOCKER_SERVICE="$(detect_docker_service || true)"

    if [ "${docker_was_present}" -eq 0 ] || [ -z "${DOCKER_SERVICE}" ]; then
        log '4/6' '未检测到可由 systemd 管理的 Docker Engine，尝试通过系统软件源安装…'
        if ! install_docker_from_packages; then
            log 'WARN' '系统软件源未提供 Docker，改用 Docker 官方安装脚本。'
            run_downloaded_script 'https://get.docker.com' 'Docker'
            DOCKER_INSTALL_METHOD='official'
        fi
        DOCKER_SERVICE="$(detect_docker_service || true)"

        # 某些镜像带有 docker 客户端（或 Podman 兼容命令），但没有 Docker daemon。
        # 软件源安装后仍没有服务时，尝试 Docker 官方安装器一次。
        if [ -z "${DOCKER_SERVICE}" ]; then
            log 'WARN' '系统软件源安装后仍未发现 Docker 服务，改用 Docker 官方安装器。'
            run_downloaded_script 'https://get.docker.com' 'Docker'
            DOCKER_INSTALL_METHOD='official'
            DOCKER_SERVICE="$(detect_docker_service || true)"
        fi

        [ -n "${DOCKER_SERVICE}" ] || die '检测到 Docker 客户端，但未找到 Docker Engine 服务。请检查是否安装了 Podman 或损坏的 Docker/Snap 安装。'
        [ "${docker_was_present}" -eq 0 ] && DOCKER_INSTALLED_BY_SCRIPT=1
    else
        log '4/6' "Docker 已安装（服务：${DOCKER_SERVICE}）。"
    fi

    if [[ "${DOCKER_SERVICE}" == snap.* ]]; then
        # Snap 服务由 snapd 负责开机启用；部分系统不允许对它执行 systemctl enable。
        systemctl start "${DOCKER_SERVICE}"
    else
        systemctl enable --now "${DOCKER_SERVICE}"
    fi
    docker info >/dev/null
}

write_install_state() {
    # 重复运行安装脚本时保留首次安装的归属记录，不能因为依赖现在已存在就丢失它。
    if [ -f "${STATE_FILE}" ]; then
        grep -Fxq 'TAILSCALE_INSTALLED_BY_SCRIPT=1' "${STATE_FILE}" && TAILSCALE_INSTALLED_BY_SCRIPT=1 || true
        grep -Fxq 'DOCKER_INSTALLED_BY_SCRIPT=1' "${STATE_FILE}" && DOCKER_INSTALLED_BY_SCRIPT=1 || true
    fi
    install -d -m 0700 "${STATE_DIR}"
    {
        printf '# 由 install.sh 生成，供 uninstall.sh 判断依赖归属。\n'
        printf 'TAILSCALE_INSTALLED_BY_SCRIPT=%q\n' "${TAILSCALE_INSTALLED_BY_SCRIPT}"
        printf 'DOCKER_INSTALLED_BY_SCRIPT=%q\n' "${DOCKER_INSTALLED_BY_SCRIPT}"
        printf 'DOCKER_INSTALL_METHOD=%q\n' "${DOCKER_INSTALL_METHOD}"
        printf 'CONTAINER_NAME=%q\n' "${CONTAINER_NAME}"
        printf 'GOST_IMAGE=%q\n' "${GOST_IMAGE}"
    } >"${STATE_FILE}"
    chmod 0600 "${STATE_FILE}"
}

write_runtime_files() {
    log '5/6' '正在配置重启后自动恢复的 systemd 服务…'
    install -d -m 0755 "${CONFIG_DIR}"

    # %q 让 config 即使包含空格等字符也能被 bash 安全地 source。
    {
        printf '# 由 install.sh 生成；可修改端口或镜像后重新运行 install.sh。\n'
        printf 'PROXY_PORT=%q\n' "${PROXY_PORT}"
        printf 'GOST_IMAGE=%q\n' "${GOST_IMAGE}"
        printf 'CONTAINER_NAME=%q\n' "${CONTAINER_NAME}"
    } >"${CONFIG_FILE}"
    chmod 0600 "${CONFIG_FILE}"

    cat >"${RUNNER_PATH}" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail

PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
CONFIG_FILE=/etc/tailscale-socks5/config
source "${CONFIG_FILE}"

case "${PROXY_PORT}" in
    ''|*[!0-9]*) echo 'Invalid PROXY_PORT' >&2; exit 1 ;;
esac
(( PROXY_PORT >= 1 && PROXY_PORT <= 65535 )) || { echo 'Invalid PROXY_PORT' >&2; exit 1; }

# Docker 会在 Tailscale 网络真正就绪前先尝试恢复旧容器；这里显式等待 IP，
# 再重建容器，避免 "cannot assign requested address" 后永远无法监听的问题。
for attempt in $(seq 1 60); do
    TS_IP="$(tailscale ip -4 2>/dev/null | sed -n '1p' || true)"
    [ -n "${TS_IP}" ] && break
    sleep 2
done
[ -n "${TS_IP:-}" ] || { echo 'Tailscale IPv4 address was not available after 120 seconds' >&2; exit 1; }

docker rm -f "${CONTAINER_NAME}" >/dev/null 2>&1 || true
exec docker run -d \
    --name "${CONTAINER_NAME}" \
    --restart unless-stopped \
    -p "${TS_IP}:${PROXY_PORT}:1080" \
    "${GOST_IMAGE}" \
    -L=socks5://:1080
EOF
    chmod 0755 "${RUNNER_PATH}"

    cat >"${UNIT_PATH}" <<EOF
[Unit]
Description=Tailscale-bound Gost SOCKS5 proxy
Wants=network-online.target tailscaled.service ${DOCKER_SERVICE}
After=network-online.target tailscaled.service ${DOCKER_SERVICE}

[Service]
Type=oneshot
ExecStart=${RUNNER_PATH}
RemainAfterExit=yes
Restart=on-failure
RestartSec=15

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable "${SERVICE_NAME}.service"
}

start_proxy() {
    local ts_ip

    log '6/6' '正在启动 SOCKS5 代理…'
    systemctl restart "${SERVICE_NAME}.service"
    ts_ip="$(wait_for_tailscale_ip)" || die '代理启动后未能获取 Tailscale IPv4 地址。'

    docker ps --format '{{.Names}}' | grep -Fx "${CONTAINER_NAME}" >/dev/null \
        || die '代理容器未处于运行状态，请运行：systemctl status tailscale-socks5.service'

    printf '\n部署成功。\n'
    printf '代理类型: SOCKS5\n代理 IP:   %s\n代理端口: %s\n' "${ts_ip}" "${PROXY_PORT}"
    printf '重启验证: systemctl status %s.service\n' "${SERVICE_NAME}"
}

main() {
    require_root
    validate_config
    ensure_systemd
    install_curl_if_needed
    ensure_tailscale
    connect_tailscale
    ensure_docker
    write_install_state
    write_runtime_files
    start_proxy
}

main "$@"
