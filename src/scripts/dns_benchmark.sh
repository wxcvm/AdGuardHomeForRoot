#!/system/bin/sh
##############################################################################
# dns_benchmark.sh — DNS 服务器测速工具
# 功能：
#   1. 预置常见 DNS 服务器列表（国内/国际/DoH/DoT 等）
#   2. 批量 Ping 测延迟 + DNS 解析测实际响应时间
#   3. 按速度排序输出排行榜
#   4. 可选：自动更新 AdGuardHome.yaml 使用最快上游
#   5. 支持自定义 DNS 列表
#   6. 仅对可用 DNS 进行深入测试（避免无意义的超时等待）
#
# 用法：
#   dns_benchmark.sh quick       — 快速测试（仅 ping 前 5 个）
#   dns_benchmark.sh full        — 完整测试所有 DNS
#   dns_benchmark.sh apply       — 用最快 DNS 更新配置
#   dns_benchmark.sh custom "1.1.1.1 8.8.8.8" — 自定义列表
##############################################################################

. /data/adb/agh/settings.conf 2>/dev/null
. /data/adb/agh/scripts/base.sh 2>/dev/null || {
  language="zh"
}

# -------------------------------------------
# DNS 测试列表（名称|类型|地址）
# 类型: plain / doh / dot / doq
# -------------------------------------------
_DNS_LIST='114DNS|plain|114.114.114.114
AliDNS|plain|223.5.5.5
AliDNS2|plain|223.6.6.6
DNSPod|plain|119.29.29.29
BaiduDNS|plain|180.76.76.76
360DNS|plain|101.226.4.6
Google|plain|8.8.8.8
Google2|plain|8.8.4.4
Cloudflare|plain|1.1.1.1
Cloudflare2|plain|1.0.0.1
Quad9|plain|9.9.9.9
OpenDNS|plain|208.67.222.222
AliDNS_DoH|doh|https://223.5.5.5/dns-query
DNSPod_DoH|doh|https://1.12.12.12/dns-query
Cloudflare_DoH|doh|https://1.1.1.1/dns-query
Google_DoH|doh|https://8.8.8.8/dns-query
Quad9_DoH|doh|https://9.9.9.9/dns-query
'

# 测速结果临时文件
_RESULT_FILE="$AGH_DIR/dns_benchmark_result.tmp"
[ -z "$AGH_DIR" ] && _RESULT_FILE="/data/adb/agh/dns_benchmark_result.tmp"

# -------------------------------------------
# ping_latency — 测 ICMP 延迟
# 参数: IP
# 返回: 平均延迟(ms)，失败返回 9999
# -------------------------------------------
ping_latency() {
  local ip="$1"
  local result
  # 快速 ping 3 个包，超时 2 秒
  result=$(busybox ping -c 3 -W 2 "$ip" 2>/dev/null | tail -1)
  if [ -n "$result" ]; then
    # 提取 avg 值，格式: round-trip min/avg/max = x.xx/yy.yy/z.zz ms
    local avg=$(echo "$result" | awk -F'/' '{print $5}')
    if [ -n "$avg" ]; then
      printf "%.0f" "$avg"
      return 0
    fi
  fi
  echo "9999"
}

# -------------------------------------------
# dns_resolve_time — 测 DNS 实际解析时间
# 参数: DNS_IP domain
# 返回: 解析时间(ms)，失败返回 9999
# -------------------------------------------
dns_resolve_time() {
  local dns_ip="$1"
  local domain="${2:-www.baidu.com}"
  local start end elapsed

  start=$(busybox date +%s%3N 2>/dev/null || date +%s%3N 2>/dev/null || echo "0")
  busybox nslookup "$domain" "$dns_ip" >/dev/null 2>&1
  end=$(busybox date +%s%3N 2>/dev/null || date +%s%3N 2>/dev/null || echo "0")

  if [ "$start" = "0" ] || [ "$end" = "0" ]; then
    # 日期精度不够，用 time 命令兜底
    local output
    output=$( { time busybox nslookup "$domain" "$dns_ip" >/dev/null 2>&1; } 2>&1 )
    elapsed=$(echo "$output" | grep real | awk '{print $2}')
    if [ -z "$elapsed" ]; then
      echo "9999"; return
    fi
    # 转换秒为毫秒
    elapsed=$(echo "$elapsed" | sed 's/s//')
    elapsed=$(echo "$elapsed * 1000" | bc 2>/dev/null || echo "9999")
    printf "%.0f" "$elapsed"
    return
  fi

  elapsed=$((end - start))
  if [ "$elapsed" -gt 0 ] && [ "$elapsed" -lt 10000 ]; then
    echo "$elapsed"
  else
    echo "9999"
  fi
}

