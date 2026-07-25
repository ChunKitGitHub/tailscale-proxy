#!/usr/bin/env bash
# 卸载 install.sh 部署的 Tailscale SOCKS5 代理。
#
# 默认只删除本项目创建的容器、systemd 服务、配置，以及由新版 install.sh
# 明确记录为“本脚本安装”的 Docker/Tailscale。这样不会误删原本就在机器上的依赖。
#
# 旧版 install.sh 没有安装记录时，如确认这台机器的 Docker 和 Tailscale 都只用于本项目，
# 可使用：sudo bash uninstall.sh --purge-dependencies

set -Eeuo pipefail

SERVICE_NAME='tailscale-socks5'
CONFIG_DIR="/etc/${SERVICE_NAME}"
RUNNER_PATH="/usr/local/sbin/${SERVICE_NAME}-start"
UNIT_PATH="/etc/systemd/system/${SERVICE_NAME}.service"
STATE_DIR="/var/lib/${SERVICE_NAME}"
STATE_FILE="${STATE_DIR}/install-state"
HEARTBEAT_SERVICE="${SERVICE_NAME}-heartbeat"
HEARTBEAT_UNIT_PATH="/etc/systemd/system/${HEARTBEAT_SERVICE}.service"
HEARTBEAT_RUNNER_PATH='/usr/local/bin/spot-agent'

CONTAINER_NAME='proxy_socks5'
GOST_IMAGE='gogost/gost'
TAILSCALE_INSTALLED_BY_SCRIPT=0
DOCKER_INSTALLED_BY_SCRIPT=0
PURGE_DEPENDENCIES=0

log() {
    printf '[%s] %s\n' "$1" "$2"
}

die() {
    log 'ERROR' "$1" >&2
    exit 1
}

require_root() {
    [ "${EUID}" -eq 0 ] || die '请以 root 身份运行：sudo bash uninstall.sh'
}

parse_args() {
    case "${1:-}" in
        '') ;;
        --purge-dependencies) PURGE_DEPENDENCIES=1 ;;
        -h|--help)
            printf '用法：sudo bash uninstall.sh [--purge-dependencies]\n'
            printf '  --purge-dependencies  仅用于旧版安装没有状态记录、且确认 Docker/Tailscale 无其他用途时。\n'
            exit 0
            ;;
        *) die "未知参数：${1}" ;;
    esac
}

load_install_state() {
    if [ -f "${STATE_FILE}" ]; then
        # state 文件只由 install.sh 以 root 权限创建，且权限为 0600。
        # shellcheck disable=SC1090
        source "${STATE_FILE}"
        log 'INFO' '已读取安装记录，将仅清理本脚本安装的依赖。'
    else
        log 'WARN' '未找到安装记录（可能由旧版 install.sh 部署）。默认会保留 Docker 和 Tailscale。'
    fi
}

remove_heartbeat_service() {
    log '1/5' '正在停止并删除 Spot 节点心跳服务…'
    if command -v systemctl >/dev/null 2>&1; then
        systemctl disable --now "${HEARTBEAT_SERVICE}.service" >/dev/null 2>&1 || true
    fi
    rm -f "${HEARTBEAT_UNIT_PATH}" "${HEARTBEAT_RUNNER_PATH}"
    if command -v systemctl >/dev/null 2>&1; then
        systemctl daemon-reload
    fi
}

remove_proxy_service() {
    log '2/5' '正在停止并删除 SOCKS5 代理服务…'

    if command -v systemctl >/dev/null 2>&1; then
        systemctl disable --now "${SERVICE_NAME}.service" >/dev/null 2>&1 || true
    fi

    if command -v docker >/dev/null 2>&1; then
        docker rm -f "${CONTAINER_NAME}" >/dev/null 2>&1 || true
        docker image rm "${GOST_IMAGE}" >/dev/null 2>&1 || true
    fi

    rm -f "${UNIT_PATH}" "${RUNNER_PATH}"
    rm -rf "${CONFIG_DIR}"
    if command -v systemctl >/dev/null 2>&1; then
        systemctl daemon-reload
    fi
}

apt_package_installed() {
    dpkg-query -W -f='${db:Status-Status}' "$1" 2>/dev/null | grep -Fx 'installed' >/dev/null
}

rpm_package_installed() {
    rpm -q "$1" >/dev/null 2>&1
}

remove_package_if_present() {
    local package="$1"

    if command -v apt-get >/dev/null 2>&1; then
        if apt_package_installed "${package}"; then
            apt-get purge -y "${package}"
        fi
    elif command -v dnf >/dev/null 2>&1; then
        if rpm_package_installed "${package}"; then
            dnf remove -y "${package}"
        fi
    elif command -v yum >/dev/null 2>&1; then
        if rpm_package_installed "${package}"; then
            yum remove -y "${package}"
        fi
    else
        die '未找到 apt-get、dnf 或 yum，无法自动卸载系统软件包。'
    fi
}

remove_tailscale() {
    if [ "${TAILSCALE_INSTALLED_BY_SCRIPT}" != '1' ] && [ "${PURGE_DEPENDENCIES}" != '1' ]; then
        log '3/5' 'Tailscale 不是本脚本安装，已保留。'
        return
    fi

    log '3/5' '正在卸载 Tailscale…'
    if command -v systemctl >/dev/null 2>&1; then
        systemctl disable --now tailscaled >/dev/null 2>&1 || true
    fi
    remove_package_if_present tailscale
    rm -rf /var/lib/tailscale /etc/tailscale
}

remove_docker() {
    local remaining_containers

    if [ "${DOCKER_INSTALLED_BY_SCRIPT}" != '1' ] && [ "${PURGE_DEPENDENCIES}" != '1' ]; then
        log '4/5' 'Docker 不是本脚本安装，已保留。'
        return
    fi

    if command -v docker >/dev/null 2>&1; then
        remaining_containers="$(docker ps -aq 2>/dev/null || true)"
        [ -z "${remaining_containers}" ] || die 'Docker 中仍有其他容器；为避免误删，未卸载 Docker。请先处理这些容器后重试。'
    fi

    log '4/5' '正在卸载 Docker…'
    if command -v systemctl >/dev/null 2>&1; then
        systemctl disable --now docker >/dev/null 2>&1 || true
        systemctl disable --now containerd >/dev/null 2>&1 || true
    fi

    # 支持 Ubuntu/Debian 的 docker.io，及 Docker 官方安装器安装的组件。
    remove_package_if_present docker.io
    remove_package_if_present docker-ce
    remove_package_if_present docker-ce-cli
    remove_package_if_present containerd.io
    remove_package_if_present docker-buildx-plugin
    remove_package_if_present docker-compose-plugin
    remove_package_if_present docker-ce-rootless-extras
    remove_package_if_present docker

    rm -rf /var/lib/docker /var/lib/containerd
}

remove_state() {
    log '5/5' '正在删除本项目的安装记录…'
    rm -rf "${STATE_DIR}"
    log 'DONE' '代理及本脚本安装的依赖已卸载完成。'
}

main() {
    parse_args "${1:-}"
    require_root
    load_install_state
    remove_heartbeat_service
    remove_proxy_service
    remove_tailscale
    remove_docker
    remove_state
}

main "$@"
