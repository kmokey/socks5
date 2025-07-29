#!/bin/bash

# ==============================================
# SOCKS5 服务器管理脚本 (支持 IPv4/IPv6 + TLS)
# 版本: 2.0
# 支持系统: Debian/Ubuntu/Alpine
# ==============================================

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# 配置文件路径
CONFIG_FILE="/etc/socks5/config.json"
SERVICE_FILE="/etc/systemd/system/socks5.service"
LOG_FILE="/var/log/socks5.log"

# 默认值
DEFAULT_PORT=$(shuf -i 20000-60000 -n 1)
DEFAULT_USER="user_$(openssl rand -hex 3)"
DEFAULT_PASS=$(openssl rand -hex 8)
DEFAULT_IPV4="0.0.0.0"
DEFAULT_IPV6="::"

# 检查 root 权限
check_root() {
    if [ "$(id -u)" != "0" ]; then
        echo -e "${RED}错误: 此脚本必须使用 root 权限运行!${NC}" >&2
        exit 1
    fi
}

# 检测系统
detect_os() {
    if [ -f /etc/alpine-release ]; then
        echo "alpine"
    elif [ -f /etc/debian_version ]; then
        echo "debian"
    elif [ -f /etc/lsb-release ] && grep -q "Ubuntu" /etc/lsb-release; then
        echo "ubuntu"
    else
        echo "unknown"
    fi
}

# 安装依赖
install_dependencies() {
    local os_type=$1
    echo -e "${CYAN}正在安装系统依赖...${NC}"
    
    case "$os_type" in
        debian|ubuntu)
            apt-get update
            apt-get install -y wget curl unzip jq openssl
            ;;
        alpine)
            apk update
            apk add wget curl unzip jq openssl
            ;;
        *)
            echo -e "${YELLOW}未知系统，请手动安装依赖: wget curl unzip jq openssl${NC}"
            ;;
    esac
}

# 安装 microsocks
install_microsocks() {
    echo -e "${CYAN}正在安装 microsocks...${NC}"
    
    if [ -x "$(command -v microsocks)" ]; then
        echo -e "${GREEN}microsocks 已安装${NC}"
        return
    fi

    # 尝试从源码安装
    if ! wget https://github.com/rofl0r/microsocks/archive/refs/heads/master.zip -O /tmp/microsocks.zip || \
       ! unzip /tmp/microsocks.zip -d /tmp/ || \
       ! cd /tmp/microsocks-master || \
       ! make; then
        echo -e "${RED}源码安装失败，尝试预编译版本...${NC}"
        
        # 根据架构下载预编译版本
        case "$(uname -m)" in
            x86_64)
                wget https://github.com/rofl0r/microsocks/releases/download/v1.0.3/microsocks-x86_64-linux-gnu -O /usr/local/bin/microsocks
                ;;
            aarch64|arm64)
                wget https://github.com/rofl0r/microsocks/releases/download/v1.0.3/microsocks-aarch64-linux-gnu -O /usr/local/bin/microsocks
                ;;
            *)
                echo -e "${RED}不支持的架构: $(uname -m)${NC}"
                exit 1
                ;;
        esac
        
        chmod +x /usr/local/bin/microsocks
    else
        cp microsocks /usr/local/bin/
        cd ..
        rm -rf /tmp/microsocks-master /tmp/microsocks.zip
    fi

    if ! command -v microsocks &>/dev/null; then
        echo -e "${RED}microsocks 安装失败!${NC}"
        exit 1
    fi
    echo -e "${GREEN}microsocks 安装成功${NC}"
}

