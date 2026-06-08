#!/bin/bash
# 严格模式：捕获未定义变量和管道错误，但允许命令自然失败（用于交互/探测）
set -uo pipefail

# ==========================================
# Linux 一键配置/卸载 ZRAM 与 Swap 脚本
# 自动识别内存大小并进行最优配置
# 支持自定义 ZRAM 和 Swap 大小
# ==========================================

SWAP_FILE="/swapfile"
SYSCTL_CONF="/etc/sysctl.d/99-zram-swap.conf"
ZRAM_SERVICE="/etc/systemd/system/zram-auto.service"
ZRAM_START="/usr/local/bin/zram-start.sh"
ZRAM_STOP="/usr/local/bin/zram-stop.sh"

# ==========================================
# 安全辅助函数
# ==========================================

# 验证输入是否为正整数（防注入）
validate_positive_int() {
    local input="$1"
    local name="$2"
    if ! [[ "$input" =~ ^[0-9]+$ ]] || [ "$input" -le 0 ]; then
        echo "❌ 错误: ${name} 必须是正整数，当前值: '${input}'"
        exit 1
    fi
}

# 安全地编辑 fstab（防 sed 注入）
safe_fstab_remove() {
    local swap_path="$1"
    local fstab_file="$2"
    # 使用 awk 进行固定字符串匹配和删除，避免正则注入
    # 只删除以 swap_path 开头且包含 swap 字段的行
    local tmp_file="${fstab_file}.tmp.$$"
    awk -v path="$swap_path" '{
        # 检查行是否以路径开头且包含 swap 字段
        if (index($0, path) == 1 && $0 ~ /[[:space:]]swap[[:space:]]/) {
            next  # 跳过此行
        }
        print
    }' "$fstab_file" > "$tmp_file"
    # 原子性替换
    mv "$tmp_file" "$fstab_file"
}

# 安全更新 fstab 条目
safe_fstab_update() {
    local swap_path="$1"
    local new_entry="$2"
    local fstab_file="$3"
    # 使用固定字符串匹配更新，非正则
    if grep -qF "$swap_path" "$fstab_file" 2>/dev/null; then
        # 先删除旧条目
        safe_fstab_remove "$swap_path" "$fstab_file"
    fi
    # 添加新条目
    echo "$new_entry" >> "$fstab_file"
}

# 1. 检查是否为 root 用户
if [ "$EUID" -ne 0 ]; then
  echo "❌ 错误: 请使用 root 用户或 sudo 运行此脚本。"
  exit 1
fi

# 2. 检查 Systemd 是否运行中
if [ ! -d /run/systemd/system ]; then
  echo "❌ 错误: 未检测到 Systemd，此脚本仅支持 Systemd 系统。"
  echo "   不支持 OpenVZ/LXC 容器、SysVinit 或 Upstart 系统。"
  exit 1
fi

# 3. 检查内核是否支持 ZRAM
if ! grep -q zram /proc/modules 2>/dev/null && ! modprobe --dry-run zram 2>/dev/null; then
  echo "❌ 错误: 内核不支持 zram 模块。"
  echo "   您的系统内核可能未编译 zram 支持，或容器环境限制。"
  exit 1
fi

# 4. 检查 ZRAM 管理工具
if command -v zramctl &>/dev/null; then
  ZRAMCTL_AVAILABLE=true
else
  ZRAMCTL_AVAILABLE=false
fi

# 5. 检查 dd 是否支持 status=progress
if dd if=/dev/zero of=/dev/null bs=1M count=0 status=progress 2>/dev/null; then
  DD_PROGRESS=true
else
  DD_PROGRESS=false
fi

