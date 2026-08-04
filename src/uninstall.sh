#!/system/bin/sh
##############################################################################
# uninstall.sh — 卸载清理脚本
# 功能：彻底删除 AdGuardHome 及所有残留（进程、iptables、日志）
##############################################################################

echo "[AdGuardHome] Stopping AdGuardHome..."
pkill -f "AdGuardHome" 2>/dev/null
pkill -9 -f "AdGuardHome" 2>/dev/null

echo "[AdGuardHome] Removing iptables rules..."
SCRIPT_DIR="/data/adb/agh/scripts"
if [ -f "$SCRIPT_DIR/iptables.sh" ]; then
  . "$SCRIPT_DIR/iptables.sh" 2>/dev/null || true
  disable_iptables_chain "iptables -w 64" "ADGUARD_REDIRECT_DNS" 2>/dev/null
  disable_iptables_chain "ip6tables -w 64" "ADGUARD_REDIRECT_DNS6" 2>/dev/null
  del_block_ipv6_dns 2>/dev/null
fi

echo "[AdGuardHome] Removing /data/adb/agh..."
[ -d "/data/adb/agh" ] && rm -rf "/data/adb/agh"

echo "[AdGuardHome] Cleanup complete."
