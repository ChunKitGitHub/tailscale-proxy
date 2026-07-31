#!/bin/sh
# OpenWrt / ImmortalWrt Tailscale 网关安装脚本。
#
# 功能：
#   1. 安装并开机启动 Tailscale；
#   2. 首次运行时从终端读取 Auth Key（不写入文件）；
#   3. 持久化 LAN <-> tailscale0 转发、tailscale0 入站放行及 NAT 规则；
#   4. 广播 LAN 子网路由（TAILSCALE_ADVERTISE_ROUTES 可覆盖，设为 none 关闭；
#      改动后需在 Tailscale 管理后台批准）；
#   5. 检测到 PassWall 时写入兼容配置：关闭"路由器本机代理"（否则 tailscaled
#      的 STUN/DERP/WireGuard UDP 会被 TPROXY 进代理，DERP 误选美国）、
#      排除 LAN 客户端的 UDP 3478/41641、控制面域名加入直连列表。
#
# 不会广播 100.64.0.0/10。Windows 等未安装 Tailscale 的 LAN 客户端，
# 通过本机默认网关/静态路由和 NAT 访问 Spot 的 Tailscale IP。

set -eu

PATH='/usr/sbin:/usr/bin:/sbin:/bin'
FIREWALL_SCRIPT='/etc/firewall.tailscale-forwarding'
LEGACY_NFT_FIREWALL_SCRIPT='/etc/nftables.d/90-tailscale-forwarding.nft'
MAGICDNS_STATE_FILE='/etc/tailscale-magicdns-domain'
FIREWALL_INCLUDE='tailscale_forwarding'
TAILSCALE_AUTH_KEY="${TAILSCALE_AUTH_KEY:-}"
TAILSCALE_ADVERTISE_ROUTES="${TAILSCALE_ADVERTISE_ROUTES:-auto}"
FORCE_TAILSCALE_RELOGIN="${FORCE_TAILSCALE_RELOGIN:-0}"
FIREWALL_BACKEND=''
MAGICDNS_SUFFIX=''
MAGICDNS_SELF_NAME=''

log() {
    printf '[%s] %s\n' "$1" "$2"
}

die() {
    log 'ERROR' "$1" >&2
    exit 1
}

require_root() {
    [ "$(id -u)" -eq 0 ] || die '请以 root 身份运行。'
}

ensure_iptables() {
    command -v iptables >/dev/null 2>&1 && command -v ip6tables >/dev/null 2>&1 && return

    log '1/6' '未检测到完整的 iptables/ip6tables，正在安装双栈兼容包…'
    opkg update
    opkg install iptables-nft ip6tables-nft 2>/dev/null || opkg install iptables ip6tables
    command -v iptables >/dev/null 2>&1 && command -v ip6tables >/dev/null 2>&1 \
        || die 'iptables/ip6tables 安装失败；请确认系统软件源可用。'
}

detect_firewall_backend() {
    # ImmortalWrt / OpenWrt 22.03+ 通常使用 firewall4 (nftables)。
    # 使用原生 nft 规则，避免 iptables-legacy 与 fw4 规则集互不相见。
    if command -v nft >/dev/null 2>&1 && nft list table inet fw4 >/dev/null 2>&1; then
        FIREWALL_BACKEND='nft'
        log 'INFO' '检测到 firewall4/nftables，将使用原生 nft 转发规则。'
    else
        FIREWALL_BACKEND='iptables'
        log 'INFO' '未检测到 firewall4，将使用 iptables 转发规则。'
        ensure_iptables
    fi
}

ensure_tailscale() {
    if ! command -v tailscale >/dev/null 2>&1; then
        log '2/6' '正在安装 Tailscale…'
        opkg update
        opkg install tailscale
    else
        log '2/6' 'Tailscale 已安装。'
    fi

    [ -x /etc/init.d/tailscale ] || die '未找到 /etc/init.d/tailscale，Tailscale 安装不完整。'
    /etc/init.d/tailscale enable
    /etc/init.d/tailscale start
}

