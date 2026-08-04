#!/system/bin/sh
##############################################################################
# proxy_manager.sh — 代理检测、冲突管理与控制面板
# 功能：
#   1. detect_proxy()         — 检测设备上已安装的代理应用/模块
#   2. check_conflict()       — 检查与 DNS 劫持是否冲突
#   3. generate_proxy_report()— 生成可读的代理状态报告
#   4. control_panel()        — 终端交互式控制面板（查看/切换模式）
#   5. auto_compat_mode()     — 自动检测并建议兼容配置
##############################################################################

. /data/adb/agh/settings.conf
. /data/adb/agh/scripts/base.sh

# -------------------------------------------
# 已知代理应用/模块特征检测表
# 格式: "检测名称|检测命令|描述"
# -------------------------------------------
_PROXY_PROFILES="
Clash|pgrep -f clash|Clash 代理客户端
ClashMeta|pgrep -f clash.meta|Clash Meta 代理
V2Ray|pgrep -x v2ray|V2Ray 代理核心
NekoBox|pgrep -f nekoray|NekoBox 代理客户端
SurfBoard|pgrep -f surfboard|SurfBoard 代理
Shadowsocks|pgrep -x ss-local|Shadowsocks 本地代理
HttpProxy|netstat -tlnp 2>/dev/null | grep -q ':10809\|:7890\|:8118\|:8888'|HTTP 代理(端口 10809/7890/8118/8888)
SocksProxy|netstat -tlnp 2>/dev/null | grep -q ':1080\|:10808\|:7891'|Socks5 代理
TunMode|ip link show | grep -qE 'tun[0-9]'|TUN 模式已启用(可能接管全部流量)
VPNMode|ip link show | grep -qE 'ppp[0-9]|tun[0-9].*OPENVPN|wg[0-9]'|VPN 隧道检测
MagiskModule|ls /data/adb/modules/ 2>/dev/null | grep -qiE 'clash|v2ray|proxy|surfboard|nekoray|nekobox|shadowsocks'|Magisk 代理模块已安装
"

# -------------------------------------------
# detect_proxy — 逐一检测已知代理
# 输出: 用换行分隔的 "名称|描述" 列表
# 返回: 0=未检测到代理, 1=检测到至少一个代理
# -------------------------------------------
function detect_proxy() {
  local found=0
  OLD_IFS="$IFS"
  IFS=$'\n'

  for profile in $_PROXY_PROFILES; do
    local name=$(echo "$profile" | cut -d'|' -f1)
    local check=$(echo "$profile" | cut -d'|' -f2)
    local desc=$(echo "$profile" | cut -d'|' -f3)

    if eval "$check" 2>/dev/null; then
      echo "$name|$desc"
      found=1
    fi
  done

  IFS="$OLD_IFS"
  return $(( (found == 0) ? 0 : 1 ))
}

# -------------------------------------------
# check_conflict — 检查是否与 AdGuardHome 冲突
# 原理：
#   - 如果存在 TUN/VPN 模式代理，它们可能已经接管了 DNS
#   - 如果代理同时监听 53 端口，直接冲突
#   - 如果代理有内置 DNS 过滤，可能重复过滤
# 返回: 0=无冲突, 1=可能冲突, 2=确定冲突
# -------------------------------------------
function check_conflict() {
  local level=0

  # 检测 TUN 模式（代理已接管所有流量，DNS 重定向无效）
  if ip link show 2>/dev/null | grep -qE 'tun[0-9]'; then
    [ $level -lt 2 ] && level=2
    log "⚠️ TUN mode detected — DNS hijack may be ineffective" "⚠️ 检测到 TUN 模式 — DNS 劫持可能无效"
  fi

  # 检测 53 端口占用
  if busybox netstat -tlnp 2>/dev/null | grep -q ':53 '; then
    [ $level -lt 2 ] && level=2
    log "⚠️ Port 53 already in use — direct conflict" "⚠️ 端口 53 已被占用 — 直接冲突"
  fi

  # 检测 VPN 模式
  if ip link show 2>/dev/null | grep -qE 'ppp[0-9]|tun[0-9].*OPENVPN|wg[0-9]'; then
    [ $level -lt 1 ] && level=1
  fi

  # 检查代理是否有内置 DNS（这些应用独立处理 DNS）
  if pgrep -f "clash.*dns" >/dev/null 2>&1 || \
     pgrep -f "v2ray.*dns"  >/dev/null 2>&1; then
    [ $level -lt 1 ] && level=1
  fi

  return $level
}

