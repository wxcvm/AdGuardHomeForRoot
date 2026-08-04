#!/system/bin/sh
##############################################################################
# tool.sh — AdGuardHome 主控脚本
# 功能：
#   start          — 启动 AdGuardHome + iptables（含代理冲突检测）
#   stop           — 停止 AdGuardHome + 清理 iptables
#   restart        — 重启
#   toggle         — 开关切换
#   iptables_on    — 单独开启 iptables 劫持
#   iptables_off   — 单独关闭 iptables 劫持
#   status         — 显示状态摘要
##############################################################################

. /data/adb/agh/settings.conf
. /data/adb/agh/scripts/base.sh

# -------------------------------------------
# move_to_system_cgroup — 将当前进程移至系统 cgroup
# 目的：防止被 Android 的 low memory killer 杀掉
# -------------------------------------------
move_to_system_cgroup() {
  echo $$ > /sys/fs/cgroup/cgroup.procs 2>/dev/null
  [ -f /dev/memcg/system/cgroup.procs ] && echo $$ > /dev/memcg/system/cgroup.procs 2>/dev/null
  [ -f /dev/cpuctl/system/cgroup.procs ] && echo $$ > /dev/cpuctl/system/cgroup.procs 2>/dev/null
  [ -f /dev/cpuset/system-background/cgroup.procs ] && echo $$ > /dev/cpuset/system-background/cgroup.procs 2>/dev/null
  [ -f /dev/blkio/cgroup.procs ] && echo $$ > /dev/blkio/cgroup.procs 2>/dev/null
}

# -------------------------------------------
# check_already_running — 通过 PID 文件 + 进程表验证
# 返回: 0=正在运行, 1=未运行
# -------------------------------------------
check_already_running() {
  if [ -f "$PID_FILE" ]; then
    local pid=$(cat "$PID_FILE" 2>/dev/null)
    if [ -n "$pid" ] && ps | grep -w "$pid" | grep -q "AdGuardHome"; then
      return 0
    fi
  fi
  # 兜底：没有 PID 文件但进程可能在跑
  if ps | grep -v grep | grep -q "AdGuardHome"; then
    # 清理残留 PID
    rm -f "$PID_FILE"
    return 0
  fi
  return 1
}

# -------------------------------------------
# start_adguardhome — 启动 AdGuardHome
# -------------------------------------------
start_adguardhome() {
  # 检查是否已在运行
  if check_already_running; then
    local pid=$(cat "$PID_FILE" 2>/dev/null)
    log "AdGuardHome is already running [PID: ${pid:-unknown}]" "AdGuardHome 已经在运行 [PID: ${pid:-unknown}]"
    return 0
  fi

  # 清除残留 PID 文件
  rm -f "$PID_FILE"

  # 代理自动适配（可选）
  if [ "${auto_proxy_detect}" = "true" ] && [ -x "$SCRIPT_DIR/proxy_manager.sh" ]; then
    log "Auto proxy detection enabled — checking..." "自动代理检测已启用 — 检查中..."
    # 仅生成报告，不强制修改配置
    $SCRIPT_DIR/proxy_manager.sh report | tee -a "$AGH_DIR/history.log"
  fi

  # 修复 AdGuardHome 在 Android 上的 SSL 证书问题
  export SSL_CERT_DIR="/system/etc/security/cacerts/"
  # 设置时区
  export TZ="$timezone"

  # 备份旧日志
  if [ -f "$AGH_DIR/bin.log" ]; then
    mv "$AGH_DIR/bin.log" "$AGH_DIR/bin.log.bak"
  fi

  # 检查二进制是否存在
  if [ ! -f "$BIN_DIR/AdGuardHome" ]; then
    log "Error: AdGuardHome binary not found at $BIN_DIR/AdGuardHome" "错误: 未找到 AdGuardHome 二进制: $BIN_DIR/AdGuardHome"
    return 1
  fi

  # 检查权限
  if [ ! -x "$BIN_DIR/AdGuardHome" ]; then
    chmod +x "$BIN_DIR/AdGuardHome"
  fi

  # 启动二进制（使用 setuidgid 以指定用户组运行）
  busybox setuidgid "$adg_user:$adg_group" "$BIN_DIR/AdGuardHome" >"$AGH_DIR/bin.log" 2>&1 &
  local adg_pid=$!

  # 等待进程完全启动（最多 5 秒）
  local retries=0
  while [ $retries -lt 50 ]; do
    if ps | grep -w "$adg_pid" | grep -q "AdGuardHome"; then
      echo "$adg_pid" >"$PID_FILE"
      break
    fi
    busybox usleep 100000
    retries=$((retries + 1))
  done

  # 验证启动结果
  if ps | grep -w "$adg_pid" | grep -q "AdGuardHome"; then
    # 启动成功，应用 iptables（如果启用）
    if [ "${enable_iptables}" = "true" ]; then
      if $SCRIPT_DIR/iptables.sh enable; then
        log "🟢 AdGuardHome is running [PID: $adg_pid] (iptables: enabled)" "🟢 AdGuardHome 运行中 [PID: $adg_pid] (iptables: 已启用)"
        update_description "🟢 Running [PID: $adg_pid] (iptables: ON)" "🟢 运行中 [PID: $adg_pid] (iptables: 开启)"
      else
        log "😭 Error occurred applying iptables" "😭 应用 iptables 规则时出错"
        update_description "🔴 Error: iptables failed" "🔴 错误: iptables 应用失败"
        $SCRIPT_DIR/iptables.sh disable
        return 1
      fi
    else
      log "🟢 AdGuardHome is running [PID: $adg_pid] (iptables: disabled)" "🟢 AdGuardHome 运行中 [PID: $adg_pid] (iptables: 已禁用)"
      update_description "🟢 Running [PID: $adg_pid] (iptables: OFF)" "🟢 运行中 [PID: $adg_pid] (iptables: 关闭)"
    fi
  else
    log "😭 Failed to start — check $AGH_DIR/bin.log" "😭 启动失败 — 检查 $AGH_DIR/bin.log"
    update_description "🔴 Failed to start" "🔴 启动失败"
    $SCRIPT_DIR/debug.sh
    return 1
  fi
}