update_tailscale() {
    log '2/6' '正在更新 Tailscale 到可用的最新版本…'

    # tailscale update --yes 等同于交互时确认 y。OpenWrt 的 opkg 版本较旧时，
    # 由 Tailscale 自更新器下载并替换二进制；失败则保留 opkg 版本继续工作。
    if tailscale update --yes; then
        /etc/init.d/tailscale restart
        log '2/6' "Tailscale 当前版本：$(tailscale version | sed -n '1p')"
    else
        log 'WARN' "Tailscale 自更新失败，继续使用 opkg 版本：$(tailscale version | sed -n '1p')"
    fi
}

read_auth_key() {
    [ -n "${TAILSCALE_AUTH_KEY}" ] && return
    [ -r /dev/tty ] || die '非交互运行时必须设置 TAILSCALE_AUTH_KEY 环境变量。'

    printf '请输入 Tailscale Auth Key（输入不会显示）：' >/dev/tty
    stty -echo </dev/tty
    if ! IFS= read -r TAILSCALE_AUTH_KEY </dev/tty; then
        stty echo </dev/tty
        printf '\n' >/dev/tty
        die '未读取到 Auth Key。'
    fi
    stty echo </dev/tty
    printf '\n' >/dev/tty
    [ -n "${TAILSCALE_AUTH_KEY}" ] || die 'Auth Key 不能为空。'
}

should_relogin() {
    [ "${FORCE_TAILSCALE_RELOGIN}" = '1' ] && return 0
    [ -r /dev/tty ] || return 1

    printf '检测到已有 Tailscale 身份。是否用新的 Auth Key 重新注册此设备？[y/N] ' >/dev/tty
    answer=''
    IFS= read -r answer </dev/tty || true
    case "${answer}" in
        y|Y|yes|YES) return 0 ;;
        *) return 1 ;;
    esac
}

connect_tailscale() {
    if tailscale ip -4 >/dev/null 2>&1 && tailscale ip -6 >/dev/null 2>&1; then
        log '3/6' "Tailscale 已连接，IPv4: $(tailscale ip -4 | sed -n '1p')，IPv6: $(tailscale ip -6 | sed -n '1p')"
        if ! should_relogin; then
            log 'INFO' '保留现有 Tailscale 身份。'
            return
        fi
        log 'INFO' '正在退出旧 Tailnet 身份并重新注册…'
        tailscale logout
    fi

    read_auth_key
    log '3/6' '正在加入 Tailscale…'
    # login 仅处理身份认证，不会要求把旧 hostname、路由等所有偏好重新列出。
    tailscale login --auth-key="${TAILSCALE_AUTH_KEY}"
    tailscale ip -4 >/dev/null 2>&1 || die 'Tailscale 未能获取 IPv4 地址，请检查 Auth Key 和网络。'
    tailscale ip -6 >/dev/null 2>&1 || die 'Tailscale 未能获取 IPv6 地址，请检查 Auth Key 和网络。'
    log '3/6' "Tailscale 已连接，IPv4: $(tailscale ip -4 | sed -n '1p')，IPv6: $(tailscale ip -6 | sed -n '1p')"
}

configure_routes() {
    # 广播 LAN 子网路由，让 tailnet 内其他设备能访问家里局域网。
    # tailscale set 会整体覆盖路由列表，同时清掉旧教程遗留的 100.64.0.0/10。
    # TAILSCALE_ADVERTISE_ROUTES=none 跳过；auto（默认）自动探测 br-lan 网段。
    routes="${TAILSCALE_ADVERTISE_ROUTES}"
    if [ "${routes}" = 'auto' ]; then
        routes="$(ip -4 route show dev br-lan proto kernel 2>/dev/null \
            | awk '$1 ~ /\// { print $1; exit }')"
        [ -n "${routes}" ] || {
            log 'WARN' '未能探测到 br-lan 子网，跳过子网路由广播。'
            return
        }
    fi
    if [ "${routes}" = 'none' ]; then
        log 'INFO' '按配置跳过子网路由广播。'
        return
    fi
    tailscale set --advertise-routes="${routes}" \
        || die "广播子网路由 ${routes} 失败。"
    log 'INFO' "已广播子网路由：${routes}（首次需在 Tailscale 管理后台批准）。"
}

