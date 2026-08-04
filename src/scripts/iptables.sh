#!/system/bin/sh
##############################################################################
# iptables.sh — DNS 流量劫持管理器
# 功能：
#   enable  — 创建 iptables/ip6tables NAT 规则，将 DNS (53端口) 重定向到 AdGuardHome
#   disable — 删除所有相关 iptables 链和规则
#
# 原理：
#   - 在 nat 表 OUTPUT 链插入自定义链 ADGUARD_REDIRECT_DNS
#   - 绕过规则：AdGuardHome 自身流量 (by uid/gid) + 用户自定义白名单
#   - UDP/TCP 53 端口流量通过 REDIRECT 目标转发到 redir_port (默认 5591)
#   - IPv6：支持 NAT 时走 REDIRECT，否则 block_ipv6_dns 直接 DROP IPv6 DNS
#
# 自定义链结构 (IPv4):
#   ADGUARD_REDIRECT_DNS
#     ├── RETURN (owner: root/net_raw — 绕过 AGH 自身)
#     ├── RETURN (dst: ignore_dest_list)
#     ├── RETURN (src: ignore_src_list)
#     ├── REDIRECT (udp:53 → redir_port)
#     └── REDIRECT (tcp:53 → redir_port)
#
# 自定义链结构 (IPv6 block 模式):
#   ADGUARD_BLOCK_DNS (filter 表)
#     ├── DROP (udp:53)
#     └── DROP (tcp:53)
##############################################################################

. /data/adb/agh/settings.conf
. /data/adb/agh/scripts/base.sh

# 使用 -w 64 参数避免 iptables 锁竞争（最长等待 64 秒）
iptables_w="iptables -w 64"
ip6tables_w="ip6tables -w 64"

# -------------------------------------------
# check_ipv6_nat_support — 检测 IPv6 NAT 是否支持 REDIRECT 目标
# 返回: 0=支持, 1=不支持
# -------------------------------------------
check_ipv6_nat_support() {
  if ! $ip6tables_w -t nat -L >/dev/null 2>&1; then
    # IPv6 NAT table not available
    return 1
  fi

  local redirect_ok=false
  # 使用高位端口做测试（避免影响正常服务）
  if $ip6tables_w -t nat -A PREROUTING -p tcp --dport 65534 -j REDIRECT --to-port 65534 >/dev/null 2>&1; then
    redirect_ok=true
    $ip6tables_w -t nat -D PREROUTING -p tcp --dport 65534 -j REDIRECT --to-port 65534 >/dev/null 2>&1
  fi

  if $redirect_ok; then
    return 0
  else
    return 1
  fi
}

# -------------------------------------------
# enable_iptables_chain — 创建并应用 iptables 自定义链
# 参数: iptables_cmd chain_name
# 失败时返回 1
# -------------------------------------------
enable_iptables_chain() {
  local iptables_cmd=$1
  local chain_name=$2

  # 检查链是否已存在
  if $iptables_cmd -t nat -L $chain_name >/dev/null 2>&1; then
    log "$chain_name chain already exists — ensuring OUTPUT jump" "$chain_name 链已存在 — 确保 OUTPUT 跳转"
    # 确保 OUTPUT 链中存在跳转到自定义链的规则
    if ! $iptables_cmd -t nat -C OUTPUT -j $chain_name >/dev/null 2>&1; then
      $iptables_cmd -t nat -I OUTPUT -j $chain_name
    fi
    return 0
  fi

  log "Creating $chain_name chain and adding redirect rules" "创建 $chain_name 链并添加重定向规则"

  # 创建自定义链
  $iptables_cmd -t nat -N $chain_name || return 1

  # 绕过 AdGuardHome 自身流量
  $iptables_cmd -t nat -A $chain_name -m owner --uid-owner $adg_user --gid-owner $adg_group -j RETURN || return 1

  # 添加用户自定义绕过目标地址
  for subnet in $ignore_dest_list; do
    if ! $iptables_cmd -t nat -A $chain_name -d $subnet -j RETURN >/dev/null 2>&1; then
      log "Warning: Failed to add bypass for $subnet" "警告: 无法为 $subnet 添加绕过规则"
    fi
  done

  # 添加用户自定义绕过源地址
  for subnet in $ignore_src_list; do
    if ! $iptables_cmd -t nat -A $chain_name -s $subnet -j RETURN >/dev/null 2>&1; then
      log "Warning: Failed to add bypass for source $subnet" "警告: 无法为源 $subnet 添加绕过规则"
    fi
  done

  # UDP DNS 重定向
  $iptables_cmd -t nat -A $chain_name -p udp --dport 53 -j REDIRECT --to-ports $redir_port || return 1
  # TCP DNS 重定向
  $iptables_cmd -t nat -A $chain_name -p tcp --dport 53 -j REDIRECT --to-ports $redir_port || return 1

  # 插入到 OUTPUT 链最前面（优先于其他规则）
  $iptables_cmd -t nat -I OUTPUT -j $chain_name || return 1

  log "Applied $chain_name rules successfully" "成功应用 $chain_name 规则"
  return 0
}

