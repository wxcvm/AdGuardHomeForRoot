##############################################################################
# base.sh — 基础函数库
# 功能：
#   1. 自动识别 Root 方案（Magisk / KernelSU / APatch）并补全 PATH
#   2. 中英双语自动切换（根据系统 locale）
#   3. log()      — 带时间戳的历史日志记录
#   4. update_description() — 更新模块描述（适配 Magisk/KSU/APatch API）
#   5. get_root_method()    — 返回当前 Root 方案名称
#   6. check_busybox()      — 检查 busybox 可用性
#   7. check_network()      — 检查网络连通性
##############################################################################

# -------------------------------------------
# 增强 PATH：自动探测所有可能的 busybox 路径
# -------------------------------------------
_add_busybox_paths() {
  local paths="
    /data/adb/magisk
    /data/adb/ksu/bin
    /data/adb/ap/bin
    /data/adb/modules/busybox-ndk/system/bin
    /system/xbin
    /system/bin
    /data/local/tmp/bin
  "
  for p in $paths; do
    [ -d "$p" ] && export PATH="$p:$PATH"
  done
}
_add_busybox_paths

# -------------------------------------------
# 中英双语支持
# -------------------------------------------
language="zh"
locale=""

# 尝试获取系统语言（兼容多种 prop 路径）
_get_locale() {
  locale=$(getprop persist.sys.locale 2>/dev/null || \
           getprop ro.product.locale 2>/dev/null || \
           getprop persist.sys.language 2>/dev/null || \
           getprop ro.product.language 2>/dev/null || \
           echo "en")
}
_get_locale

if echo "$locale" | grep -qi "en"; then
  language="en"
fi

# -------------------------------------------
# log — 带时间戳的记录到历史日志
# 用法: log "english" "中文"
# -------------------------------------------
function log() {
  local timestamp=$(date "+%Y-%m-%d %H:%M:%S")
  local str
  [ "$language" = "en" ] && str="$timestamp $1" || str="$timestamp $2"
  echo "$str" | tee -a "$AGH_DIR/history.log"
}

# -------------------------------------------
# update_description — 同步模块描述到管理器
# 自动适配 Magisk / KernelSU / APatch 的 API
# -------------------------------------------
function update_description() {
  local description
  [ "$language" = "en" ] && description="$1" || description="$2"
  local module_id
  module_id=$(grep "^id=" "$MOD_PATH/module.prop" | cut -d'=' -f2)
  if [ -x /data/adb/ksud ]; then
    MODULE_ID="$module_id" /data/adb/ksud module config set override.description "$description" 2>/dev/null
  elif [ -x /data/adb/apd ]; then
    MODULE_ID="$module_id" /data/adb/apd module config set override.description "$description" 2>/dev/null
  else
    sed -i "/^description=/c\description=$description" "$MOD_PATH/module.prop" 2>/dev/null
  fi
}

# -------------------------------------------
# get_root_method — 返回当前 Root 方案
# 输出: magisk / kernelsu / apatch / unknown
# -------------------------------------------
function get_root_method() {
  if [ -d "/data/adb/magisk" ]; then
    echo "magisk"
  elif [ -d "/data/adb/ksu" ]; then
    echo "kernelsu"
  elif [ -d "/data/adb/ap" ]; then
    echo "apatch"
  else
    echo "unknown"
  fi
}

# -------------------------------------------
# check_busybox — 验证 busybox 是否可用
# 返回 0=可用, 1=不可用
# -------------------------------------------
function check_busybox() {
  if command -v busybox >/dev/null 2>&1; then
    return 0
  fi
  # 尝试从 Magisk 内置路径查找
  if [ -f "/data/adb/magisk/busybox" ] && /data/adb/magisk/busybox --help >/dev/null 2>&1; then
    export PATH="/data/adb/magisk:$PATH"
    return 0
  fi
  return 1
}

# -------------------------------------------
# check_network — 检查网络连通性
# 返回 0=正常, 1=无网络
# -------------------------------------------
function check_network() {
  # 尝试通过 TCP 连接 Google DNS 来判断网络
  if busybox timeout 3 nc -z 8.8.8.8 53 2>/dev/null; then
    return 0
  fi
  if busybox timeout 3 nc -z 223.5.5.5 53 2>/dev/null; then
    return 0
  fi
  # 最后尝试 ping
  if ping -c 1 -W 2 223.5.5.5 >/dev/null 2>&1; then
    return 0
  fi
  return 1
}
