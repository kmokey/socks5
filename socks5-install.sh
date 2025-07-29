#!/bin/bash

# 脚本信息
SCRIPT_NAME="SOCKS5 服务器安装脚本"
SCRIPT_VERSION="1.0"
SCRIPT_AUTHOR="Your Name"
SCRIPT_UPDATE="2023-11-01"

# 默认配置
DEFAULT_PORT=$(shuf -i 20000-60000 -n 1)
DEFAULT_USER="user_$(openssl rand -hex 3)"
DEFAULT_PASS=$(openssl rand -hex 8)
DEFAULT_IP="0.0.0.0"
DEFAULT_IPV6="::"

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# 检查root权限
check_root() {
    if [ "$(id -u)" != "0" ]; then
        echo -e "${RED}错误: 此脚本必须以root权限运行${NC}" >&2
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
        echo -e "${YELLOW}警告: 未知系统，将尝试使用通用安装方法${NC}"
        echo "unknown"
    fi
}

# 安装必要组件
install_dependencies() {
    local os_type=$1
    
    echo -e "${BLUE}正在安装必要组件...${NC}"
    
    case "$os_type" in
        debian|ubuntu)
            apt-get update
            apt-get install -y wget openssl gcc make
            ;;
        alpine)
            apk update
            apk add wget openssl gcc make
            ;;
        *)
            echo -e "${YELLOW}未知系统，请手动安装以下组件: wget openssl gcc make${NC}"
            ;;
    esac
}

# 安装microsocks
install_microsocks() {
    echo -e "${BLUE}正在安装microsocks...${NC}"
    
    if [ -x "$(command -v microsocks)" ]; then
        echo -e "${GREEN}microsocks 已经安装${NC}"
        return
    fi
    
    wget https://github.com/rofl0r/microsocks/archive/refs/heads/master.zip -O microsocks.zip
    unzip microsocks.zip
    cd microsocks-master
    make
    cp microsocks /usr/local/bin/
    cd ..
    rm -rf microsocks-master microsocks.zip
    
    if [ ! -x "$(command -v microsocks)" ]; then
        echo -e "${RED}microsocks 安装失败${NC}"
        exit 1
    fi
    
    echo -e "${GREEN}microsocks 安装成功${NC}"
}