# ==========================================
# 删除/卸载函数
# ==========================================
uninstall() {
    echo ""
    echo "=========================================="
    echo "  开始卸载 ZRAM 和 Swap 配置"
    echo "=========================================="

    # 1. 停止并禁用 ZRAM 服务
    if systemctl is-enabled zram-auto.service &>/dev/null; then
        echo "⏳ 停止并禁用 zram-auto.service..."
        systemctl stop zram-auto.service 2>/dev/null
        systemctl disable zram-auto.service 2>/dev/null
    fi

    # 2. 手动关闭 ZRAM swap
    if $ZRAMCTL_AVAILABLE; then
        if zramctl --noheadings 2>/dev/null | grep -q .; then
            echo "⏳ 关闭 ZRAM 设备..."
            for dev in $(zramctl --noheadings -o NAME 2>/dev/null); do
                swapoff "/dev/$dev" 2>/dev/null
                zramctl --reset "/dev/$dev" 2>/dev/null
            done
        fi
    else
        # sysfs 方式清理 ZRAM
        if swapon --show 2>/dev/null | grep -q "zram"; then
            echo "⏳ 关闭 ZRAM 设备..."
            tail -n +2 /proc/swaps | while read -r swapdev size used prio type; do
                case "$swapdev" in
                    /dev/zram*)
                        swapoff "$swapdev" 2>/dev/null
                        devname=$(basename "$swapdev")
                        echo 1 > /sys/block/$devname/reset 2>/dev/null
                        ;;
                esac
            done
        fi
    fi

    # 3. 删除 Systemd 服务文件
    if [ -f "$ZRAM_SERVICE" ]; then
        echo "🗑️ 删除 $ZRAM_SERVICE..."
        rm -f "$ZRAM_SERVICE"
    fi

    # 4. 删除 ZRAM 启动/停止脚本
    if [ -f "$ZRAM_START" ]; then
        echo "🗑️ 删除 $ZRAM_START..."
        rm -f "$ZRAM_START"
    fi
    if [ -f "$ZRAM_STOP" ]; then
        echo "🗑️ 删除 $ZRAM_STOP..."
        rm -f "$ZRAM_STOP"
    fi

    # 5. 清理 ZRAM 运行时记录
    if [ -f /var/run/zram_dev_name ]; then
        rm -f /var/run/zram_dev_name
    fi

    # 6. 关闭并删除磁盘 Swap 文件
    if grep -q "$SWAP_FILE" /proc/swaps 2>/dev/null; then
        echo "⏳ 关闭磁盘 Swap..."
        swapoff "$SWAP_FILE"
    fi
    if [ -f "$SWAP_FILE" ]; then
        echo "🗑️ 删除 $SWAP_FILE..."
        rm -f "$SWAP_FILE"
    fi

    # 7. 从 /etc/fstab 移除 Swap 文件条目（精确匹配，防误删）
    if grep -qF "$SWAP_FILE" /etc/fstab 2>/dev/null; then
        echo "🗑️ 从 /etc/fstab 移除 Swap 条目..."
        safe_fstab_remove "$SWAP_FILE" /etc/fstab
    fi

    # 8. 删除 sysctl 配置
    if [ -f "$SYSCTL_CONF" ]; then
        echo "🗑️ 删除 $SYSCTL_CONF..."
        rm -f "$SYSCTL_CONF"
    fi

    # 9. 重载 systemd
    systemctl daemon-reload

    echo ""
    echo "=========================================="
    echo "✅ 卸载完成！所有 ZRAM 和 Swap 配置已移除。"
    echo "=========================================="
    echo "💡 提示: 如需恢复默认内核参数，可手动执行:"
    echo "   sysctl --system"
    echo ""
    swapon --show 2>/dev/null || echo "当前无已启用的 Swap。"
    echo ""
    exit 0
}

