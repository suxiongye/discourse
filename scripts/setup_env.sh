#!/bin/bash
# ============================================================
# Discourse 开发环境一键安装脚本
# 适用系统: TencentOS / CentOS 8+
# 
# 用法:
#   chmod +x setup_env.sh
#   ./setup_env.sh
#
# 安装内容:
#   - 系统依赖库
#   - Ruby 3.3.0 (rbenv)
#   - Node.js 20.x (nvm)
#   - pnpm
#   - Redis 
#   - PostgreSQL 客户端
#   - Nginx
# ============================================================

set -e

# 颜色输出
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }
log_step() { echo -e "\n${BLUE}========================================${NC}"; echo -e "${BLUE}$1${NC}"; echo -e "${BLUE}========================================${NC}"; }

# 检查是否为 root
check_root() {
    if [ "$EUID" -ne 0 ]; then
        log_error "请使用 root 用户运行此脚本"
        log_info "sudo ./setup_env.sh"
        exit 1
    fi
}

# ============================================================
# 步骤 1: 安装系统依赖
# ============================================================
install_system_deps() {
    log_step "步骤 1/7: 安装系统依赖"
    
    yum update -y
    
    yum install -y \
        gcc gcc-c++ make \
        openssl-devel readline-devel zlib-devel \
        libffi-devel libyaml-devel \
        ImageMagick ImageMagick-devel \
        libxml2-devel libxslt-devel \
        bzip2 autoconf automake libtool bison \
        sqlite-devel \
        git curl wget \
        lvm2 \
        postgresql
    
    log_info "系统依赖安装完成"
}

# ============================================================
# 步骤 2: 安装 Docker（可选）
# ============================================================
install_docker() {
    log_step "步骤 2/7: 检查 Docker"
    
    if command -v docker &> /dev/null; then
        log_info "Docker 已安装: $(docker --version)"
    else
        log_warn "Docker 未安装，跳过（原生开发模式不需要）"
    fi
    
    # 确保 Docker 服务运行
    if systemctl is-active --quiet docker; then
        log_info "Docker 服务运行中"
    else
        log_warn "Docker 服务未运行"
    fi
}

# ============================================================
# 步骤 3: 安装 rbenv 和 Ruby
# ============================================================
install_ruby() {
    log_step "步骤 3/7: 安装 Ruby 3.3.0"
    
    RUBY_VERSION="3.3.0"
    
    # 检查是否已安装
    if command -v ruby &> /dev/null; then
        current_version=$(ruby --version | awk '{print $2}')
        if [[ "$current_version" == "$RUBY_VERSION"* ]]; then
            log_info "Ruby $RUBY_VERSION 已安装"
            return 0
        fi
    fi
    
    # 为非 root 用户安装（假设是 root）
    export HOME="/root"
    
    # 安装 rbenv
    if [ ! -d "$HOME/.rbenv" ]; then
        log_info "安装 rbenv..."
        git clone https://github.com/rbenv/rbenv.git "$HOME/.rbenv"
        
        # 添加到 bashrc
        if ! grep -q 'rbenv' "$HOME/.bashrc"; then
            echo '' >> "$HOME/.bashrc"
            echo '# rbenv' >> "$HOME/.bashrc"
            echo 'export PATH="$HOME/.rbenv/bin:$PATH"' >> "$HOME/.bashrc"
            echo 'eval "$(rbenv init -)"' >> "$HOME/.bashrc"
        fi
    fi
    
    # 安装 ruby-build
    if [ ! -d "$HOME/.rbenv/plugins/ruby-build" ]; then
        log_info "安装 ruby-build..."
        git clone https://github.com/rbenv/ruby-build.git "$HOME/.rbenv/plugins/ruby-build"
    fi
    
    # 加载 rbenv
    export PATH="$HOME/.rbenv/bin:$PATH"
    eval "$(rbenv init -)"
    
    # 安装 Ruby
    if ! rbenv versions | grep -q "$RUBY_VERSION"; then
        log_info "编译安装 Ruby $RUBY_VERSION（需要 5-10 分钟）..."
        rbenv install "$RUBY_VERSION"
    fi
    
    rbenv global "$RUBY_VERSION"
    
    log_info "Ruby 安装完成: $(ruby --version)"
}

