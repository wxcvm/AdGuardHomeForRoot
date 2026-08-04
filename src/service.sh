#!/system/bin/sh
##############################################################################
# service.sh — 开机自启脚本
# 功能：
#   1. 等待系统启动完成（弹窗动画停止）
#   2. 启动 AdGuardHome 服务
#   3. 部署文件监听（inotifyd）以感知模块启停
#   4. 可选：启动时自动生成代理感知报告
##############################################################################

# 等待系统启动动画结束（最多等 5 分钟）
retries=0
until [ "$(getprop init.svc.bootanim 2>/dev/null)" = "stopped" ]; do
  sleep 12
  retries=$((retries + 1))
  if [ $retries -gt 25 ]; then
    # 5 分钟超时后强制启动
    break
  fi
done

# 额外等待网络就绪（WiFi / 蜂窝数据）
sleep 5

# 启动 AdGuardHome
/data/adb/agh/scripts/tool.sh start &

# 部署 inotifyd 文件监听：
#   模块目录发生变更时自动响应 (如模块禁用/启用)
#   - d: disable (模块目录被删除 → 禁用模块 → 启动 AGH 重新绑定)
#   - n: new (模块目录恢复 → 启用模块 → 停止 AGH)
inotifyd /data/adb/agh/scripts/inotify.sh /data/adb/modules/AdGuardHome:d,n &