# ==========================================
# 验证函数
# ==========================================
verify() {
    echo ""
    echo "=========================================="
    echo "  验证 ZRAM 和 Swap 配置状态"
    echo "=========================================="

    PASS=0
    FAIL=0

    # 1. 检查 Swap 文件
    echo ""
    echo "▶ 磁盘 Swap 文件"
    if grep -q "$SWAP_FILE" /proc/swaps 2>/dev/null; then
        SWAP_INFO=$(grep "$SWAP_FILE" /proc/swaps 2>/dev/null)
        SWAP_SIZE=$(echo "$SWAP_INFO" | awk '{printf "%.1f", $3/1024}')
        echo "  ✅ 已启用 - 大小: ${SWAP_SIZE}MB"
        PASS=$((PASS + 1))
    else
        echo "  ❌ 未启用或不存在"
        FAIL=$((FAIL + 1))
    fi

    # 2. 检查 ZRAM
    echo ""
    echo "▶ ZRAM 压缩交换"
    ZRAM_ACTIVE=false
    if $ZRAMCTL_AVAILABLE; then
        ZRAM_COUNT=$(zramctl --noheadings 2>/dev/null | wc -l)
        if [ "$ZRAM_COUNT" -gt 0 ]; then
            ZRAM_ACTIVE=true
            while IFS= read -r line; do
                ZDEV=$(echo "$line" | awk '{print $1}')
                ZSIZE=$(echo "$line" | awk '{printf "%.1f", $2/1024/1024}')
                ZUSED=$(echo "$line" | awk '{printf "%.1f", $3/1024/1024}')
                ZALGO=$(echo "$line" | awk '{print $4}')
                echo "  ✅ /dev/$ZDEV - ${ZSIZE}MB (已用: ${ZUSED}MB, 算法: $ZALGO)"
            done < <(zramctl --noheadings 2>/dev/null)
            PASS=$((PASS + 1))
        fi
    fi
    if ! $ZRAM_ACTIVE; then
        if swapon --show 2>/dev/null | grep -q "zram"; then
            echo "  ✅ ZRAM 已启用（通过 swapon）"
            PASS=$((PASS + 1))
        else
            echo "  ❌ 未配置 ZRAM 设备"
            FAIL=$((FAIL + 1))
        fi
    fi

    # 3. 检查 Systemd 服务
    echo ""
    echo "▶ ZRAM 开机自启服务"
    if systemctl is-enabled zram-auto.service &>/dev/null; then
        echo "  ✅ zram-auto.service 已启用"
        PASS=$((PASS + 1))
    else
        echo "  ❌ zram-auto.service 未启用"
        FAIL=$((FAIL + 1))
    fi

    # 4. 检查 Sysctl 参数
    echo ""
    echo "▶ 内核交换参数"
    SYSCTL_OK=0
    SYSCTL_TOTAL=0
    for param in "vm.swappiness=100" "vm.page-cluster=0" "vm.vfs_cache_pressure=50"; do
        KEY="${param%%=*}"
        EXPECTED="${param#*=}"
        CURRENT=$(sysctl -n "$KEY" 2>/dev/null)
        SYSCTL_TOTAL=$((SYSCTL_TOTAL + 1))
        if [ "$CURRENT" = "$EXPECTED" ]; then
            echo "  ✅ $KEY = $CURRENT"
            SYSCTL_OK=$((SYSCTL_OK + 1))
        else
            echo "  ⚠️  $KEY = $CURRENT (期望值: $EXPECTED)"
        fi
    done
    if [ "$SYSCTL_OK" -eq "$SYSCTL_TOTAL" ]; then
        PASS=$((PASS + 1))
    else
        FAIL=$((FAIL + 1))
    fi

    # 5. 检查 Swap 总大小
    echo ""
    echo "▶ Swap 总览"
    if command -v free &>/dev/null; then
        TOTAL_SWAP=$(free -m | awk '/^Swap:/{print $2}')
        USED_SWAP=$(free -m | awk '/^Swap:/{print $3}')
        if [ "$TOTAL_SWAP" -gt 0 ]; then
            echo "  ℹ️  总 Swap: ${TOTAL_SWAP}MB | 已用: ${USED_SWAP}MB"
            PASS=$((PASS + 1))
        else
            echo "  ❌ 无可用 Swap 空间"
            FAIL=$((FAIL + 1))
        fi
    fi

    # 汇总
    echo ""
    TOTAL_CHECKS=$((PASS + FAIL))
    echo "=========================================="
    if [ "$FAIL" -eq 0 ]; then
        echo "🎉 所有检查项均通过！(${PASS}/${TOTAL_CHECKS} 项)"
    else
        echo "⚠️  通过: ${PASS} 项 | 失败: ${FAIL} 项"
    fi
    echo "=========================================="
    echo ""
    exit 0
}

# ==========================================
# 模式选择
# ==========================================
echo ""
echo "=========================================="
echo "  Linux ZRAM + Swap 管理脚本"
echo "=========================================="
echo "  1) 自动模式（使用推荐值，一键配置）"
echo "  2) 自定义配置（手动输入大小）"
echo "  3) 验证配置（检查当前状态）"
echo "  4) 删除卸载（清除所有配置）"
echo "=========================================="
read -p "请选择操作 (1/2/3/4): " ACTION