# -------------------------------------------
# disable_iptables_chain — 删除自定义链及所有关联
# -------------------------------------------
disable_iptables_chain() {
  local iptables_cmd=$1
  local chain_name=$2

  log "Removing $chain_name chain and rules" "正在移除 $chain_name 链及规则"
  $iptables_cmd -t nat -D OUTPUT -j $chain_name >/dev/null 2>&1
  $iptables_cmd -t nat -F $chain_name >/dev/null 2>&1
  $iptables_cmd -t nat -X $chain_name >/dev/null 2>&1
  return 0
}

# -------------------------------------------
# add_block_ipv6_dns — 创建 IPv6 DNS 阻断链（filter 表）
# 适用于 IPv6 NAT 不支持的设备，直接 DROP 所有 IPv6 DNS
# -------------------------------------------
add_block_ipv6_dns() {
  if $ip6tables_w -t filter -L ADGUARD_BLOCK_DNS >/dev/null 2>&1; then
    log "ADGUARD_BLOCK_DNS chain already exists" "ADGUARD_BLOCK_DNS 链已存在"
    if ! $ip6tables_w -t filter -C OUTPUT -j ADGUARD_BLOCK_DNS >/dev/null 2>&1; then
      $ip6tables_w -t filter -I OUTPUT -j ADGUARD_BLOCK_DNS
    fi
    return 0
  fi

  log "Creating ADGUARD_BLOCK_DNS chain" "正在创建 ADGUARD_BLOCK_DNS 链"
  $ip6tables_w -t filter -N ADGUARD_BLOCK_DNS || return 1
  $ip6tables_w -t filter -A ADGUARD_BLOCK_DNS -p udp --dport 53 -j DROP || return 1
  $ip6tables_w -t filter -A ADGUARD_BLOCK_DNS -p tcp --dport 53 -j DROP || return 1
  $ip6tables_w -t filter -I OUTPUT -j ADGUARD_BLOCK_DNS || return 1

  log "Applied IPv6 DNS blocking rules" "成功应用 IPv6 DNS 阻断规则"
  return 0
}

# -------------------------------------------
# del_block_ipv6_dns — 删除 IPv6 DNS 阻断链
# -------------------------------------------
del_block_ipv6_dns() {
  log "Removing ADGUARD_BLOCK_DNS chain" "正在移除 ADGUARD_BLOCK_DNS 链"
  $ip6tables_w -t filter -D OUTPUT -j ADGUARD_BLOCK_DNS >/dev/null 2>&1
  $ip6tables_w -t filter -F ADGUARD_BLOCK_DNS >/dev/null 2>&1
  $ip6tables_w -t filter -X ADGUARD_BLOCK_DNS >/dev/null 2>&1
  return 0
}

# -------------------------------------------
# enable_ipv6_iptables — IPv6 NAT 劫持模式
# -------------------------------------------
enable_ipv6_iptables() {
  if ! check_ipv6_nat_support; then
    log "IPv6 NAT not supported — skipping IPv6 DNS hijack" "IPv6 NAT 不支持 — 跳过 IPv6 DNS 劫持"
    return 0
  fi
  enable_iptables_chain "$ip6tables_w" "ADGUARD_REDIRECT_DNS6"
}

# -------------------------------------------
# disable_ipv6_iptables — IPv6 NAT 清理
# -------------------------------------------
disable_ipv6_iptables() {
  if ! check_ipv6_nat_support; then
    return 0
  fi
  disable_iptables_chain "$ip6tables_w" "ADGUARD_REDIRECT_DNS6"
}

# -------------------------------------------
# CLI 入口
# -------------------------------------------
case "$1" in
  enable)
    log "Enabling iptables DNS hijack" "启用 iptables DNS 劫持"
    enable_iptables_chain "$iptables_w" "ADGUARD_REDIRECT_DNS" || exit 1

    if [ "$block_ipv6_dns" = true ]; then
      log "IPv6 DNS mode: block (DROP)" "IPv6 DNS 模式: block (丢弃)"
      add_block_ipv6_dns || exit 1
    else
      log "IPv6 DNS mode: hijack (NAT REDIRECT)" "IPv6 DNS 模式: hijack (劫持)"
      enable_ipv6_iptables || exit 1
    fi
    ;;
  disable)
    log "Disabling iptables DNS hijack" "禁用 iptables DNS 劫持"
    disable_iptables_chain "$iptables_w" "ADGUARD_REDIRECT_DNS"
    del_block_ipv6_dns
    disable_ipv6_iptables
    ;;
  *)
    echo "AdGuardHome For Root — iptables DNS 劫持管理"
    echo "用法: $0 {enable|disable}"
    ;;
esac