# -------------------------------------------
# quick_reachability — 快速可达性检测
# 仅测试 DNS 是否可达（TCP 端口 53）
# -------------------------------------------
quick_reachability() {
  local ip="$1"
  if busybox timeout 2 nc -z "$ip" 53 2>/dev/null; then
    return 0
  fi
  if ping -c 1 -W 1 "$ip" >/dev/null 2>&1; then
    return 0
  fi
  return 1
}

# -------------------------------------------
# run_benchmark — 执行完整测速
# 参数: full (完整) / quick (快速)
# -------------------------------------------
run_benchmark() {
  local mode="${1:-quick}"
  local test_count=0
  local skip_count=0

  echo ""
  echo "╔══════════════════════════════════════════════╗"
  echo "║       AdGuardHome DNS 测速工具               ║"
  echo "╚══════════════════════════════════════════════╝"
  echo ""
  echo "模式: $([ "$mode" = "full" ] && echo '完整测试 (所有 DNS)' || echo '快速测试 (仅常用 DNS)')"
  echo ""

  # 清空结果文件
  > "$_RESULT_FILE"

  OLD_IFS="$IFS"
  IFS=$'\n'
  for entry in $_DNS_LIST; do
    local name=$(echo "$entry" | cut -d'|' -f1)
    local type=$(echo "$entry" | cut -d'|' -f2)
    local addr=$(echo "$entry" | cut -d'|' -f3)

    # 快速模式跳过 DoT/DoQ 和国际 DNS
    if [ "$mode" = "quick" ]; then
      case "$name" in
        *DoH|*DoT|Google*|Cloudflare*|Quad9*|OpenDNS*) skip_count=$((skip_count + 1)); continue ;;
      esac
    fi

    # 提取 IP 用于 ping
    local ip="$addr"
    case "$type" in
      doh|dot) ip=$(echo "$addr" | sed 's|https://||;s|/.*||;s|:.*||') ;;
    esac

    echo -n "  [${name}] 检测中..."

    # 快速可达性检测
    if [ "$type" = "plain" ]; then
      if ! quick_reachability "$ip"; then
        echo " ❌ 不可达"
        echo "$name|$type|$addr|9999|9999|0" >> "$_RESULT_FILE"
        continue
      fi
    fi

    # Ping 测延迟
    local ping_ms=9999
    if [ "$type" = "plain" ] || [ -n "$ip" ]; then
      ping_ms=$(ping_latency "$ip")
    fi

    # DNS 解析测时
    local dns_ms=9999
    if [ "$type" = "plain" ]; then
      dns_ms=$(dns_resolve_time "$ip" "www.baidu.com")
      # 再测一个国际域名
      local dns2_ms
      dns2_ms=$(dns_resolve_time "$ip" "www.google.com")
      [ "$dns2_ms" != "9999" ] && dns_ms=$(( (dns_ms + dns2_ms) / 2 ))
    fi

    # 综合评分 (ping 权重 30% + dns 权重 70%)
    local score=9999
    if [ "$ping_ms" != "9999" ] && [ "$dns_ms" != "9999" ]; then
      score=$(echo "$ping_ms * 0.3 + $dns_ms * 0.7" | bc 2>/dev/null || echo "9999")
    elif [ "$ping_ms" != "9999" ]; then
      score=$ping_ms
    elif [ "$dns_ms" != "9999" ]; then
      score=$dns_ms
    fi
    score=$(printf "%.0f" "$score" 2>/dev/null || echo "9999")

    # 状态显示
    local icon="✅"
    [ "$score" = "9999" ] && icon="❌"
    [ "$score" != "9999" ] && [ "$score" -lt 50 ] && icon="🟢"
    [ "$score" != "9999" ] && [ "$score" -ge 50 ] && [ "$score" -lt 100 ] && icon="🟡"
    [ "$score" != "9999" ] && [ "$score" -ge 100 ] && icon="🟠"

    echo " $icon ping=${ping_ms}ms dns=${dns_ms}ms 综合=${score}ms"

    echo "$name|$type|$addr|$ping_ms|$dns_ms|$score" >> "$_RESULT_FILE"
    test_count=$((test_count + 1))
  done
  IFS="$OLD_IFS"

  # 打印排行榜
  echo ""
  echo "════════════════════════════════════════════════"
  echo "  📊 DNS 速度排行榜 (按综合延迟排序)"
  echo "════════════════════════════════════════════════"
  echo ""

  local rank=0
  # 按综合分数升序排列
  sort -t'|' -k6 -n "$_RESULT_FILE" 2>/dev/null | while IFS='|' read name type addr ping_ms dns_ms score; do
    rank=$((rank + 1))
    if [ "$score" = "0" ] || [ "$score" = "9999" ]; then
      printf "  %2d. %-18s ❌ 不可达\n" "$rank" "$name"
    else
      local medal=""
      [ "$rank" -eq 1 ] && medal="🥇"
      [ "$rank" -eq 2 ] && medal="🥈"
      [ "$rank" -eq 3 ] && medal="🥉"
      printf "  %s%2d. %-18s %4sms (ping=%sms, dns=%sms)\n" \
        "$medal" "$rank" "$name" "$score" "$ping_ms" "$dns_ms"
    fi
  done

  echo ""
  echo "════════════════════════════════════════════════"
  echo "  共测试 $test_count 个 DNS 服务器"
  if [ "$mode" = "quick" ]; then
    echo "  快速模式已跳过 $skip_count 个 (DoH/国际DNS)"
  fi
  echo "════════════════════════════════════════════════"
  echo ""
  echo "💡 使用以下命令自动应用最快 DNS:"
  echo "   /data/adb/agh/scripts/dns_benchmark.sh apply"
  echo ""
}

