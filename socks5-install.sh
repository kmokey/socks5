#!/bin/bash
# ==============================================
# SOCKS5 服务器一键部署脚本 (IPv4/IPv6双栈)
# 版本: 3.0
# 特点: 自动修复+智能诊断+多系统支持
# ==============================================

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# 全局配置
CONFIG_FILE="/etc/socks5/config.json"
SERVICE_FILE="/etc/systemd/system/socks5.service"
LOG_FILE="/var/log/socks5.log"
BIN_PATH="/usr/local/bin/microsocks"

# 初始化安装
init_install() {
    # 检测root权限
    [ "$(id -u)" != "0" ] && echo -e "${RED}错误: 必须使用root权限运行!${NC}" && exit 1

    # 安装依赖
    echo -e "${CYAN}>>> 正在安装系统依赖...${NC}"
    if grep -qi "alpine" /etc/os-release; then
        apk update && apk add wget unzip jq curl make gcc
    elif grep -qi "ubuntu\|debian" /etc/os-release; then
        apt update && apt install -y wget unzip jq curl make gcc
    else
        echo -e "${YELLOW}警告: 未知系统，尝试通用安装...${NC}"
        if ! command -v make >/dev/null; then
            echo -e "${RED}错误: 必须手动安装make工具${NC}"
            exit 1
        fi
    fi

    # 安装microsocks
    install_microsocks
}

# 安装核心组件
install_microsocks() {
    echo -e "${CYAN}>>> 正在部署microsocks...${NC}"
    rm -f "$BIN_PATH"

    # 自动选择最佳安装方式
    if [ -f "/etc/alpine-release" ]; then
        # Alpine优先使用预编译
        case "$(uname -m)" in
            x86_64) BIN_URL="https://github.com/rofl0r/microsocks/releases/download/v1.0.3/microsocks-x86_64-linux-gnu" ;;
            aarch64) BIN_URL="https://github.com/rofl0r/microsocks/releases/download/v1.0.3/microsocks-aarch64-linux-gnu" ;;
            *) compile_from_source ;;
        esac
        wget "$BIN_URL" -O "$BIN_PATH" || compile_from_source
    else
        # 其他系统尝试编译
        compile_from_source
    fi

    chmod +x "$BIN_PATH"
    if [ ! -x "$BIN_PATH" ]; then
        echo -e "${RED}错误: microsocks安装失败!${NC}"
        exit 1
    fi
    echo -e "${GREEN}microsocks安装成功${NC}"
}

# 源码编译
compile_from_source() {
    echo -e "${YELLOW}尝试从源码编译...${NC}"
    tmp_dir=$(mktemp -d)
    wget https://github.com/rofl0r/microsocks/archive/refs/heads/master.zip -O "$tmp_dir/microsocks.zip" || {
        echo -e "${RED}下载源码失败!${NC}"; exit 1
    }
    unzip "$tmp_dir/microsocks.zip" -d "$tmp_dir" && cd "$tmp_dir/microsocks-master" || {
        echo -e "${RED}解压失败!${NC}"; exit 1
    }
    make && cp microsocks "$BIN_PATH" || {
        echo -e "${RED}编译失败!${NC}"; exit 1
    }
    rm -rf "$tmp_dir"
}

# 配置防火墙
config_firewall() {
    local port=$1
    echo -e "${CYAN}>>> 配置防火墙规则...${NC}"
    
    # 自动检测防火墙类型
    if command -v ufw >/dev/null; then
        ufw allow "$port"/tcp
        ufw reload
    elif command -v firewall-cmd >/dev/null; then
        firewall-cmd --permanent --add-port="$port"/tcp
        firewall-cmd --reload
    elif [ -f "/etc/alpine-release" ]; then
        iptables -A INPUT -p tcp --dport "$port" -j ACCEPT
        service iptables save
    else
        echo -e "${YELLOW}警告: 未检测到支持的防火墙工具，请手动放行端口${NC}"
    fi
}

# 创建服务
create_service() {
    local port=$1 user=$2 pass=$3
    echo -e "${CYAN}>>> 创建系统服务...${NC}"

    cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=SOCKS5 Proxy Server
After=network.target

[Service]
Type=simple
User=root
ExecStart=$BIN_PATH -i 0.0.0.0 -6 :: -p $port -u $user -P $pass
Restart=always
RestartSec=10
StandardOutput=file:$LOG_FILE
StandardError=file:$LOG_FILE
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable socks5
    systemctl restart socks5
}

