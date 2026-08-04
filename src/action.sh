#!/system/bin/sh
##############################################################################
# action.sh — 用户快捷操作入口
# 功能：从模块管理中点击操作按钮时触发
# 默认：显示模块状态 + 开关切换
# 
# 可用操作（修改此处切换）：
#   toggle  → 开关切换
#   status  → 显示运行状态
#   panel   → 打开交互控制面板
#   report  → 显示代理感知报告
##############################################################################

. /data/adb/agh/settings.conf

echo ""
echo "==== AdGuardHome For Root ===="
$SCRIPT_DIR/tool.sh status
echo ""

$SCRIPT_DIR/tool.sh toggle

sleep 1
