# AdGuardHome For Root — 功能详解

> 本文档详细说明每个脚本的功能、参数、使用场景和底层原理。

---

## 📂 项目架构

```
/data/adb/agh/
├── bin/
│   ├── AdGuardHome          # Go 编译的 DNS 服务进程
│   ├── AdGuardHome.yaml     # AdGuardHome 运行时配置
│   ├── agh.pid              # 进程 PID 文件
│   └── data/filters/        # 内置广告过滤规则
├── scripts/
│   ├── base.sh              # 基础函数库 (语言/日志/Root检测)
│   ├── tool.sh              # ⭐ 主控 (启动/停止/重启/切换)
│   ├── iptables.sh          # iptables DNS 劫持
│   ├── proxy_manager.sh     # 🆕 代理感知与控制面板
│   ├── inotify.sh           # 文件变更监听
│   └── debug.sh             # 调试信息收集
├── settings.conf            # ⭐ 用户配置文件
├── history.log              # 运行历史日志
├── bin.log                  # AdGuardHome 进程输出
└── debug.log                # 调试信息
```

---

## 🔧 `base.sh` — 基础函数库

### 载入路径

被其他所有脚本以 `. /data/adb/agh/scripts/base.sh` 方式引入。

### 提供的函数

| 函数 | 参数 | 返回值 | 用途 |
|------|------|--------|------|
| `log` | `"英文" "中文"` | 无 | 输出到终端 + 追加到 `history.log` |
| `update_description` | `"英文描述" "中文描述"` | 无 | 更新 Magisk/KSU/APatch 模块描述 |
| `get_root_method` | 无 | 输出 `magisk/kernelsu/apatch/unknown` | 识别当前 Root 类型 |
| `check_busybox` | 无 | 0=可用, 1=不可用 | 检查 busybox 是否可用 |
| `check_network` | 无 | 0=正常, 1=无网络 | 通过 TCP/Ping 检查网络通断 |

### PATH 增强

自动扩展以下路径以查找 busybox：
```
/data/adb/magisk          (Magisk)
/data/adb/ksu/bin         (KernelSU)
/data/adb/ap/bin           (APatch)
/data/adb/modules/busybox-ndk/system/bin
/system/xbin
/system/bin
/data/local/tmp/bin
```

---

## 🎯 `tool.sh` — 主控脚本

**文件路径：** `/data/adb/agh/scripts/tool.sh`

### 使用方式

```bash
/data/adb/agh/scripts/tool.sh start          # 启动
/data/adb/agh/scripts/tool.sh stop           # 停止
/data/adb/agh/scripts/tool.sh restart        # 重启
/data/adb/agh/scripts/tool.sh toggle         # 开关切换
/data/adb/agh/scripts/tool.sh iptables_on    # 单独开劫持
/data/adb/agh/scripts/tool.sh iptables_off   # 单独关劫持
/data/adb/agh/scripts/tool.sh status         # 查看运行状态
```

### 启动流程详解 (`start`)

1. **检查是否已在运行** — `check_already_running()` 先读 PID 文件再搜进程表，双重验证
2. **代理自动检测** — 如果 `auto_proxy_detect=true`，调用 `proxy_manager.sh report` 生成报告
3. **环境变量设置** — `SSL_CERT_DIR` → 解决 Android TLS 证书问题；`TZ` → 时区
4. **二进制检查** — 确认 `/data/adb/agh/bin/AdGuardHome` 存在且可执行
5. **启动进程** — 用 `setuidgid` 以 `root:net_raw` 运行
6. **等待完成** — 最多等 5 秒确认进程存活
7. **iptables 应用** — 如果启用，调用 `iptables.sh enable`

### 停止流程 (`stop`)

1. 先调用 `iptables.sh disable` 清理 iptables 规则
2. 从 PID 文件读取 PID 并 `kill`
3. 兜底 `pkill -9 -f AdGuardHome` 清理残留
4. 删除 PID 文件

### 安全修复 (相比原版)

| 原版 Bug | 修复 |
|---------|------|
| `$adg_pid` 变量在 `grep` 前可能未定义 | 引入 `check_already_running()` 统一检查 |
| `ps \| grep -w $adg_pid` 空变量匹配所有进程 | 变量检查 `[ -n "$pid" ]` 后再 grep |
| `exit 1` 终止调用者 | 改为 `return 1`，不退出 shell |
| 无重启命令 | 新增 `restart` 子命令 |
| 无状态查询 | 新增 `status` 子命令 |

---

## 🌐 `iptables.sh` — DNS 流量劫持

### iptables 链结构

```
nat 表 → OUTPUT → ADGUARD_REDIRECT_DNS
                  ├── RETURN (root:net_raw 自身流量)
                  ├── RETURN (ignore_dest_list 目标白名单)
                  ├── RETURN (ignore_src_list 源白名单)
                  ├── REDIRECT udp:53 → :5591
                  └── REDIRECT tcp:53 → :5591

IPv6:
  block 模式:  filter → OUTPUT → ADGUARD_BLOCK_DNS
                                  ├── DROP udp:53
                                  └── DROP tcp:53

  hijack 模式: nat → OUTPUT → ADGUARD_REDIRECT_DNS6
                              └── (同 v4 链结构)
```