configure_magicdns() {
    status_json=''
    suffix=''
    self_dns_name=''
    self_host_name=''
    old_suffix=''

    log 'INFO' '正在配置 OpenWrt 和 LAN 的 Tailscale MagicDNS…'
    tailscale set --accept-dns=true \
        || log 'WARN' '无法启用 Tailscale accept-dns，将继续配置 dnsmasq 条件转发。'

    status_json="$(tailscale status --json 2>/dev/null || true)"
    if command -v jsonfilter >/dev/null 2>&1; then
        suffix="$(printf '%s' "${status_json}" | jsonfilter -e '@.MagicDNSSuffix' 2>/dev/null || true)"
        self_dns_name="$(printf '%s' "${status_json}" | jsonfilter -e '@.Self.DNSName' 2>/dev/null || true)"
        self_host_name="$(printf '%s' "${status_json}" | jsonfilter -e '@.Self.HostName' 2>/dev/null || true)"
    fi
    if [ -z "${suffix}" ]; then
        suffix="$(printf '%s\n' "${status_json}" \
            | sed -n 's/.*"MagicDNSSuffix"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' \
            | sed -n '1p')"
    fi
    if [ -z "${self_dns_name}" ]; then
        self_dns_name="$(printf '%s\n' "${status_json}" \
            | sed -n 's/.*"DNSName"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' \
            | sed -n '1p')"
    fi
    if [ -z "${self_host_name}" ]; then
        self_host_name="$(printf '%s\n' "${status_json}" \
            | sed -n 's/.*"HostName"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' \
            | sed -n '1p')"
    fi
    suffix="${suffix%.}"
    case "${suffix}" in
        ''|*[!A-Za-z0-9.-]*)
            log 'WARN' '未能读取有效的 MagicDNS 后缀；完整域名需要由现有 DNS 配置解析。'
            return
            ;;
    esac
    self_dns_name="${self_dns_name%.}"
    if [ -z "${self_dns_name}" ] && [ -n "${self_host_name}" ]; then
        self_dns_name="${self_host_name%.}.${suffix}"
    fi
    MAGICDNS_SUFFIX="${suffix}"
    MAGICDNS_SELF_NAME="${self_dns_name}"

    [ -x /etc/init.d/dnsmasq ] || {
        log 'WARN' '未检测到 dnsmasq，跳过 LAN MagicDNS 转发配置。'
        return
    }
    if [ -f "${MAGICDNS_STATE_FILE}" ]; then
        old_suffix="$(sed -n '1p' "${MAGICDNS_STATE_FILE}")"
    fi
    if [ -n "${old_suffix}" ]; then
        uci -q del_list "dhcp.@dnsmasq[0].server=/${old_suffix}/100.100.100.100" || true
        uci -q del_list "dhcp.@dnsmasq[0].rebind_domain=${old_suffix}" || true
        uci -q del_list "dhcp.@dnsmasq[0].rebind_domain=/${old_suffix}/" || true
        if [ "$(uci -q get dhcp.lan 2>/dev/null || true)" = 'dhcp' ]; then
            uci -q del_list "dhcp.lan.dhcp_option=15,${old_suffix}" || true
            uci -q del_list "dhcp.lan.dhcp_option=119,${old_suffix}" || true
        fi
    fi

    uci -q del_list "dhcp.@dnsmasq[0].server=/${suffix}/100.100.100.100" || true
    uci add_list "dhcp.@dnsmasq[0].server=/${suffix}/100.100.100.100"
    uci -q del_list "dhcp.@dnsmasq[0].rebind_domain=${suffix}" || true
    uci -q del_list "dhcp.@dnsmasq[0].rebind_domain=/${suffix}/" || true
    uci add_list "dhcp.@dnsmasq[0].rebind_domain=/${suffix}/"
    if [ "$(uci -q get dhcp.lan 2>/dev/null || true)" = 'dhcp' ]; then
        uci -q del_list "dhcp.lan.dhcp_option=15,${suffix}" || true
        uci add_list "dhcp.lan.dhcp_option=15,${suffix}"
        uci -q del_list "dhcp.lan.dhcp_option=119,${suffix}" || true
        uci add_list "dhcp.lan.dhcp_option=119,${suffix}"
    fi
    uci commit dhcp
    printf '%s\n' "${suffix}" >"${MAGICDNS_STATE_FILE}"
    chmod 0600 "${MAGICDNS_STATE_FILE}"
    /etc/init.d/dnsmasq restart
    log 'INFO' "MagicDNS 已转发到 100.100.100.100，域名后缀：${suffix}"
    log 'INFO' 'LAN 客户端需重新获取 DHCP 租约后，才会取得短名称搜索后缀。'
}