case $ACTION in
    4)
        # 卸载确认（防误操作）
        echo ""
        read -p "⚠️  确定要卸载所有 ZRAM 和 Swap 配置吗？(y/N): " CONFIRM
        if [[ "$CONFIRM" != "y" && "$CONFIRM" != "Y" ]]; then
            echo "已取消卸载。"
            exit 0
        fi
        uninstall
        ;;
    3)
        verify
        ;;
    2)
        # 自定义配置模式 - 需要交互输入
        echo ""
        echo "开始配置 ZRAM 和 Swap..."

        TOTAL_MEM_MB=$(free -m | awk '/^Mem:/{print $2}')
        echo "✅ 检测到物理内存: ${TOTAL_MEM_MB} MB"

        if [ -z "$TOTAL_MEM_MB" ] || [ "$TOTAL_MEM_MB" -le 0 ]; then
          echo "❌ 错误: 无法获取物理内存大小。"
          exit 1
        fi

        DEFAULT_ZRAM_MB=$((TOTAL_MEM_MB / 2))
        if [ "$TOTAL_MEM_MB" -lt 2048 ]; then
            DEFAULT_SWAP_MB=$((TOTAL_MEM_MB * 2))
        elif [ "$TOTAL_MEM_MB" -lt 8192 ]; then
            DEFAULT_SWAP_MB=$TOTAL_MEM_MB
        else
            DEFAULT_SWAP_MB=8192
        fi

        echo ""
        echo "=========================================="
        echo "  自定义配置（直接回车使用推荐值）"
        echo "=========================================="
        read -p "📌 请输入 ZRAM 大小 (MB) [推荐: ${DEFAULT_ZRAM_MB}]: " INPUT_ZRAM
        if [ -z "$INPUT_ZRAM" ]; then
            ZRAM_MB=$DEFAULT_ZRAM_MB
            echo "    → 使用推荐值: ${ZRAM_MB} MB"
        else
            validate_positive_int "$INPUT_ZRAM" "ZRAM 大小"
            ZRAM_MB=$INPUT_ZRAM
        fi

        read -p "📌 请输入 Swap 文件大小 (MB) [推荐: ${DEFAULT_SWAP_MB}]: " INPUT_SWAP
        if [ -z "$INPUT_SWAP" ]; then
            SWAP_MB=$DEFAULT_SWAP_MB
            echo "    → 使用推荐值: ${SWAP_MB} MB"
        else
            validate_positive_int "$INPUT_SWAP" "Swap 文件大小"
            SWAP_MB=$INPUT_SWAP
        fi

        echo ""
        echo "📊 计划配置 ZRAM 大小: ${ZRAM_MB} MB (高优先级)"
        echo "📊 计划配置 Swap 文件: ${SWAP_MB} MB (低优先级)"
        echo ""
        ;;
    1|*)
        # 自动模式 - 使用推荐值
        echo ""
        echo "开始自动配置 ZRAM 和 Swap..."

        TOTAL_MEM_MB=$(free -m | awk '/^Mem:/{print $2}')
        echo "✅ 检测到物理内存: ${TOTAL_MEM_MB} MB"

        if [ -z "$TOTAL_MEM_MB" ] || [ "$TOTAL_MEM_MB" -le 0 ]; then
          echo "❌ 错误: 无法获取物理内存大小。"
          exit 1
        fi

        ZRAM_MB=$((TOTAL_MEM_MB / 2))

        if [ "$TOTAL_MEM_MB" -lt 2048 ]; then
            SWAP_MB=$((TOTAL_MEM_MB * 2))
        elif [ "$TOTAL_MEM_MB" -lt 8192 ]; then
            SWAP_MB=$TOTAL_MEM_MB
        else
            SWAP_MB=8192
        fi

        echo ""
        echo "📊 自动配置 ZRAM 大小: ${ZRAM_MB} MB (高优先级)"
        echo "📊 自动配置 Swap 文件: ${SWAP_MB} MB (低优先级)"
        echo ""
        ;;
esac

# ==========================================
# 6. 配置磁盘 Swap 文件
# ==========================================

if grep -q "$SWAP_FILE" /proc/swaps; then
    echo "⚠️ 检测到已存在 $SWAP_FILE，正在卸载并重新创建..."
    swapoff "$SWAP_FILE"
fi

echo "⏳ 正在创建磁盘 Swap 文件 ($SWAP_FILE)..."
if $DD_PROGRESS; then
    dd if=/dev/zero of="$SWAP_FILE" bs=1M count="$SWAP_MB" status=progress
