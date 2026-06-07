# Linux 一键配置 ZRAM 与 Swap 脚本

自动识别内存大小并进行最优配置，支持 ZRAM 压缩交换和磁盘 Swap 文件管理。

## 功能特性

- **自动模式** - 一键使用系统推荐的配置值
- **自定义配置** - 手动输入 ZRAM 和 Swap 大小
- **删除卸载** - 完全清除所有配置
- **验证配置** - 检查当前 ZRAM 和 Swap 运行状态

## 使用方法

### 国内使用

**自动安装（一键）：**
```bash
curl -sSL https://gh-proxy.org/https://raw.githubusercontent.com/qqgtr/swap/main/setup_swap_zram.sh -o setup_swap_zram.sh && sudo bash setup_swap_zram.sh
```

**手动安装（分步）：**
```bash
# 1. 下载脚本
curl -sSL https://gh-proxy.org/https://raw.githubusercontent.com/qqgtr/swap/main/setup_swap_zram.sh -o setup_swap_zram.sh

# 2. 赋予执行权限
chmod +x setup_swap_zram.sh

# 3. 运行脚本（需 root 权限）
sudo ./setup_swap_zram.sh
```

### 海外使用

**自动安装（一键）：**
```bash
curl -sSL https://raw.githubusercontent.com/qqgtr/swap/main/setup_swap_zram.sh -o setup_swap_zram.sh && sudo bash setup_swap_zram.sh
```

**手动安装（分步）：**
```bash
# 1. 下载脚本
curl -sSL https://raw.githubusercontent.com/qqgtr/swap/main/setup_swap_zram.sh -o setup_swap_zram.sh

# 2. 赋予执行权限
chmod +x setup_swap_zram.sh

# 3. 运行脚本（需 root 权限）
sudo ./setup_swap_zram.sh
```

### 菜单选项

```
1) 自动模式（使用推荐值，一键配置）
2) 自定义配置（手动输入大小）
3) 验证配置（检查当前状态）
4) 删除卸载（清除所有配置）
```

## 支持系统

### 支持的主流发行版

| 发行版 | 版本要求 | 状态 |
|---------|----------|------|
| Ubuntu | 18.04+ | ✅ |
| Debian | 10+ | ✅ |
| CentOS | 7+ | ✅ |
| Rocky Linux | 8+ | ✅ |
| AlmaLinux | 8+ | ✅ |
| Fedora | 30+ | ✅ |
| openSUSE | 15+ | ✅ |
| Arch Linux | 最新 | ✅ |
| RHEL | 7+ | ✅ |
| Oracle Linux | 7+ | ✅ |
| Alibaba Cloud Linux (Alinux) | 2+ | ✅ |
| Tencent Cloud Linux (TencentOS) | 3+ | ✅ |
| Amazon Linux | 2+ | ✅ |

### 不支持的环境

- Windows / macOS（非 Linux 系统）
- OpenVZ / LXC 容器（不支持加载内核模块）
- WSL 1（Windows Subsystem for Linux 第一代）
- 精简版系统（缺少 `systemd`、`zram` 模块）

## 系统要求

| 要求项 | 说明 |
|--------|------|
| 操作系统 | Linux（支持 Systemd） |
| 内核模块 | 支持 ZRAM 模块（主流发行版默认内置） |
| 权限 | root 或 sudo 权限 |
| 依赖工具 | bash、systemctl、zramctl（默认自带） |

## 配置策略

| 物理内存 | ZRAM (50%) | Swap 文件 |
|---------|-------------|-----------|
| < 2GB   | 内存的 50%  | 内存 × 2  |
| 2GB~8GB | 内存的 50%  | 等于内存  |
| > 8GB   | 内存的 50%  | 固定 8GB  |

## 配置内容

- **ZRAM** - 压缩内存交换，优先级 100（高）
- **磁盘 Swap** - `/swapfile`，优先级 10（低）
- **Systemd 服务** - 开机自启 `zram-auto.service`
- **内核参数** - `vm.swappiness=100`, `vm.page-cluster=0`, `vm.vfs_cache_pressure=50`