verify_magicdns() {
    [ -n "${MAGICDNS_SUFFIX}" ] || return
    command -v nslookup >/dev/null 2>&1 || {
        log 'WARN' '未找到 nslookup，无法自动验证 MagicDNS；请手动查询完整域名。'
        return
    }
    [ -n "${MAGICDNS_SELF_NAME}" ] || die 'MagicDNS 已写入 dnsmasq，但无法读取本机完整 DNS 名称进行验证。'

    expected_ipv4="$(tailscale ip -4 | sed -n '1p')"
    lookup_result="$(nslookup "${MAGICDNS_SELF_NAME}" 127.0.0.1 2>&1 || true)"
    if ! printf '%s\n' "${lookup_result}" | grep -F "${expected_ipv4}" >/dev/null; then
        printf '%s\n' "${lookup_result}" >&2
        die "MagicDNS 验证失败：dnsmasq 无法将 ${MAGICDNS_SELF_NAME} 解析到 ${expected_ipv4}。请检查 dhcp.@dnsmasq[0].server 和 100.100.100.100。"
    fi
    log 'INFO' "MagicDNS 验证通过：${MAGICDNS_SELF_NAME} -> ${expected_ipv4}"
}

write_firewall_script() {
    log '4/6' '正在写入持久化 Tailscale 转发规则…'
    # 清理早期版本写入的错误 nftables include；fw4 会自动加载
    # /etc/nftables.d/*.nft，遗留文件会阻止整个防火墙重载。
    rm -f "${LEGACY_NFT_FIREWALL_SCRIPT}"

    if [ "${FIREWALL_BACKEND}" = 'nft' ]; then
        cat >"${FIREWALL_SCRIPT}" <<'EOF'
#!/bin/sh
# 由 openwrt-install.sh 管理。fw4 启动/重载完成后执行本文件。

PATH='/usr/sbin:/usr/bin:/sbin:/bin'

replace_nft_rule() {
    action="$1"
    chain="$2"
    marker="$3"
    shift 3

    # 旧版脚本将 accept 规则追加在 forward 链末尾，可能落在 fw4 的
    # 默认 reject 之后。先按 comment 找到并删除旧规则，再按正确位置插入。
    handles="$(nft -a list chain inet fw4 "${chain}" 2>/dev/null \
        | sed -n "/${marker}/s/.*# handle \([0-9][0-9]*\).*/\1/p")"
    for handle in ${handles}; do
        nft delete rule inet fw4 "${chain}" handle "${handle}"
    done

    nft "${action}" rule inet fw4 "${chain}" "$@" comment "\"${marker}\""
}

# 允许 LAN 客户端经 OpenWrt 转发到 Spot 的 Tailscale 地址；
# MASQUERADE 保证 Spot 的回包返回本 OpenWrt，再由 conntrack 交还 LAN 客户端。
# input 放行是必需的：fw4 input 链默认 policy drop，tailscale 自己表里的
# accept 拦不住 fw4 的 reject，缺了这条就无法从 tailnet 访问 OpenWrt 本机。
replace_nft_rule insert input tailscale-input iifname '"tailscale0"' accept
replace_nft_rule insert forward tailscale-forward-in iifname '"tailscale0"' accept
replace_nft_rule insert forward tailscale-forward-out oifname '"tailscale0"' accept
replace_nft_rule add srcnat tailscale-srcnat oifname '"tailscale0"' masquerade
EOF
        chmod 0755 "${FIREWALL_SCRIPT}"
        return
    fi

    cat >"${FIREWALL_SCRIPT}" <<'EOF'
#!/bin/sh
# 由 openwrt-install.sh 管理。此文件会在 firewall 启动/重载时执行。

PATH='/usr/sbin:/usr/bin:/sbin:/bin'

ensure_rule() {
	command="$1"
	table="$2"
	chain="$3"
	shift 3
	"${command}" -t "${table}" -C "${chain}" "$@" 2>/dev/null || \
		"${command}" -t "${table}" -I "${chain}" "$@"
}

# 允许 LAN 客户端经 OpenWrt 转发到 Spot 的 Tailscale 地址；
# MASQUERADE 保证 Spot 的回包返回本 OpenWrt，再由 conntrack 交还 LAN 客户端。
# INPUT 放行保证可以从 tailnet 访问 OpenWrt 本机（LuCI/SSH）。
ensure_rule iptables filter INPUT -i tailscale0 -j ACCEPT
ensure_rule iptables filter FORWARD -i tailscale0 -j ACCEPT
ensure_rule iptables filter FORWARD -o tailscale0 -j ACCEPT
ensure_rule iptables nat POSTROUTING -o tailscale0 -j MASQUERADE
ensure_rule ip6tables filter INPUT -i tailscale0 -j ACCEPT
ensure_rule ip6tables filter FORWARD -i tailscale0 -j ACCEPT
ensure_rule ip6tables filter FORWARD -o tailscale0 -j ACCEPT
ensure_rule ip6tables nat POSTROUTING -o tailscale0 -j MASQUERADE
EOF
    chmod 0755 "${FIREWALL_SCRIPT}"
}