**调试命令：**
```bash
iptables -t nat -L ADGUARD_REDIRECT_DNS -n -v
ip6tables -t filter -L ADGUARD_BLOCK_DNS -n -v
```

---

## 🕵️ `proxy_manager.sh` — 代理感知系统 🆕

**这是本次改造的核心新增功能**，实现自动检测、冲突分析和适配。

### 支持的代理检测

| 代理 | 检测方式 |
|------|---------|
| Clash / Clash Meta | `pgrep -f clash` |
| V2Ray | `pgrep -x v2ray` |
| NekoBox | `pgrep -f nekoray` |
| SurfBoard | `pgrep -f surfboard` |
| Shadowsocks | `pgrep -x ss-local` |
| HTTP 代理 (10809/7890/8118/8888) | netstat 端口检查 |
| Socks5 代理 (1080/10808/7891) | netstat 端口检查 |
| TUN 模式 | `ip link show` 检查 tun 接口 |
| VPN (OpenVPN/WireGuard) | `ip link show` 检查 ppp/wg 接口 |
| Magisk 代理模块 | `/data/adb/modules/` 目录扫描 |

### 冲突等级

| 等级 | 含义 | 自动处理 |
|------|------|---------|
| 🟢 0 | 无冲突 | 保持 `local_only` 模式 |
| 🟡 1 | 可能重复过滤 | 关闭 iptables 劫持，建议代理 DNS 指向 127.0.0.1:5591 |
| 🔴 2 | TUN/VPN 接管所有流量 | 关闭 iptables 劫持 + 提示二选一方案 |

### 使用方式

```bash
# 生成代理感知报告
/data/adb/agh/scripts/proxy_manager.sh report

# 进入交互式控制面板
/data/adb/agh/scripts/proxy_manager.sh panel

# 自动检测并适配代理模式
/data/adb/agh/scripts/proxy_manager.sh auto

# 查看当前状态摘要
/data/adb/agh/scripts/proxy_manager.sh status

# 手动切换 DNS 监听模式
/data/adb/agh/scripts/proxy_manager.sh mode lan_only
```

---

## 📡 DNS 监听模式

通过 `settings.conf` 中的 `listen_mode` 或 `proxy_manager.sh mode` 控制。

| 模式 | DNS 监听 | Web 面板 | 局域网可用 | 使用场景 |
|------|---------|----------|----------|---------|
| `local_only` | 127.0.0.1 | 127.0.0.1:3000 | ❌ | 仅本机使用 |
| `lan_only` | 0.0.0.0 | 127.0.0.1:3000 | ✅ (DNS) | 分享 DNS 给局域网，但不暴露管理面板 |
| `lan_both` | 0.0.0.0 | 0.0.0.0:3000 | ✅ (全部) | 完全向局域网开放 |

### 如何让其他设备使用

1. 切换到 `lan_only` 或 `lan_both` 模式
2. 在 Android 设备上查看局域网 IP：`ip addr show wlan0`
3. 在其他设备上将 DNS 设为 Android 设备的 IP

---

## 🚀 `service.sh` — 开机自启

- 等待系统启动动画结束（最多 5 分钟）
- 额外 sleep 5 秒等网络就绪
- 后台启动 AdGuardHome (`&` 不阻塞)
- 部署 `inotifyd` 监听模块启停

---

## 📊 `debug.sh` — 调试信息

收集并写入 `/data/adb/agh/debug.log`：
- 系统信息（Android 版本、设备型号、架构）
- AdGuardHome 版本
- Root 方法
- 目录结构
- 进程日志（最近 30 行）
- 当前配置
- iptables 状态
- 网络接口信息

---

## ⚙️ `settings.conf` — 配置参考

| 配置项 | 默认值 | 说明 |
|--------|--------|------|
| `listen_mode` | `local_only` | DNS 监听模式 |
| `auto_proxy_detect` | `true` | 启动时自动检测代理 |
| `enable_iptables` | `true` | 启用 iptables DNS 劫持 |
| `block_ipv6_dns` | `true` | 阻断 IPv6 DNS |
| `redir_port` | `5591` | DNS 重定向端口 |
| `adg_user` | `root` | 运行用户 |
| `adg_group` | `net_raw` | 运行用户组 |
| `ignore_dest_list` | `""` | DNS 劫持绕过目标白名单 |
| `ignore_src_list` | `""` | DNS 劫持绕过源白名单 |
| `timezone` | `Asia/Shanghai` | 时区 |

---

## 🔗 快速命令参考

```bash
# 查看状态
/data/adb/agh/scripts/tool.sh status

# 查看代理报告
/data/adb/agh/scripts/proxy_manager.sh report

# 进入控制面板
/data/adb/agh/scripts/proxy_manager.sh panel

# 自动适配代理
/data/adb/agh/scripts/proxy_manager.sh auto

# 切换局域网模式
/data/adb/agh/scripts/proxy_manager.sh mode lan_only

# 重启服务
/data/adb/agh/scripts/tool.sh restart

# 查看调试日志
cat /data/adb/agh/debug.log

# 查看历史日志
tail -50 /data/adb/agh/history.log
```