# 安装 simple-tls
install_simple_tls() {
    echo -e "${CYAN}正在安装 simple-tls...${NC}"
    
    if [ -x "$(command -v simple-tls)" ]; then
        echo -e "${GREEN}simple-tls 已安装${NC}"
        return
    fi

    # 根据架构下载
    case "$(uname -m)" in
        x86_64)
            wget https://github.com/v2fly/simple-tls/releases/download/v0.7.4/simple-tls-linux-amd64.zip -O /tmp/simple-tls.zip
            ;;
        aarch64|arm64)
            wget https://github.com/v2fly/simple-tls/releases/download/v0.7.4/simple-tls-linux-arm64.zip -O /tmp/simple-tls.zip
            ;;
        *)
            echo -e "${RED}不支持的架构: $(uname -m)${NC}"
            exit 1
            ;;
    esac

    unzip /tmp/simple-tls.zip -d /tmp/
    mv /tmp/simple-tls /usr/local/bin/
    chmod +x /usr/local/bin/simple-tls
    rm -f /tmp/simple-tls.zip

    if ! command -v simple-tls &>/dev/null; then
        echo -e "${RED}simple-tls 安装失败!${NC}"
        exit 1
    fi
    echo -e "${GREEN}simple-tls 安装成功${NC}"
}

