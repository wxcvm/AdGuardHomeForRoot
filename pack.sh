#!/system/bin/sh
##############################################################################
# pack.sh — AdGuardHomeForRoot 模块打包脚本 (跨平台)
# 用法:
#   pack.sh scripts           仅打包脚本+配置 (不含 AdGuardHome 二进制)
#   pack.sh arm64             下载 arm64 二进制 + 完整打包
#   pack.sh armv7             下载 armv7 二进制 + 完整打包
#   pack.sh all               下载全部架构 + 全打包
#
# 输出目录: ./release/
##############################################################################

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SRC_DIR="$SCRIPT_DIR/src"
CACHE_DIR="$SCRIPT_DIR/cache"
RELEASE_DIR="$SCRIPT_DIR/release"

# AdGuardHome 下载地址
AGH_BASE_URL="https://github.com/AdguardTeam/AdGuardHome/releases/latest/download"
AGH_ARM64_URL="$AGH_BASE_URL/AdGuardHome_linux_arm64.tar.gz"
AGH_ARMV7_URL="$AGH_BASE_URL/AdGuardHome_linux_armv7.tar.gz"

echo "============================================"
echo " AdGuardHome For Root — 模块打包工具"
echo "============================================"
echo ""

# 创建输出目录
mkdir -p "$RELEASE_DIR" "$CACHE_DIR"

# -------------------------------------------
# 下载 AdGuardHome 二进制
# -------------------------------------------
download_agh() {
  local arch="$1"
  local url=""
  local out_file=""

  case "$arch" in
    arm64)
      url="$AGH_ARM64_URL"
      out_file="$CACHE_DIR/AdGuardHome_linux_arm64.tar.gz"
      ;;
    armv7)
      url="$AGH_ARMV7_URL"
      out_file="$CACHE_DIR/AdGuardHome_linux_armv7.tar.gz"
      ;;
    *)
      echo "Unknown arch: $arch"
      return 1
      ;;
  esac

  if [ -f "$out_file" ]; then
    echo "[skip] $arch binary already cached"
    return 0
  fi

  echo "[download] Fetching AdGuardHome $arch..."
  if command -v wget >/dev/null 2>&1; then
    wget -q --show-progress -O "$out_file" "$url" || {
      echo "Download failed, retrying without TLS verification..."
      wget --no-check-certificate -O "$out_file" "$url"
    }
  elif command -v curl >/dev/null 2>&1; then
    curl -L -o "$out_file" "$url" || {
      echo "Download failed, retrying with -k..."
      curl -kL -o "$out_file" "$url"
    }
  else
    echo "Error: wget or curl required"
    return 1
  fi

  echo "[extract] $arch..."
  local extract_dir="$CACHE_DIR/$arch"
  mkdir -p "$extract_dir"
  tar -xzf "$out_file" -C "$extract_dir"
  echo "[done] $arch binary ready"
}

# -------------------------------------------
# 打包一个架构的 ZIP
# -------------------------------------------
pack_zip() {
  local arch="$1"
  local include_binary="${2:-false}"
  local zip_name="AdGuardHomeForRoot_${arch}.zip"
  local zip_path="$RELEASE_DIR/$zip_name"
  local tmp_dir="$CACHE_DIR/pack_tmp"

  echo ""
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo " Packaging: $zip_name"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

  # 清理临时目录
  rm -rf "$tmp_dir"
  mkdir -p "$tmp_dir"

  # 复制所有脚本和配置
  echo "[copy] Scripts and configs..."
  cp "$SRC_DIR"/*.sh "$tmp_dir/" 2>/dev/null || true
  cp "$SRC_DIR/settings.conf" "$tmp_dir/"
  cp "$SRC_DIR/module.prop" "$tmp_dir/"

  # 复制 META-INF
  cp -r "$SRC_DIR/META-INF" "$tmp_dir/"

  # 复制 scripts 目录
  cp -r "$SRC_DIR/scripts" "$tmp_dir/"

  # 复制 webroot
  cp -r "$SRC_DIR/webroot" "$tmp_dir/"

  # 复制 bin 目录（配置和过滤规则）
  mkdir -p "$tmp_dir/bin"
  if [ -f "$SRC_DIR/bin/AdGuardHome.yaml" ]; then
    cp "$SRC_DIR/bin/AdGuardHome.yaml" "$tmp_dir/bin/"
  fi
  if [ -d "$SRC_DIR/bin/data" ]; then
    cp -r "$SRC_DIR/bin/data" "$tmp_dir/bin/"
  fi

  # 复制二进制（如果有）
  if [ "$include_binary" = "true" ]; then
    local bin_src="$CACHE_DIR/$arch/AdGuardHome/AdGuardHome"
    if [ -f "$bin_src" ]; then
      echo "[copy] AdGuardHome binary ($arch)..."
      cp "$bin_src" "$tmp_dir/bin/AdGuardHome"
    else
      echo "[warn] Binary not found at $bin_src"
    fi
  fi

  # 移除旧 zip
  rm -f "$zip_path"

  # 打包
  echo "[zip] Creating $zip_name..."
  cd "$tmp_dir"
  if command -v zip >/dev/null 2>&1; then
    zip -r "$zip_path" . -x "*.DS_Store" -x "__MACOSX/*"
  elif command -v 7z >/dev/null 2>&1; then
    7z a -tzip "$zip_path" .
  else
    echo "Error: zip or 7z required"
    return 1
  fi
  cd "$SCRIPT_DIR"

  # 显示结果
  local size=$(ls -lh "$zip_path" | awk '{print $5}')
  echo ""
  echo "✅ Packaged: $zip_name ($size)"
  echo "   Path: $zip_path"
  echo ""

  # 列出内容
  echo "Contents:"
  unzip -l "$zip_path" 2>/dev/null | tail -n +4 | head -n -2 || true
  echo ""

  # 清理
  rm -rf "$tmp_dir"
}

# -------------------------------------------
# 入口
# -------------------------------------------
case "$1" in
  scripts)
    echo "📦 Packing scripts-only (no binary)..."
    pack_zip "scripts" "false"
    ;;
  arm64)
    echo "📦 Packing with arm64 binary..."
    download_agh "arm64"
    pack_zip "arm64" "true"
    ;;
  armv7)
    echo "📦 Packing with armv7 binary..."
    download_agh "armv7"
    pack_zip "armv7" "true"
    ;;
  all)
    echo "📦 Packing all architectures..."
    download_agh "arm64"
    download_agh "armv7"
    pack_zip "arm64" "true"
    pack_zip "armv7" "true"
    pack_zip "scripts" "false"
    ;;
  *)
    echo "AdGuardHome For Root — 打包工具"
    echo ""
    echo "用法: $0 {scripts|arm64|armv7|all}"
    echo ""
    echo "  scripts  — 仅脚本+配置 (不含二进制, ~100KB)"
    echo "  arm64    — arm64 完整包 (含 ~60MB 二进制)"
    echo "  armv7    — armv7 完整包"
    echo "  all      — 全部架构"
    echo ""
    echo "输出目录: $RELEASE_DIR/"
    ;;
esac

echo ""
echo "============================================"
echo " Done!"
echo "============================================"