# -------------------------------------------
# generate_proxy_report — 生成可读报告
# -------------------------------------------
function generate_proxy_report() {
  echo "========================================"
  echo "  AdGuardHome For Root — 代理感知报告"
  echo "========================================"
  echo ""

  local proxies
  proxies=$(detect_proxy)
  local proxy_count=$?

  if [ $proxy_count -eq 0 ]; then
    log "No proxy detected — safe to use default mode" "未检测到代理 — 可以安全使用默认模式"
    echo "[✓] 未检测到已知代理应用/模块"
    echo ""
    echo "建议模式: local_only (本机 DNS 过滤)"
  else
    echo "[!] 检测到以下代理/网络接管:"
    echo ""
    OLD_IFS="$IFS"
    IFS=$'\n'
    for line in $proxies; do
      local name=$(echo "$line" | cut -d'|' -f1)
      local desc=$(echo "$line" | cut -d'|' -f2)
      echo "  • $name — $desc"
    done
    IFS="$OLD_IFS"
    echo ""

    check_conflict
    local level=$?

    case $level in
      0)
        echo "冲突等级: 🟢 低 — 代理与 AdGuardHome 可共存"
        echo "建议模式: local_only (本机 DNS 过滤)"
        echo "说明: 代理处理应用层流量，AdGuardHome 处理 DNS，互不干扰"
        ;;
      1)
        echo "冲突等级: 🟡 中 — 可能重复过滤或 DNS 绕行"
        echo "建议模式: manual_dns (手动在代理中上游 DNS 指向 127.0.0.1:5591)"
        echo "说明: 代理可能独立处理 DNS，建议在代理配置中指向 AdGuardHome"
        ;;
      2)
        echo "冲突等级: 🔴 高 — TUN/VPN 模式已接管所有流量"
        echo "建议模式: disable_iptables (关闭 AdGuardHome DNS 劫持)"
        echo "说明: TUN 模式下 iptables DNS 重定向无效，建议二选一："
        echo "  方案A) 关闭代理的 DNS 功能，在代理中设置上游 DNS 为 127.0.0.1:5591"
        echo "  方案B) 关闭 AdGuardHome iptables 劫持 (enable_iptables=false)"
        ;;
    esac
    echo ""
  fi

  echo "----------------------------------------"
  echo "当前 AdGuardHome 模式:"
  local mode="${listen_mode:-local_only}"
  case "$mode" in
    local_only)
      echo "  📱 本机模式 — DNS 仅监听 127.0.0.1"
      echo "     其他设备无法使用此 DNS 服务"
      ;;
    lan_only)
      echo "  🌐 局域网模式 — DNS 监听 0.0.0.0:53"
      echo "     局域网设备可指向本机 IP 使用 DNS"
      ;;
    lan_both)
      echo "  🏠 混合模式 — DNS 监听 0.0.0.0:53 + Web 面板可从局域网访问"
      ;;
  esac

  echo ""
  echo "是否启用 iptables DNS 劫持: ${enable_iptables:-true}"
  echo "DNS 重定向端口: ${redir_port:-5591}"
  echo "Web 面板地址: http://127.0.0.1:3000"
  echo "========================================"
}