# -------------------------------------------
# get_best_dns — 获取测速最快的前 N 个 DNS
# 参数: 返回数量 (默认 3)
# 输出: "名称|类型|地址" 每行一个
# -------------------------------------------
get_best_dns() {
  local count="${1:-3}"
  sort -t'|' -k6 -n "$_RESULT_FILE" 2>/dev/null | \
    grep -v '9999' | \
    head -n "$count"
}

# -------------------------------------------
# apply_best_dns — 自动更新配置
# -------------------------------------------
apply_best_dns() {
  local yaml="/data/adb/agh/bin/AdGuardHome.yaml"

  if [ ! -f "$_RESULT_FILE" ] || ! grep -q '|' "$_RESULT_FILE" 2>/dev/null; then
    echo "❌ 请先运行测速: /data/adb/agh/scripts/dns_benchmark.sh full"
    return 1
  fi

  if [ ! -f "$yaml" ]; then
    echo "❌ 未找到 AdGuardHome.yaml"
    return 1
  fi

  echo "🔍 正在分析测速结果..."
  echo ""

  # 获取前三快的 DNS
  local best
  best=$(get_best_dns 3)

  if [ -z "$best" ]; then
    echo "❌ 没有可用的 DNS 结果"
    return 1
  fi

  # 备份当前配置
  cp "$yaml" "${yaml}.bak.$(date +%Y%m%d%H%M%S)"

  # 显示推荐
  echo ""
  echo "推荐最快 DNS:"
  OLD_IFS="$IFS"
  IFS=$'\n'
  for line in $best; do
    local name=$(echo "$line" | cut -d'|' -f1)
    local addr=$(echo "$line" | cut -d'|' -f3)
    echo "  ✅ $name: $addr"
  done
  IFS="$OLD_IFS"
  echo ""

  echo "⚠️  Auto-apply to yaml requires sed. Applying first plain DNS to bootstrap..."
  
  # 获取第一个 plain 类型的 DNS 用于 bootstrap
  local first_plain="223.5.5.5"
  IFS=$'\n'
  for line in $best; do
    local type=$(echo "$line" | cut -d'|' -f2)
    local addr=$(echo "$line" | cut -d'|' -f3)
    if [ "$type" = "plain" ]; then
      first_plain="$addr"
      break
    fi
  done
  IFS="$OLD_IFS"

  # 生成新 YAML DNS 配置段（使用 sed 替换）
  local new_upstreams_line="  upstream_dns:"
  IFS=$'\n'
  for line in $best; do
    local type=$(echo "$line" | cut -d'|' -f2)
    local addr=$(echo "$line" | cut -d'|' -f3)
    new_upstreams_line="$new_upstreams_line\\n    - $addr"
  done
  IFS="$OLD_IFS"

  # 替换 upstream_dns 段
  sed -i "/upstream_dns:/,/upstream_dns_file:/ {
    /upstream_dns:/!{/upstream_dns_file:/!d}
  }" "$yaml"

  # 写入新的
  sed -i "s|upstream_dns:|upstream_dns:\n    - ${first_plain}|" "$yaml"

  echo ""
  echo "✅ 配置文件已更新！原配置已备份"
  echo "⚠️  请打开 Web 面板 http://127.0.0.1:3000 手动添加推荐的 DNS："
  echo ""
  echo "  设置 → DNS 设置 → 上游 DNS 服务器"
  echo ""
  OLD_IFS="$IFS"
  IFS=$'\n'
  for line in $best; do
    local name=$(echo "$line" | cut -d'|' -f1)
    local addr=$(echo "$line" | cut -d'|' -f3)
    echo "    $addr  ($name)"
  done
  IFS="$OLD_IFS"
}