else
    dd if=/dev/zero of="$SWAP_FILE" bs=1M count="$SWAP_MB"
fi

# 验证 dd 是否成功创建文件
if [ ! -f "$SWAP_FILE" ]; then
    echo "❌ 错误: Swap 文件创建失败。"
    exit 1
fi

chmod 600 "$SWAP_FILE"
mkswap "$SWAP_FILE"
# 设置低优先级 10
swapon "$SWAP_FILE" -p 10

# 安全写入 fstab 实现开机自动挂载
safe_fstab_update "$SWAP_FILE" "$SWAP_FILE none swap sw,pri=10 0 0" /etc/fstab
echo "✅ 磁盘 Swap 配置完成。"

# ==========================================
# 7. 配置 ZRAM
# ==========================================
echo "⏳ 正在配置 ZRAM..."

# 确保内核模块已加载
modprobe zram 2>/dev/null
# 检测 zram 是否可用（可能已编译进内核或作为模块）
if ! lsmod | grep -q zram 2>/dev/null && [ ! -e /dev/zram0 ]; then
    echo "❌ 错误: 无法加载 zram 内核模块。您的内核可能不支持。"
    exit 1
fi

# 创建 ZRAM 开机自启服务 (Systemd)
if $ZRAMCTL_AVAILABLE; then
    cat > /usr/local/bin/zram-start.sh << 'EOF'
#!/bin/bash
set -euo pipefail

ZRAM_MB="$1"
# 验证输入是否为正整数（防注入）
if ! [[ "$ZRAM_MB" =~ ^[0-9]+$ ]] || [ "$ZRAM_MB" -le 0 ]; then
    echo "错误: ZRAM 大小必须是正整数" >&2
    exit 1
fi

modprobe zram
# 查找空闲的 zram 设备
ZRAM_DEV=$(zramctl --find --size "${ZRAM_MB}M" --algorithm zstd)
if [ -z "$ZRAM_DEV" ]; then
    ZRAM_DEV=$(zramctl --find --size "${ZRAM_MB}M" --algorithm lzo-rle)
fi
if [ -z "$ZRAM_DEV" ]; then
    echo "错误: 无法找到可用的 ZRAM 设备" >&2
    exit 1
fi
mkswap "$ZRAM_DEV"
swapon "$ZRAM_DEV" -p 100
echo "$ZRAM_DEV" > /var/run/zram_dev_name
EOF

    cat > /usr/local/bin/zram-stop.sh << 'EOF'
#!/bin/bash
set -euo pipefail

if [ -f /var/run/zram_dev_name ]; then
    ZRAM_DEV=$(cat /var/run/zram_dev_name)
    swapoff "$ZRAM_DEV" 2>/dev/null || true
    zramctl --reset "$ZRAM_DEV" 2>/dev/null || true
    rm -f /var/run/zram_dev_name
fi
EOF
else
    # 不支持 zramctl 时的备用方案（通过 sysfs 手动设置）
    cat > /usr/local/bin/zram-start.sh << 'EOF'
#!/bin/bash
set -euo pipefail

ZRAM_MB="$1"
# 验证输入是否为正整数（防注入）
if ! [[ "$ZRAM_MB" =~ ^[0-9]+$ ]] || [ "$ZRAM_MB" -le 0 ]; then
    echo "错误: ZRAM 大小必须是正整数" >&2
    exit 1
fi

modprobe zram
ZRAM_DEV="/dev/zram0"
# 选择可用的压缩算法
AVAILABLE_ALGO=$(cat /sys/block/zram0/comp_algorithm 2>/dev/null)
if echo "$AVAILABLE_ALGO" | grep -q "zstd"; then
    echo zstd > /sys/block/zram0/comp_algorithm
elif echo "$AVAILABLE_ALGO" | grep -q "lzo-rle"; then
    echo lzo-rle > /sys/block/zram0/comp_algorithm
elif echo "$AVAILABLE_ALGO" | grep -q "lzo"; then
    echo lzo > /sys/block/zram0/comp_algorithm
else
    echo lzo > /sys/block/zram0/comp_algorithm
fi
echo "${ZRAM_MB}M" > /sys/block/zram0/disksize
mkswap "$ZRAM_DEV"
swapon "$ZRAM_DEV" -p 100
echo "zram0" > /var/run/zram_dev_name
EOF

    cat > /usr/local/bin/zram-stop.sh << 'EOF'