# -------------------------------------------
# control_panel — 终端交互式控制面板
# 用法: proxy_manager.sh panel
# -------------------------------------------
function control_panel() {
  while true; do
    echo ""
    echo "╔══════════════════════════════════════════════╗"
    echo "║      AdGuardHome For Root — 控制面板         ║"
    echo "╠══════════════════════════════════════════════╣"
    echo "║    📊 信息查看                               ║"
    echo "║  1) 查看代理感知报告                         ║"
    echo "║  2) 查看当前状态                             ║"
    echo "║  3) 查看最近日志 (30行)                      ║"
    echo "║                                              ║"
    echo "║    ⚙️ 模式控制                               ║"
    echo "║  4) 切换 DNS 监听模式                        ║"
    echo "║  5) 切换 iptables 劫持开关                   ║"
    echo "║  6) 自动适配代理模式                         ║"
    echo "║  7) 重启 AdGuardHome                         ║"
    echo "║                                              ║"
    echo "║    🚀 DNS 测速                               ║"
    echo "║  8) 快速 DNS 测速 (国内 ~30秒)               ║"
    echo "║  9) 完整 DNS 测速 (全部 ~2分钟)              ║"
    echo "║  A) 查看最快 DNS 结果                        ║"
    echo "║  B) 应用最快 DNS 到配置                      ║"
    echo "║                                              ║"
    echo "║  0) 退出                                     ║"
    echo "╚══════════════════════════════════════════════╝"
    echo -n "请选择 [0-9/A/B]: "
    read choice
    # 转大写
    choice=$(echo "$choice" | tr 'a-z' 'A-Z')

    case "$choice" in
      1) generate_proxy_report ;;
      2) status_panel ;;
      3) [ -f "/data/adb/agh/history.log" ] && tail -30 "/data/adb/agh/history.log" || echo "暂无日志" ;;
      4)
        echo "当前模式: ${listen_mode:-local_only}"
        echo "可选: 1) local_only  2) lan_only  3) lan_both"
        echo -n "选择: "
        read m
        case "$m" in
          1) set_listen_mode "local_only" ;;
          2) set_listen_mode "lan_only" ;;
          3) set_listen_mode "lan_both" ;;
          *) echo "无效选择" ;;
        esac
        ;;
      5)
        if [ "${enable_iptables}" = "true" ]; then
          echo "iptables DNS 劫持当前: 开启 → 要关闭吗? (y/n)"
          read ans
          [ "$ans" = "y" ] && /data/adb/agh/scripts/tool.sh iptables_off
        else
          echo "iptables DNS 劫持当前: 关闭 → 要开启吗? (y/n)"
          read ans
          [ "$ans" = "y" ] && /data/adb/agh/scripts/tool.sh iptables_on
        fi
        ;;
      6) auto_compat_mode ;;
      7) /data/adb/agh/scripts/tool.sh restart ;;
      8)
        if [ -x "/data/adb/agh/scripts/dns_benchmark.sh" ]; then
          /data/adb/agh/scripts/dns_benchmark.sh quick
        else
          echo "❌ DNS 测速脚本未安装"
        fi
        ;;
      9)
        if [ -x "/data/adb/agh/scripts/dns_benchmark.sh" ]; then
          /data/adb/agh/scripts/dns_benchmark.sh full
        else
          echo "❌ DNS 测速脚本未安装"
        fi
        ;;
      A)
        if [ -x "/data/adb/agh/scripts/dns_benchmark.sh" ]; then
          echo "📊 最快的 5 个 DNS:"
          /data/adb/agh/scripts/dns_benchmark.sh best 5
        else
          echo "❌ DNS 测速脚本未安装"
        fi
        ;;
      B)
        if [ -x "/data/adb/agh/scripts/dns_benchmark.sh" ]; then
          /data/adb/agh/scripts/dns_benchmark.sh apply
        else
          echo "❌ DNS 测速脚本未安装"
        fi
        ;;
      0) break ;;
      *) echo "无效选择" ;;
    esac
  done
}