# -------------------------------------------
# custom_benchmark — 自定义 DNS 测速
# -------------------------------------------
custom_benchmark() {
  local custom="$1"
  if [ -z "$custom" ]; then
    echo "用法: $0 custom \"1.1.1.1 8.8.8.8 223.5.5.5\""
    return 1
  fi

  echo ""
  echo "📡 自定义 DNS 测速"
  echo ""

  > "$_RESULT_FILE"

  local rank=0
  for ip in $custom; do
    rank=$((rank + 1))
    echo -n "  [$rank] $ip ..."

    if ! quick_reachability "$ip"; then
      echo " ❌ 不可达"
      continue
    fi

    local ping_ms=$(ping_latency "$ip")
    local dns_ms=$(dns_resolve_time "$ip" "www.baidu.com")

    local score=9999
    if [ "$ping_ms" != "9999" ] && [ "$dns_ms" != "9999" ]; then
      score=$(echo "$ping_ms * 0.3 + $dns_ms * 0.7" | bc 2>/dev/null || echo "9999")
    elif [ "$ping_ms" != "9999" ]; then
      score=$ping_ms
    elif [ "$dns_ms" != "9999" ]; then
      score=$dns_ms
    fi
    score=$(printf "%.0f" "$score" 2>/dev/null || echo "9999")

    local icon="✅"
    [ "$score" = "9999" ] && icon="❌"
    [ "$score" != "9999" ] && [ "$score" -lt 50 ] && icon="🟢"

    echo " $icon ping=${ping_ms}ms dns=${dns_ms}ms 综合=${score}ms"
    echo "Custom_$rank|plain|$ip|$ping_ms|$dns_ms|$score" >> "$_RESULT_FILE"
  done

  echo ""
  echo "💡 应用最快结果: $0 apply"
}

# -------------------------------------------
# CLI 入口
# -------------------------------------------
case "$1" in
  quick)
    run_benchmark "quick"
    ;;
  full)
    echo "⏳ 完整测试可能需要 2-5 分钟，请耐心等待..."
    run_benchmark "full"
    ;;
  apply)
    apply_best_dns
    ;;
  best)
    get_best_dns "${2:-3}"
    ;;
  custom)
    custom_benchmark "$2"
    ;;
  *)
    echo "AdGuardHome For Root — DNS 测速工具"
    echo "用法: $0 {quick|full|apply|best|custom}"
    echo ""
    echo "  quick        — 快速测试 (仅国内常用 DNS, 约30秒)"
    echo "  full         — 完整测试 (全部 DNS, 约2-5分钟)"
    echo "  apply        — 自动将最快 DNS 写入 AdGuardHome 配置"
    echo "  best [N]     — 显示最快的 N 个 DNS"
    echo "  custom 'IPs' — 自定义 DNS 列表测速"
    echo ""
    echo "示例:"
    echo "  $0 quick"
    echo "  $0 full && $0 apply"
    echo "  $0 custom '1.1.1.1 8.8.8.8 223.5.5.5'"
    ;;
esac