# 健康检查
health_check() {
    local port=$1 user=$2 pass=$3
    echo -e "${CYAN}>>> 运行健康检查...${NC}"

    # 检查服务状态
    if ! systemctl is-active socks5 >/dev/null; then
        echo -e "${RED}错误: 服务未运行!${NC}"
        journalctl -u socks5 -n 20 --no-pager
        return 1
    fi

    # 检查端口监听
    if ! ss -tulnp | grep -q ":$port"; then
        echo -e "${RED}错误: 端口未监听!${NC}"
        return 1
    fi

    # 测试本地连接
    if ! curl --socks5 "127.0.0.1:$port" --proxy-user "$user:$pass" -sSf https://ifconfig.co --connect-timeout 5 >/dev/null; then
        echo -e "${RED}错误: 本地连接测试失败!${NC}"
        tail -n 20 "$LOG_FILE"
        return 1
    fi

    echo -e "${GREEN}所有检查通过!${NC}"
    return 0
}

# 显示配置
show_config() {
    local port=$1 user=$2 pass=$3
    echo -e "\n${GREEN}========== 部署成功 ==========${NC}"
    echo -e "${CYAN}服务器IP:${NC} $(curl -s4 ifconfig.co || curl -s6 ifconfig.co || echo '未知')"
    echo -e "${CYAN}端口:${NC} $port"
    echo -e "${CYAN}用户名:${NC} $user"
    echo -e "${CYAN}密码:${NC} $pass"
    echo -e "${CYAN}日志文件:${NC} $LOG_FILE"
    
    echo -e "\n${YELLOW}测试命令:${NC}"
    echo "curl --socks5-hostname IP:$port --proxy-user $user:$pass https://ifconfig.co"
    
    echo -e "\n${GREEN}============================${NC}"
}

# 主安装流程
main_install() {
    init_install

    # 交互式配置
    echo -e "\n${BLUE}>>> SOCKS5服务器配置向导${NC}"
    read -p "输入监听端口 [默认: $(shuf -i 20000-60000 -n 1)]: " port
    port=${port:-$(shuf -i 20000-60000 -n 1)}
    
    read -p "输入用户名 [默认: user_$(openssl rand -hex 3)]: " user
    user=${user:-user_$(openssl rand -hex 3)}
    
    read -p "输入密码 [默认: $(openssl rand -hex 8)]: " pass
    pass=${pass:-$(openssl rand -hex 8)}

    # 执行安装
    config_firewall "$port"
    create_service "$port" "$user" "$pass"
    
    # 验证安装
    if health_check "$port" "$user" "$pass"; then
        show_config "$port" "$user" "$pass"
    else
        echo -e "${RED}安装遇到问题，请检查日志${NC}"
        exit 1
    fi
}

# 卸载功能
uninstall() {
    echo -e "${RED}>>> 正在卸载SOCKS5服务...${NC}"
    systemctl stop socks5 2>/dev/null
    systemctl disable socks5 2>/dev/null
    rm -f "$SERVICE_FILE"
    systemctl daemon-reload
    rm -f "$BIN_PATH"
    echo -e "${GREEN}已卸载SOCKS5服务${NC}"
}

# 诊断功能
diagnose() {
    echo -e "${CYAN}>>> 开始系统诊断...${NC}"
    
    echo -e "\n${YELLOW}1. 服务状态:${NC}"
    systemctl status socks5 --no-pager
    
    echo -e "\n${YELLOW}2. 端口监听:${NC}"
    ss -tulnp | grep -E "microsocks|:$port"
    
    echo -e "\n${YELLOW}3. 连接测试:${NC}"
    timeout 5 curl --socks5 "127.0.0.1:$port" --proxy-user "$user:$pass" -sSf https://ifconfig.co || \
    echo -e "${RED}连接测试失败!${NC}"
    
    echo -e "\n${YELLOW}4. 最近日志:${NC}"
    tail -n 20 "$LOG_FILE"
    
    echo -e "\n${CYAN}诊断完成${NC}"
}

# 脚本入口
clear
echo -e "${GREEN}=== SOCKS5服务器一键部署脚本 ===${NC}"

case "$1" in
    install)
        main_install
        ;;
    uninstall)
        uninstall
        ;;
    diagnose)
        diagnose
        ;;
    *)
        echo -e "使用方法: $0 [command]"
        echo -e "Commands:"
        echo -e "  install     - 安装SOCKS5服务器"
        echo -e "  uninstall   - 完全卸载"
        echo -e "  diagnose    - 诊断连接问题"
        exit 1
        ;;
esac
