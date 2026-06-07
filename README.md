# Linux 一键配置 ZRAM 与 Swap 脚本

自动识别内存大小并进行最优配置，支持 ZRAM 压缩交换和磁盘 Swap 文件管理。

## 功能特性

- **自动模式** - 一键使用系统推荐的配置值
- **自定义配置** - 手动输入 ZRAM 和 Swap 大小
- **删除卸载** - 完全清除所有配置
- **验证配置** - 检查当前 ZRAM 和 Swap 运行状态

## 配置策略

| 物理内存 | ZRAM (50%) | Swap 文件 |
|---------|-------------|-----------|
| < 2GB   | 内存的 50%  | 内存 × 2  |
| 2GB~8GB | 内存的 50%  | 等于内存  |
| > 8GB   | 内存的 50%  | 固定 8GB  |

## 使用方法

### 一键安装并运行

```bash
curl -sSL https://raw.githubusercontent.com/qqgtr/swap/main/setup_swap_zram.sh -o setup_swap_zram.sh && sudo bash setup_swap_zram.sh
```

或分步执行：

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

## 配置内容

- **ZRAM** - 压缩内存交换，优先级 100（高）
- **磁盘 Swap** - `/swapfile`，优先级 10（低）
- **Systemd 服务** - 开机自启 `zram-auto.service`
- **内核参数** - `vm.swappiness=100`, `vm.page-cluster=0`, `vm.vfs_cache_pressure=50`

## 系统要求

- Linux 系统（支持 Systemd）
- 内核支持 ZRAM 模块
- root 权限