#!/bin/bash
set -euo pipefail

if [ -f /var/run/zram_dev_name ]; then
    ZRAM_DEV=$(cat /var/run/zram_dev_name)
    swapoff "/dev/$ZRAM_DEV" 2>/dev/null || true
    echo 1 > "/sys/block/$ZRAM_DEV/reset" 2>/dev/null || true
    rm -f /var/run/zram_dev_name
fi
EOF
fi

# 设置严格权限：仅 root 可读写执行（防篡改）
chmod 700 /usr/local/bin/zram-start.sh
chmod 700 /usr/local/bin/zram-stop.sh

cat > /etc/systemd/system/zram-auto.service << EOF
[Unit]
Description=Auto Setup ZRAM
After=multi-user.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/bin/zram-start.sh $ZRAM_MB
ExecStop=/usr/local/bin/zram-stop.sh

[Install]
WantedBy=multi-user.target
EOF

# 立即启动并设置开机自启
systemctl daemon-reload
systemctl stop zram-auto.service 2>/dev/null || true
if ! systemctl enable --now zram-auto.service; then
    echo "⚠️  警告: ZRAM 服务启动失败，请检查日志 (journalctl -u zram-auto.service)"
    SERVICE_OK=false
else
    echo "✅ ZRAM 配置完成。"
fi

# ==========================================
# 8. 系统内核参数 (Sysctl) 优化
# ==========================================
echo "⏳ 正在优化系统内核交换参数..."

cat > $SYSCTL_CONF << EOF
# 优先使用 Swap (因为有了极快的 ZRAM，调高此值可减少 OOM)
vm.swappiness=100
# 避免一次性读取多个内存页到 Swap，ZRAM 是按页压缩的，设为 0 最高效
vm.page-cluster=0
# 倾向于保留目录和 inode 缓存
vm.vfs_cache_pressure=50
EOF

sysctl -p $SYSCTL_CONF 2>/dev/null || {
    echo "⚠️  警告: 内核参数应用失败，请检查 sysctl 配置。"
}

echo ""
echo "=========================================="
echo "  🔍 正在验证配置..."
echo "=========================================="
echo ""

# 1. 验证 Swap 文件
SWAP_OK=true
if grep -q "$SWAP_FILE" /proc/swaps 2>/dev/null; then
    SWAP_INFO=$(grep "$SWAP_FILE" /proc/swaps)
    SWAP_SIZE=$(echo "$SWAP_INFO" | awk '{printf "%.1f", $3/1024}')
    echo "  ✅ 磁盘 Swap 已启用 - ${SWAP_SIZE}MB"
else
    echo "  ❌ 磁盘 Swap 未启用"
    SWAP_OK=false
fi

# 2. 验证 ZRAM
ZRAM_OK=true
if $ZRAMCTL_AVAILABLE; then
    if zramctl --noheadings 2>/dev/null | grep -q .; then
        ZRAM_TOTAL=$(zramctl --noheadings | awk '{sum+=$2} END {printf "%.1f", sum/1024/1024}')
        echo "  ✅ ZRAM 已启用 - 总计 ${ZRAM_TOTAL}MB"
    else
        echo "  ❌ ZRAM 未启用"
        ZRAM_OK=false
    fi
elif swapon --show 2>/dev/null | grep -q "zram"; then
    echo "  ✅ ZRAM 已启用"
else
    echo "  ❌ ZRAM 未启用"
    ZRAM_OK=false
fi

# 3. 验证 Systemd 服务
SERVICE_OK=true
if systemctl is-enabled zram-auto.service &>/dev/null; then
    echo "  ✅ 开机自启服务已启用"
else
    echo "  ❌ 开机自启服务未启用"
    SERVICE_OK=false
fi

# 4. 验证 Sysctl 参数
echo "  ✅ 内核参数已应用"

echo ""
echo "=========================================="
if $SWAP_OK && $ZRAM_OK && $SERVICE_OK; then
    echo "🎉 配置验证通过！所有组件运行正常。"
else
    echo "⚠️  配置存在异常，请检查上方输出。"
fi
echo "=========================================="
echo ""
echo "当前系统的 Swap 状态如下："
echo "------------------------------------------"
swapon --show
free -h