configure_firewall_include() {
    command -v uci >/dev/null 2>&1 || die '未找到 UCI，当前系统不是标准 OpenWrt/ImmortalWrt。'

    # 首次安装时该 section 不存在；-q 只是不输出错误，仍会返回非零。
    # 必须显式忽略这个预期结果，才能继续创建 include。
    uci -q delete "firewall.${FIREWALL_INCLUDE}" || true
    uci set "firewall.${FIREWALL_INCLUDE}=include"
    if [ "${FIREWALL_BACKEND}" = 'nft' ]; then
        # fw4 的 nftables include 是规则集片段，不接受 "nft add rule" 命令。
        # 用 script include 在 fw4 规则集就绪后执行原生 nft 命令。
        uci set "firewall.${FIREWALL_INCLUDE}.type=script"
        uci set "firewall.${FIREWALL_INCLUDE}.path=${FIREWALL_SCRIPT}"
    else
        uci set "firewall.${FIREWALL_INCLUDE}.type=script"
        uci set "firewall.${FIREWALL_INCLUDE}.path=${FIREWALL_SCRIPT}"
    fi
    uci set "firewall.${FIREWALL_INCLUDE}.reload=1"
    uci commit firewall
}

apply_firewall_rules() {
    log '5/6' '正在加载防火墙规则…'
    [ -x /etc/init.d/firewall ] || die '未找到 OpenWrt firewall 服务。'
    /etc/init.d/firewall restart
    # firewall 重启可能清理 Tailscale 自己维护的 netfilter 规则，重启一次
    # tailscaled 让它重新写入；身份状态保存在本机，不会要求再次输入 Auth Key。
    /etc/init.d/tailscale restart
    "${FIREWALL_SCRIPT}"
}

configure_passwall_compat() {
    # PassWall 与 Tailscale 共存的三处必要排除，全部幂等：
    #   1. 关闭"路由器本机代理"。PassWall 的 PSW_RULE 会用 ct mark 覆盖
    #      tailscaled 的 0x80000 逃逸标记再 TPROXY，导致 STUN/DERP/WireGuard
    #      全部绕道代理出口（DERP 误选美国、NAT 探测抖动）。DERP 地址表内嵌
    #      IP 不走 DNS，直连域名列表拦不住，只能关本机代理；LAN 客户端翻墙
    #      走的是 client_proxy（PREROUTING 链），不受影响。
    #   2. UDP 不转发端口加 3478/41641，豁免 LAN 上 Tailscale 客户端
    #      （Mac/iPhone 等）的 STUN 探测与 WireGuard 直连。
    #   3. 控制面域名加直连列表（对 controlplane 的 TCP 443 有效）。
    uci -q get passwall.@global[0] >/dev/null 2>&1 || return 0
    log 'INFO' '检测到 PassWall，正在检查 Tailscale 兼容配置…'
    changed=0

    if [ "$(uci -q get passwall.@global[0].localhost_proxy || echo '1')" != '0' ]; then
        uci set passwall.@global[0].localhost_proxy='0'
        changed=1
        log 'INFO' '已关闭 PassWall 路由器本机代理（不影响 LAN 客户端代理）。'
    fi

    current="$(uci -q get passwall.@global_forwarding[0].udp_no_redir_ports || true)"
    wanted="${current}"
    case "${wanted}" in
        ''|disable) wanted='3478,41641' ;;
    esac
    case ",${wanted}," in
        *,3478,*) ;;
        *) wanted="${wanted},3478" ;;
    esac
    case ",${wanted}," in
        *,41641,*) ;;
        *) wanted="${wanted},41641" ;;
    esac
    if [ "${wanted}" != "${current}" ]; then
        uci set passwall.@global_forwarding[0].udp_no_redir_ports="${wanted}"
        changed=1
        log 'INFO' "PassWall UDP 不转发端口已设为：${wanted}"
    fi

    direct_host='/usr/share/passwall/rules/direct_host'
    if [ -f "${direct_host}" ]; then
        for domain in tailscale.com ts.net; do
            if ! grep -qx "${domain}" "${direct_host}"; then
                printf '%s\n' "${domain}" >>"${direct_host}"
                changed=1
                log 'INFO' "已将 ${domain} 加入 PassWall 直连域名列表。"
            fi
        done
    fi

    if [ "${changed}" = '1' ]; then
        uci commit passwall
        /etc/init.d/passwall restart
        # 让 tailscaled 丢弃经代理测得的 DERP 延迟，重新探测。
        /etc/init.d/tailscale restart
        log 'INFO' 'PassWall 兼容配置已应用，PassWall 与 Tailscale 已重启。'
    else
        log 'INFO' 'PassWall 兼容配置已就绪，无需修改。'
    fi
}