# -------------------------------------------
# set_listen_mode — 切换 DNS 监听模式
# 参数: local_only / lan_only / lan_both
# -------------------------------------------
function set_listen_mode() {
  local mode="$1"
  local yaml="/data/adb/agh/bin/AdGuardHome.yaml"

  if [ ! -f "$yaml" ]; then
    log "Error: AdGuardHome.yaml not found" "错误: 未找到 AdGuardHome.yaml"
    return 1
  fi

  # 备份原配置
  cp "$yaml" "${yaml}.bak" 2>/dev/null

  case "$mode" in
    local_only)
      log "Setting DNS mode: local_only (127.0.0.1 only)" "设置 DNS 模式: local_only (仅本机)"
      # 修改 DNS bind_hosts
      sed -i '/bind_hosts:/,/port:/{/ -/d}' "$yaml"
      sed -i '/bind_hosts:/a\    - 127.0.0.1' "$yaml"
      # Web 面板仅监听本地
      sed -i "s/address: .*/address: 127.0.0.1:3000/" "$yaml"
      # 清空 allowed_clients
      sed -i '/allowed_clients:/,/disallowed_clients:/{/^  [a-z]/!{s/\[.*\]/\[\]/}}' "$yaml"
      ;;
    lan_only)
      log "Setting DNS mode: lan_only (0.0.0.0:53 for LAN)" "设置 DNS 模式: lan_only (局域网可访问 DNS)"
      sed -i '/bind_hosts:/,/port:/{/ -/d}' "$yaml"
      sed -i '/bind_hosts:/a\    - 0.0.0.0' "$yaml"
      # Web 面板仍仅本地
      sed -i "s/address: .*/address: 127.0.0.1:3000/" "$yaml"
      # 放行局域网
      sed -i '/allowed_clients:/,/disallowed_clients:/{/^  [a-z]/!{s/\[.*\]/\[192.168.0.0\/16, 10.0.0.0\/8, 172.16.0.0\/12\]/}}' "$yaml"
      ;;
    lan_both)
      log "Setting DNS mode: lan_both (DNS + Web accessible)" "设置 DNS 模式: lan_both (DNS + Web 均可达)"
      sed -i '/bind_hosts:/,/port:/{/ -/d}' "$yaml"
      sed -i '/bind_hosts:/a\    - 0.0.0.0' "$yaml"
      # Web 面板也监听所有接口
      sed -i "s/address: .*/address: 0.0.0.0:3000/" "$yaml"
      # 放行局域网
      sed -i '/allowed_clients:/,/disallowed_clients:/{/^  [a-z]/!{s/\[.*\]/\[192.168.0.0\/16, 10.0.0.0\/8, 172.16.0.0\/12\]/}}' "$yaml"
      ;;
    *)
      log "Unknown mode: $mode" "未知模式: $mode"
      return 1
      ;;
  esac

  # 更新 settings.conf
  sed -i "s/^listen_mode=.*/listen_mode=\"$mode\"/" /data/adb/agh/settings.conf 2>/dev/null

  log "Mode changed to $mode. Please restart AdGuardHome" "模式已切换为 $mode，请重启 AdGuardHome"
  echo "✅ 模式已切换为: $mode"
  echo "⚠️  需要重启 AdGuardHome 生效: /data/adb/agh/scripts/tool.sh restart"
}

# -------------------------------------------
# auto_compat_mode — 自动检测并调整为兼容模式
# -------------------------------------------
function auto_compat_mode() {
  echo "🔍 正在检测网络环境..."
  echo ""

  local proxies
  proxies=$(detect_proxy)
  local has_proxy=$?

  check_conflict
  local level=$?

  if [ $has_proxy -eq 0 ]; then
    echo "✅ 未检测到代理 — 保持当前配置"
    set_listen_mode "local_only"
  elif [ $level -eq 0 ]; then
    echo "🟢 代理低冲突 — 保持 local_only 模式"
    set_listen_mode "local_only"
  elif [ $level -eq 1 ]; then
    echo "🟡 代理中冲突 — 建议关闭 iptables 劫持 + 代理中配置 DNS 指向 127.0.0.1:5591"
    sed -i "s/^enable_iptables=.*/enable_iptables=false/" /data/adb/agh/settings.conf 2>/dev/null
    set_listen_mode "local_only"
  else
    echo "🔴 代理高冲突 (TUN/VPN 模式) — 关闭 iptables 劫持"
    sed -i "s/^enable_iptables=.*/enable_iptables=false/" /data/adb/agh/settings.conf 2>/dev/null
    set_listen_mode "local_only"
    echo ""
    echo "⚠️  TUN 模式下 DNS 劫持无效。建议:"
    echo "  方案A: 在代理配置中将 DNS 上游改为 http://127.0.0.1:5591/dns-query"
    echo "  方案B: 关闭代理内 DNS，仅用 AdGuardHome 处理 DNS"
  fi

  echo ""
  echo "🔄 重启 AdGuardHome 以应用变更..."
  /data/adb/agh/scripts/tool.sh restart
}