# -------------------------------------------
# stop_adguardhome — 停止 AdGuardHome
# -------------------------------------------
stop_adguardhome() {
  # 先禁用 iptables
  $SCRIPT_DIR/iptables.sh disable 2>/dev/null

  if [ -f "$PID_FILE" ]; then
    local pid=$(cat "$PID_FILE")
    if [ -n "$pid" ]; then
      kill "$pid" 2>/dev/null || kill -9 "$pid" 2>/dev/null
      log "🔴 AdGuardHome stopped [PID: $pid]" "🔴 AdGuardHome 已停止 [PID: $pid]"
    fi
    rm -f "$PID_FILE"
  fi

  # 兜底：暴力杀所有残留进程
  pkill -f "AdGuardHome" 2>/dev/null || pkill -9 -f "AdGuardHome" 2>/dev/null

  update_description "🔴 Stopped" "🔴 已停止"
}

# -------------------------------------------
# toggle_adguardhome — 切换状态
# -------------------------------------------
toggle_adguardhome() {
  if check_already_running; then
    stop_adguardhome
  else
    start_adguardhome
  fi
}

# -------------------------------------------
# CLI 入口
# -------------------------------------------
move_to_system_cgroup

case "$1" in
  start)
    start_adguardhome
    ;;
  stop)
    stop_adguardhome
    ;;
  restart)
    log "Restarting AdGuardHome..." "重启 AdGuardHome..."
    stop_adguardhome
    sleep 2
    start_adguardhome
    ;;
  toggle)
    toggle_adguardhome
    ;;
  iptables_on)
    sed -i "s/^enable_iptables=.*/enable_iptables=true/" /data/adb/agh/settings.conf 2>/dev/null
    $SCRIPT_DIR/iptables.sh enable
    log "iptables DNS hijack: ON" "iptables DNS 劫持: 已开启"
    ;;
  iptables_off)
    sed -i "s/^enable_iptables=.*/enable_iptables=false/" /data/adb/agh/settings.conf 2>/dev/null
    $SCRIPT_DIR/iptables.sh disable
    log "iptables DNS hijack: OFF" "iptables DNS 劫持: 已关闭"
    ;;
  status)
    if check_already_running; then
      local pid=$(cat "$PID_FILE" 2>/dev/null)
      if iptables -t nat -L ADGUARD_REDIRECT_DNS >/dev/null 2>&1; then
        echo "🟢 Running [PID: $pid] (iptables: ON)"
      else
        echo "🟢 Running [PID: $pid] (iptables: OFF)"
      fi
    else
      echo "🔴 Stopped"
    fi
    ;;
  *)
    echo "AdGuardHome For Root — 主控工具"
    echo "用法: $0 {start|stop|restart|toggle|iptables_on|iptables_off|status}"
    echo ""
    echo "  start        — 启动 AdGuardHome"
    echo "  stop         — 停止 AdGuardHome"
    echo "  restart      — 重启"
    echo "  toggle       — 开关切换"
    echo "  iptables_on  — 单独开启 iptables DNS 劫持"
    echo "  iptables_off — 单独关闭 iptables DNS 劫持"
    echo "  status       — 显示运行状态"
    exit 1
    ;;
esac