verify() {
    log '6/6' '正在验证…'
    verify_magicdns
    if [ "${FIREWALL_BACKEND}" = 'nft' ]; then
        nft list chain inet fw4 input | grep -F 'tailscale0' >/dev/null \
            || die 'tailscale0 入站放行规则未生效。'
        nft list chain inet fw4 forward | grep -F 'tailscale0' >/dev/null \
            || die 'tailscale0 转发规则未生效。'
        nft list chain inet fw4 srcnat | grep -F 'tailscale0' >/dev/null \
            || die 'tailscale0 NAT 规则未生效。'
        printf '\n部署完成。\n'
		printf 'Tailscale IPv4: %s\n' "$(tailscale ip -4 | sed -n '1p')"
		printf 'Tailscale IPv6: %s\n' "$(tailscale ip -6 | sed -n '1p')"
        printf '重启后规则由 %s 自动恢复。\n' "${FIREWALL_SCRIPT}"
        printf 'Windows 可通过本 OpenWrt 的默认网关，访问已获授权的 Spot Tailscale IP:1080。\n'
        return
    fi

    iptables -C INPUT -i tailscale0 -j ACCEPT || die 'tailscale0 入站放行规则未生效。'
    iptables -C FORWARD -i tailscale0 -j ACCEPT || die 'tailscale0 入站转发规则未生效。'
    iptables -C FORWARD -o tailscale0 -j ACCEPT || die 'tailscale0 出站转发规则未生效。'
    iptables -t nat -C POSTROUTING -o tailscale0 -j MASQUERADE || die 'tailscale0 NAT 规则未生效。'
    ip6tables -C FORWARD -i tailscale0 -j ACCEPT || die 'tailscale0 IPv6 入站转发规则未生效。'
    ip6tables -C FORWARD -o tailscale0 -j ACCEPT || die 'tailscale0 IPv6 出站转发规则未生效。'
    ip6tables -t nat -C POSTROUTING -o tailscale0 -j MASQUERADE || die 'tailscale0 IPv6 NAT 规则未生效。'

    printf '\n部署完成。\n'
    printf 'Tailscale IPv4: %s\n' "$(tailscale ip -4 | sed -n '1p')"
    printf 'Tailscale IPv6: %s\n' "$(tailscale ip -6 | sed -n '1p')"
    printf '重启后规则由 %s 自动恢复。\n' "${FIREWALL_SCRIPT}"
    printf 'Windows 可通过本 OpenWrt 的默认网关，访问已获授权的 Spot Tailscale IP:1080。\n'
}

main() {
    require_root
    command -v opkg >/dev/null 2>&1 || die '此脚本仅支持 OpenWrt / ImmortalWrt。'
    detect_firewall_backend
    ensure_tailscale
    update_tailscale
    connect_tailscale
    configure_routes
    configure_magicdns
    write_firewall_script
    configure_firewall_include
    apply_firewall_rules
    configure_passwall_compat
    verify
}

main "$@"