# ============================================================
# 步骤 4: 安装 Node.js
# ============================================================
install_nodejs() {
    log_step "步骤 4/7: 安装 Node.js 20.x"
    
    NODE_VERSION="20"
    
    # 检查是否已安装
    if command -v node &> /dev/null; then
        current_version=$(node --version | cut -d'.' -f1 | tr -d 'v')
        if [ "$current_version" -ge "$NODE_VERSION" ]; then
            log_info "Node.js 已安装: $(node --version)"
            return 0
        fi
    fi
    
    export HOME="/root"
    
    # 安装 nvm
    if [ ! -d "$HOME/.nvm" ]; then
        log_info "安装 nvm..."
        curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.39.7/install.sh | bash
    fi
    
    # 加载 nvm
    export NVM_DIR="$HOME/.nvm"
    [ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"
    
    # 安装 Node.js
    log_info "安装 Node.js $NODE_VERSION..."
    nvm install "$NODE_VERSION"
    nvm use "$NODE_VERSION"
    nvm alias default "$NODE_VERSION"
    
    log_info "Node.js 安装完成: $(node --version)"
}

# ============================================================
# 步骤 5: 安装 pnpm
# ============================================================
install_pnpm() {
    log_step "步骤 5/7: 安装 pnpm"
    
    # 加载 nvm
    export NVM_DIR="$HOME/.nvm"
    [ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"
    
    if command -v pnpm &> /dev/null; then
        log_info "pnpm 已安装: $(pnpm --version)"
        return 0
    fi
    
    log_info "安装 pnpm..."
    npm install -g pnpm
    
    log_info "pnpm 安装完成: $(pnpm --version)"
}

# ============================================================
# 步骤 6: 安装 Redis
# ============================================================
install_redis() {
    log_step "步骤 6/7: 安装 Redis"
    
    if command -v redis-server &> /dev/null; then
        log_info "Redis 已安装: $(redis-server --version | head -1)"
    else
        log_info "安装 Redis..."
        yum install -y redis
    fi
    
    # 启动 Redis
    systemctl start redis || true
    systemctl enable redis || true
    
    # 验证
    if redis-cli ping | grep -q "PONG"; then
        log_info "Redis 运行正常"
    else
        log_warn "Redis 可能未正常运行，请检查"
    fi
}

# ============================================================
# 步骤 7: 安装 Nginx
# ============================================================
install_nginx() {
    log_step "步骤 7/7: 安装 Nginx"
    
    if command -v nginx &> /dev/null; then
        log_info "Nginx 已安装: $(nginx -v 2>&1)"
    else
        log_info "安装 Nginx..."
        yum install -y nginx
    fi
    
    # 启动 Nginx
    systemctl start nginx || true
    systemctl enable nginx || true
    
    log_info "Nginx 安装完成"
}

# ============================================================
# 配置 bundler 镜像源
# ============================================================
configure_bundler() {
    log_step "配置 Bundler 国内镜像"
    
    # 加载 rbenv
    export PATH="$HOME/.rbenv/bin:$PATH"
    eval "$(rbenv init -)" 2>/dev/null || true
    
    if command -v bundle &> /dev/null; then
        bundle config set --global mirror.https://rubygems.org https://gems.ruby-china.com
        log_info "Bundler 镜像配置完成"
    fi
}

# ============================================================
# 打印环境信息
# ============================================================
print_summary() {
    log_step "安装完成！环境信息"
    
    # 重新加载环境
    export HOME="/root"
    export PATH="$HOME/.rbenv/bin:$PATH"
    eval "$(rbenv init -)" 2>/dev/null || true
    export NVM_DIR="$HOME/.nvm"
    [ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"
    
    echo ""
    echo "系统信息:"
    echo "  - OS: $(cat /etc/os-release | grep PRETTY_NAME | cut -d'"' -f2)"
    echo ""
    echo "已安装组件:"
    echo "  - Ruby:    $(ruby --version 2>/dev/null || echo '未安装')"
    echo "  - Node.js: $(node --version 2>/dev/null || echo '未安装')"
    echo "  - pnpm:    $(pnpm --version 2>/dev/null || echo '未安装')"
    echo "  - Redis:   $(redis-server --version 2>/dev/null | awk '{print $3}' || echo '未安装')"
    echo "  - Nginx:   $(nginx -v 2>&1 | awk -F'/' '{print $2}' || echo '未安装')"
    echo "  - psql:    $(psql --version 2>/dev/null | awk '{print $3}' || echo '未安装')"
    echo ""
    echo -e "${GREEN}下一步操作:${NC}"
    echo ""
    echo "  1. 重新加载 shell 环境:"
    echo "     source ~/.bashrc"
    echo ""
    echo "  2. 进入项目目录安装依赖:"
    echo "     cd /root/orcaspaces"
    echo "     bundle install"
    echo "     pnpm install"
    echo ""
    echo "  3. 配置 Nginx:"
    echo "     cp nginx_dev.conf /etc/nginx/conf.d/discourse_dev.conf"
    echo "     nginx -t && systemctl reload nginx"
    echo ""
    echo "  4. 启动 Discourse:"
    echo "     ./dev_start.sh start"
    echo ""
    echo "  5. 访问:"
    echo "     https://dev.orcaspace.woa.com"
    echo ""
}

# ============================================================
# 主函数
# ============================================================
main() {
    echo ""
    echo "============================================================"
    echo "    Discourse 开发环境一键安装脚本"
    echo "    适用: TencentOS / CentOS 8+"
    echo "============================================================"
    echo ""
    
    check_root
    
    install_system_deps
    install_docker
    install_ruby
    install_nodejs
    install_pnpm
    install_redis
    install_nginx
    configure_bundler
    
    print_summary
}

# 运行
main "$@"