# -------------------------------------------
# status_panel — 显示当前运行状态摘要
# -------------------------------------------
function status_panel() {
  echo "========================================"
  echo "  AdGuardHome 状态面板"
  echo "========================================"
  echo ""

  # 运行状态
  if [ -f /data/adb/agh/bin/agh.pid ]; then
    local pid=$(cat /data/adb/agh/bin/agh.pid)
    if ps | grep -w "$pid" | grep -q "AdGuardHome"; then
      echo "🟢 AdGuardHome: 运行中 [PID: $pid]"
    else
      echo "🔴 AdGuardHome: 已停止 (PID 文件残留)"
    fi
  else
    echo "🔴 AdGuardHome: 已停止"
  fi

  # Root 方式
  echo "Root 方案: $(get_root_method)"

  # 监听模式
  echo "DNS 模式: ${listen_mode:-local_only}"

  # iptables 状态
  if iptables -t nat -L ADGUARD_REDIRECT_DNS >/dev/null 2>&1; then
    echo "iptables 劫持: 🟢 已启用"
  else
    echo "iptables 劫持: 🔴 已禁用"
  fi

  # 网络状态
  if check_network; then
    echo "网络连通: 🟢 正常"
  else
    echo "网络连通: 🔴 异常"
  fi

  # 代理状态
  local proxies
  proxies=$(detect_proxy)
  if [ $? -eq 1 ]; then
    echo ""
    echo "检测到代理:"
    OLD_IFS="$IFS"
    IFS=$'\n'
    for line in $proxies; do
      local name=$(echo "$line" | cut -d'|' -f1)
      echo "  • $name"
    done
    IFS="$OLD_IFS"
  else
    echo "代理状态: 未检测到"
  fi

  echo ""
  echo "Web 面板: http://127.0.0.1:3000"
  echo "日志文件: /data/adb/agh/history.log"
  echo "========================================"
}

# -------------------------------------------
# CLI 入口
# -------------------------------------------
case "$1" in
  detect)
    detect_proxy
    ;;
  conflict)
    check_conflict
    exit $?
    ;;
  report)
    generate_proxy_report
    ;;
  panel)
    control_panel
    ;;
  auto)
    auto_compat_mode
    ;;
  status)
    status_panel
    ;;
  mode)
    set_listen_mode "${2:-local_only}"
    ;;
  dns_quick)
    if [ -x "/data/adb/agh/scripts/dns_benchmark.sh" ]; then
      /data/adb/agh/scripts/dns_benchmark.sh quick
    else
      echo "❌ DNS 测速脚本未安装"
    fi
    ;;
  dns_full)
    if [ -x "/data/adb/agh/scripts/dns_benchmark.sh" ]; then
      /data/adb/agh/scripts/dns_benchmark.sh full
    else
      echo "❌ DNS 测速脚本未安装"
    fi
    ;;
  dns_best)
    if [ -x "/data/adb/agh/scripts/dns_benchmark.sh" ]; then
      /data/adb/agh/scripts/dns_benchmark.sh best "${2:-5}"
    else
      echo "❌ DNS 测速脚本未安装"
    fi
    ;;
  *)
    echo "AdGuardHome For Root — 控制中心"
    echo "用法: $0 {detect|conflict|report|panel|auto|status|mode|dns_quick|dns_full|dns_best}"
    echo ""
    echo "  📊 信息:"
    echo "    detect     — 检测已安装的代理"
    echo "    conflict   — 检查 DNS 冲突等级"
    echo "    report     — 生成完整代理感知报告"
    echo "    status     — 显示当前运行状态"
    echo ""
    echo "  ⚙️ 控制:"
    echo "    panel      — 打开交互式控制面板"
    echo "    auto       — 自动适配代理兼容模式"
    echo "    mode <x>   — 手动切换 DNS 监听模式 (local_only/lan_only/lan_both)"
    echo ""
    echo "  🚀 DNS 测速:"
    echo "    dns_quick  — 快速 DNS 测速 (国内 ~30秒)"
    echo "    dns_full   — 完整 DNS 测速 (全部 ~2分钟)"
    echo "    dns_best N — 查看最快的 N 个 DNS"
    ;;
esac