# 生成 TLS 证书
generate_tls_cert() {
    echo -e "${CYAN}正在生成 TLS 证书...${NC}"
    mkdir -p /etc/socks5/tls
    
    if ! openssl req -x509 -nodes -days 3650 -newkey rsa:2048 \
        -keyout /etc/socks5/tls/socks5.key \
        -out /etc/socks5/tls/socks5.crt \
        -subj "/CN=socks5-server" &>/dev/null; then
        echo -e "${RED}TLS 证书生成失败!${NC}"
        exit 1
    fi
    
    chmod 600 /etc/socks5/tls/*
    echo -e "${GREEN}TLS 证书生成成功${NC}"
}

# 创建配置文件
create_config() {
    local port=$1
    local user=$2
    local pass=$3
    local use_tls=$4
    
    echo -e "${CYAN}正在创建配置文件...${NC}"
    mkdir -p /etc/socks5
    
    cat > "$CONFIG_FILE" <<EOF
{
    "port": $port,
    "ipv4": "$DEFAULT_IPV4",
    "ipv6": "$DEFAULT_IPV6",
    "username": "$user",
    "password": "$pass",
    "tls_enabled": $use_tls,
    "tls_cert": "/etc/socks5/tls/socks5.crt",
    "tls_key": "/etc/socks5/tls/socks5.key"
}
EOF

    echo -e "${GREEN}配置文件已创建: $CONFIG_FILE${NC}"
}

# 创建 systemd 服务
create_service() {
    echo -e "${CYAN}正在创建系统服务...${NC}"
    
    local config=$(cat "$CONFIG_FILE")
    local port=$(jq -r '.port' <<< "$config")
    local user=$(jq -r '.username' <<< "$config")
    local pass=$(jq -r '.password' <<< "$config")
    local tls_enabled=$(jq -r '.tls_enabled' <<< "$config")
    
    cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=SOCKS5 Proxy Server
After=network.target

[Service]
Type=simple
User=root
ExecStartPre=/bin/sleep 3
EOF

    if [ "$tls_enabled" = "true" ]; then
        cat >> "$SERVICE_FILE" <<EOF
ExecStart=/usr/local/bin/simple-tls -l :${port} -k /etc/socks5/tls/socks5.key -c /etc/socks5/tls/socks5.crt --exec "/usr/local/bin/microsocks -i ${DEFAULT_IPV4} -6 ${DEFAULT_IPV6} -u ${user} -P ${pass}"
EOF
    else
        cat >> "$SERVICE_FILE" <<EOF
ExecStart=/usr/local/bin/microsocks -i ${DEFAULT_IPV4} -6 ${DEFAULT_IPV6} -p ${port} -u ${user} -P ${pass}
EOF
    fi

    cat >> "$SERVICE_FILE" <<EOF
Restart=always
RestartSec=10
StandardOutput=file:${LOG_FILE}
StandardError=file:${LOG_FILE}

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable socks5
    systemctl restart socks5
    
    echo -e "${GREEN}服务已创建并启动${NC}"
}

# 显示配置信息
show_config() {
    if [ ! -f "$CONFIG_FILE" ]; then
        echo -e "${RED}未找到配置文件，请先安装服务!${NC}"
        return
    fi
    
    local config=$(cat "$CONFIG_FILE")
    local port=$(jq -r '.port' <<< "$config")
    local user=$(jq -r '.username' <<< "$config")
    local pass=$(jq -r '.password' <<< "$config")
    local tls_enabled=$(jq -r '.tls_enabled' <<< "$config")
    
    local public_ipv4=$(curl -s4 ifconfig.co || echo "未知")
    local public_ipv6=$(curl -s6 ifconfig.co || echo "未知")
    
    echo -e "\n${GREEN}============== SOCKS5 配置信息 ==============${NC}"
    echo -e "${CYAN}服务器IPv4:${NC} $public_ipv4"
    echo -e "${CYAN}服务器IPv6:${NC} $public_ipv6"
    echo -e "${CYAN}端口:${NC} $port"
    echo -e "${CYAN}用户名:${NC} $user"
    echo -e "${CYAN}密码:${NC} $pass"
    echo -e "${CYAN}TLS加密:${NC} $tls_enabled"
    
    if [ "$tls_enabled" = "true" ]; then
        echo -e "\n${YELLOW}支持TLS的客户端连接格式:${NC}"
        echo -e "socks5://${user}:${pass}@${public_ipv4}:${port}?tls=true"
        echo -e "\n${YELLOW}cURL测试命令:${NC}"
        echo -e "curl --socks5-hostname ${public_ipv4}:${port} --proxy-user ${user}:${pass} --proxy-insecure -k https://example.com"
    else
        echo -e "\n${YELLOW}普通客户端连接格式:${NC}"
        echo -e "socks5://${user}:${pass}@${public_ipv4}:${port}"
        echo -e "\n${YELLOW}cURL测试命令:${NC}"
        echo -e "curl --socks5-hostname ${public_ipv4}:${port} --proxy-user ${user}:${pass} https://example.com"
    fi
    
    echo -e "\n${GREEN}===========================================${NC}"
}

# 修改配置
modify_config() {
    if [ ! -f "$CONFIG_FILE" ]; then
        echo -e "${RED}未找到配置文件，请先安装服务!${NC}"
        return
    fi
    
    local config=$(cat "$CONFIG_FILE")
    local current_port=$(jq -r '.port' <<< "$config")
    local current_user=$(jq -r '.username' <<< "$config")
    local current_pass=$(jq -r '.password' <<< "$config")
    local current_tls=$(jq -r '.tls_enabled' <<< "$config")
    
    echo -e "\n${CYAN}当前配置:${NC}"
    echo -e "1. 端口: $current_port"
    echo -e "2. 用户名: $current_user"
    echo -e "3. 密码: $current_pass"
    echo -e "4. TLS加密: $current_tls"
    echo -e "5. 返回主菜单"
    
    read -p "请选择要修改的选项 (1-5): " choice
    
    case $choice in
        1)
            read -p "请输入新端口 (当前: $current_port): " new_port
            if [[ "$new_port" =~ ^[0-9]+$ ]] && [ "$new_port" -ge 1 ] && [ "$new_port" -le 65535 ]; then
                jq ".port = $new_port" "$CONFIG_FILE" > /tmp/socks5_config.tmp && mv /tmp/socks5_config.tmp "$CONFIG_FILE"
                systemctl restart socks5
                echo -e "${GREEN}端口已修改为 $new_port${NC}"
            else
                echo -e "${RED}无效的端口号!${NC}"
            fi
            ;;
        2)
            read -p "请输入新用户名 (当前: $current_user): " new_user
            if [ -n "$new_user" ]; then
                jq ".username = \"$new_user\"" "$CONFIG_FILE" > /tmp/socks5_config.tmp && mv /tmp/socks5_config.tmp "$CONFIG_FILE"
                systemctl restart socks5
                echo -e "${GREEN}用户名已修改为 $new_user${NC}"
            else
                echo -e "${RED}用户名不能为空!${NC}"
            fi
            ;;
        3)
            read -p "请输入新密码 (当前: $current_pass): " new_pass
            if [ -n "$new_pass" ]; then
                jq ".password = \"$new_pass\"" "$CONFIG_FILE" > /tmp/socks5_config.tmp && mv /tmp/socks5_config.tmp "$CONFIG_FILE"
                systemctl restart socks5
                echo -e "${GREEN}密码已修改${NC}"
            else
                echo -e "${RED}密码不能为空!${NC}"
            fi
            ;;
        4)
            local new_tls="false"
            if [ "$current_tls" = "false" ]; then
                new_tls="true"
                generate_tls_cert
            else
                echo -e "${YELLOW}禁用 TLS 后连接将不再加密!${NC}"
                read -p "确定要禁用 TLS 吗? (y/N): " confirm
                if [[ "$confirm" =~ ^[Yy]$ ]]; then
                    new_tls="false"
                else
                    return
                fi
            fi
            jq ".tls_enabled = $new_tls" "$CONFIG_FILE" > /tmp/socks5_config.tmp && mv /tmp/socks5_config.tmp "$CONFIG_FILE"
            systemctl restart socks5
            echo -e "${GREEN}TLS 设置已修改为 $new_tls${NC}"
            ;;
        5)
            return
            ;;
        *)
            echo -e "${RED}无效选择!${NC}"
            ;;
    esac
    
    # 递归调用以继续修改
    modify_config
}

# 卸载服务
uninstall() {
    echo -e "${RED}正在卸载 SOCKS5 服务...${NC}"
    
    systemctl stop socks5 2>/dev/null
    systemctl disable socks5 2>/dev/null
    rm -f "$SERVICE_FILE"
    systemctl daemon-reload
    
    rm -f /usr/local/bin/microsocks
    rm -f /usr/local/bin/simple-tls
    rm -rf /etc/socks5
    rm -f "$LOG_FILE"
    
    echo -e "${GREEN}SOCKS5 服务已卸载${NC}"
}

# 安装服务
install() {
    check_root
    local os_type=$(detect_os)
    
    echo -e "\n${GREEN}====== SOCKS5 服务器安装向导 ======${NC}"
    
    # 获取用户输入
    read -p "请输入端口号 [默认: $DEFAULT_PORT]: " port
    port=${port:-$DEFAULT_PORT}
    
    read -p "请输入用户名 [默认: $DEFAULT_USER]: " user
    user=${user:-$DEFAULT_USER}
    
    read -p "请输入密码 [默认: 随机生成]: " pass
    pass=${pass:-$DEFAULT_PASS}
    
    read -p "启用 TLS 加密? [Y/n]: " tls_answer
    if [[ "$tls_answer" =~ ^[Nn]$ ]]; then
        use_tls="false"
    else
        use_tls="true"
    fi
    
    # 开始安装
    echo -e "\n${CYAN}开始安装 SOCKS5 服务器...${NC}"
    install_dependencies "$os_type"
    install_microsocks
    
    if [ "$use_tls" = "true" ]; then
        install_simple_tls
        generate_tls_cert
    fi
    
    create_config "$port" "$user" "$pass" "$use_tls"
    create_service
    
    echo -e "\n${GREEN}====== 安装完成 ======${NC}"
    show_config
}

# 主菜单
main_menu() {
    while true; do
        echo -e "\n${BLUE}======== SOCKS5 服务器管理菜单 ========${NC}"
        echo -e "1. 安装/重新安装 SOCKS5 服务器"
        echo -e "2. 修改配置"
        echo -e "3. 查看当前配置"
        echo -e "4. 卸载 SOCKS5 服务器"
        echo -e "5. 退出"
        
        read -p "请选择操作 (1-5): " choice
        
        case $choice in
            1)
                install
                ;;
            2)
                modify_config
                ;;
            3)
                show_config
                ;;
            4)
                uninstall
                ;;
            5)
                echo -e "${GREEN}再见!${NC}"
                exit 0
                ;;
            *)
                echo -e "${RED}无效选择!${NC}"
                ;;
        esac
    done
}

# 启动脚本
clear
echo -e "${GREEN}=== SOCKS5 服务器管理脚本 v2.0 ===${NC}"
echo -e "支持: IPv4/IPv6 | TLS 加密 | 多用户认证"
echo -e "兼容: Debian/Ubuntu/Alpine\n"

check_root
main_menu