# 生成TLS证书
generate_tls_cert() {
    echo -e "${BLUE}正在生成TLS证书...${NC}"
    
    mkdir -p /etc/socks5/tls
    openssl req -x509 -nodes -days 3650 -newkey rsa:2048 \
        -keyout /etc/socks5/tls/socks5.key \
        -out /etc/socks5/tls/socks5.crt \
        -subj "/CN=socks5-server"
    
    chmod 600 /etc/socks5/tls/*
    
    echo -e "${GREEN}TLS证书生成成功${NC}"
}

# 安装simple-tls
install_simple_tls() {
    echo -e "${BLUE}正在安装simple-tls...${NC}"
    
    if [ -x "$(command -v simple-tls)" ]; then
        echo -e "${GREEN}simple-tls 已经安装${NC}"
        return
    fi
    
    local arch=$(uname -m)
    local url=""
    
    case "$arch" in
        x86_64)
            url="https://github.com/v2fly/simple-tls/releases/download/v0.7.4/simple-tls-linux-amd64.zip"
            ;;
        aarch64|arm64)
            url="https://github.com/v2fly/simple-tls/releases/download/v0.7.4/simple-tls-linux-arm64.zip"
            ;;
        armv7l)
            url="https://github.com/v2fly/simple-tls/releases/download/v0.7.4/simple-tls-linux-arm.zip"
            ;;
        *)
            echo -e "${RED}不支持的架构: $arch${NC}"
            exit 1
            ;;
    esac
    
    wget "$url" -O simple-tls.zip
    unzip simple-tls.zip
    mv simple-tls /usr/local/bin/
    chmod +x /usr/local/bin/simple-tls
    rm -f simple-tls.zip
    
    if [ ! -x "$(command -v simple-tls)" ]; then
        echo -e "${RED}simple-tls 安装失败${NC}"
        exit 1
    fi
    
    echo -e "${GREEN}simple-tls 安装成功${NC}"
}

# 创建systemd服务
create_systemd_service() {
    local port=$1
    local user=$2
    local pass=$3
    local use_tls=$4
    
    echo -e "${BLUE}正在创建systemd服务...${NC}"
    
    cat > /etc/systemd/system/socks5.service <<EOF
[Unit]
Description=SOCKS5 Proxy Server
After=network.target

[Service]
Type=simple
User=root
EOF

    if [ "$use_tls" = "true" ]; then
        cat >> /etc/systemd/system/socks5.service <<EOF
ExecStart=/usr/local/bin/simple-tls -l :${port} -k /etc/socks5/tls/socks5.key -c /etc/socks5/tls/socks5.crt --exec "/usr/local/bin/microsocks -i ${DEFAULT_IP} -6 ${DEFAULT_IPV6} -u ${user} -P ${pass}"
EOF
    else
        cat >> /etc/systemd/system/socks5.service <<EOF
ExecStart=/usr/local/bin/microsocks -i ${DEFAULT_IP} -6 ${DEFAULT_IPV6} -p ${port} -u ${user} -P ${pass}
EOF
    fi

    cat >> /etc/systemd/system/socks5.service <<EOF
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable socks5
    systemctl start socks5
    
    echo -e "${GREEN}socks5服务创建成功${NC}"
}

# 安装SOCKS5服务器
install_socks5() {
    local port=$1
    local user=$2
    local pass=$3
    local use_tls=$4
    
    check_root
    local os_type=$(detect_os)
    
    echo -e "${GREEN}开始安装SOCKS5服务器...${NC}"
    
    install_dependencies "$os_type"
    install_microsocks
    
    if [ "$use_tls" = "true" ]; then
        generate_tls_cert
        install_simple_tls
    fi
    
    create_systemd_service "$port" "$user" "$pass" "$use_tls"
    
    echo -e "${GREEN}SOCKS5服务器安装完成!${NC}"
}

# 卸载SOCKS5服务器
uninstall_socks5() {
    check_root
    
    echo -e "${BLUE}开始卸载SOCKS5服务器...${NC}"
    
    systemctl stop socks5 2>/dev/null
    systemctl disable socks5 2>/dev/null
    rm -f /etc/systemd/system/socks5.service
    systemctl daemon-reload
    
    rm -f /usr/local/bin/microsocks
    rm -f /usr/local/bin/simple-tls
    rm -rf /etc/socks5
    
    echo -e "${GREEN}SOCKS5服务器已卸载${NC}"
}

# 显示配置信息
show_config() {
    local port=$1
    local user=$2
    local pass=$3
    local use_tls=$4
    
    local public_ip=$(curl -s https://api.ipify.org || echo "未知")
    local ipv6_address=$(ip -6 addr show scope global | grep inet6 | awk '{print $2}' | cut -d'/' -f1 | head -n1)
    
    echo -e "\n${GREEN}========== SOCKS5 服务器配置 ==========${NC}"
    echo -e "${BLUE}服务器IP:${NC} ${public_ip}"
    if [ -n "$ipv6_address" ]; then
        echo -e "${BLUE}IPv6地址:${NC} ${ipv6_address}"
    fi
    echo -e "${BLUE}端口:${NC} ${port}"
    echo -e "${BLUE}用户名:${NC} ${user}"
    echo -e "${BLUE}密码:${NC} ${pass}"
    
    if [ "$use_tls" = "true" ]; then
        echo -e "${BLUE}加密:${NC} TLS/SSL 已启用"
        echo -e "\n${YELLOW}客户端连接示例 (支持TLS的客户端):${NC}"
        echo -e "socks5://${user}:${pass}@${public_ip}:${port}?tls=true"
    else
        echo -e "${BLUE}加密:${NC} 未启用"
        echo -e "\n${YELLOW}客户端连接示例:${NC}"
        echo -e "socks5://${user}:${pass}@${public_ip}:${port}"
    fi
    
    echo -e "\n${YELLOW}cURL 使用示例:${NC}"
    if [ "$use_tls" = "true" ]; then
        echo -e "curl --socks5-hostname ${public_ip}:${port} --proxy-user ${user}:${pass} --proxy-insecure -k https://example.com"
    else
        echo -e "curl --socks5-hostname ${public_ip}:${port} --proxy-user ${user}:${pass} https://example.com"
    fi
    
    echo -e "\n${GREEN}======================================${NC}"
}

# 主菜单
main() {
    echo -e "${GREEN}${SCRIPT_NAME} v${SCRIPT_VERSION}${NC}"
    echo -e "作者: ${SCRIPT_AUTHOR}"
    echo -e "更新日期: ${SCRIPT_UPDATE}\n"
    
    if [ "$1" = "uninstall" ]; then
        uninstall_socks5
        exit 0
    fi
    
    local port=""
    local user=""
    local pass=""
    local use_tls="false"
    
    # 解析参数
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -p|--port)
                port="$2"
                shift 2
                ;;
            -u|--user)
                user="$2"
                shift 2
                ;;
            -P|--password)
                pass="$2"
                shift 2
                ;;
            -t|--tls)
                use_tls="true"
                shift
                ;;
            *)
                echo -e "${RED}未知参数: $1${NC}"
                exit 1
                ;;
        esac
    done
    
    # 交互式设置
    if [ -z "$port" ]; then
        echo -e "${YELLOW}请输入SOCKS5服务器端口 [默认: ${DEFAULT_PORT}]:${NC}"
        read -r input_port
        port=${input_port:-$DEFAULT_PORT}
    fi
    
    if [ -z "$user" ]; then
        echo -e "${YELLOW}请输入SOCKS5用户名 [默认: ${DEFAULT_USER}]:${NC}"
        read -r input_user
        user=${input_user:-$DEFAULT_USER}
    fi
    
    if [ -z "$pass" ]; then
        echo -e "${YELLOW}请输入SOCKS5密码 [默认: 随机生成]:${NC}"
        read -r input_pass
        pass=${input_pass:-$DEFAULT_PASS}
    fi
    
    if [ "$use_tls" = "false" ]; then
        echo -e "${YELLOW}是否启用TLS加密? [y/N]:${NC}"
        read -r tls_answer
        if [[ "$tls_answer" =~ ^[Yy]$ ]]; then
            use_tls="true"
        fi
    fi
    
    # 安装
    install_socks5 "$port" "$user" "$pass" "$use_tls"
    
    # 显示配置
    show_config "$port" "$user" "$pass" "$use_tls"
    
    # 保存配置
    mkdir -p /etc/socks5
    cat > /etc/socks5/config <<EOF
PORT=$port
USER=$user
PASS=$pass
TLS=$use_tls
EOF
}

main "$@"
