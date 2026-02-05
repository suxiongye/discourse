#!/bin/bash
# ============================================================
# Discourse 项目依赖安装脚本
# 
# 用法:
#   chmod +x setup_project.sh
#   ./setup_project.sh
#
# 前提: 已运行 setup_env.sh 安装好系统环境
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

# 项目根目录
PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

# ============================================================
# 加载环境
# ============================================================
load_env() {
    export HOME="/root"
    
    # 加载 rbenv
    if [ -d "$HOME/.rbenv" ]; then
        export PATH="$HOME/.rbenv/bin:$PATH"
        eval "$(rbenv init -)"
    fi
    
    # 加载 nvm
    export NVM_DIR="$HOME/.nvm"
    [ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"
}

# ============================================================
# 检查环境
# ============================================================
check_env() {
    log_step "检查环境"
    
    local has_error=false
    
    if ! command -v ruby &> /dev/null; then
        log_error "Ruby 未安装，请先运行 ./setup_env.sh"
        has_error=true
    else
        log_info "Ruby: $(ruby --version)"
    fi
    
    if ! command -v node &> /dev/null; then
        log_error "Node.js 未安装，请先运行 ./setup_env.sh"
        has_error=true
    else
        log_info "Node.js: $(node --version)"
    fi
    
    if ! command -v pnpm &> /dev/null; then
        log_error "pnpm 未安装，请先运行 ./setup_env.sh"
        has_error=true
    else
        log_info "pnpm: $(pnpm --version)"
    fi
    
    if ! redis-cli ping &> /dev/null; then
        log_warn "Redis 未运行，尝试启动..."
        sudo systemctl start redis || true
    else
        log_info "Redis: 运行中"
    fi
    
    if [ "$has_error" = true ]; then
        exit 1
    fi
}

# ============================================================
# 安装 Ruby 依赖
# ============================================================
install_ruby_deps() {
    log_step "安装 Ruby 依赖 (bundle install)"
    
    cd "$PROJECT_ROOT"
    
    # 配置 bundler
    bundle config set --global mirror.https://rubygems.org https://gems.ruby-china.com
    bundle config set --local path 'vendor/bundle'
    
    # 安装依赖
    bundle install --jobs 4 --retry 3
    
    log_info "Ruby 依赖安装完成"
}

# ============================================================
# 安装前端依赖
# ============================================================
install_frontend_deps() {
    log_step "安装前端依赖 (pnpm install)"
    
    cd "$PROJECT_ROOT"
    
    pnpm install
    
    log_info "前端依赖安装完成"
}

# ============================================================
# 配置 Nginx
# ============================================================
setup_nginx() {
    log_step "配置 Nginx"
    
    cd "$PROJECT_ROOT"
    
    if [ -f "nginx_dev.conf" ]; then
        sudo cp nginx_dev.conf /etc/nginx/conf.d/discourse_dev.conf
        
        # 测试配置
        if sudo nginx -t; then
            sudo systemctl reload nginx
            log_info "Nginx 配置完成"
        else
            log_error "Nginx 配置有误，请检查"
        fi
    else
        log_warn "nginx_dev.conf 不存在，跳过 Nginx 配置"
    fi
}

# ============================================================
# 设置文件权限
# ============================================================
setup_permissions() {
    log_step "设置文件权限"
    
    cd "$PROJECT_ROOT"
    
    # 创建必要目录
    mkdir -p tmp/pids tmp/sockets log public/assets
    
    # SSL 证书权限
    if [ -d "ssl" ]; then
        chmod 600 ssl/*.key 2>/dev/null || true
        chmod 644 ssl/*.crt 2>/dev/null || true
    fi
    
    # 脚本执行权限
    chmod +x dev_start.sh 2>/dev/null || true
    chmod +x scripts/*.sh 2>/dev/null || true
    
    log_info "权限设置完成"
}

# ============================================================
# 测试数据库连接
# ============================================================
test_database() {
    log_step "测试数据库连接"
    
    cd "$PROJECT_ROOT"
    
    # 加载环境变量
    source dev_start.sh 2>/dev/null || true
    
   
    if psql "$DB_URL" -c "SELECT 1;" &> /dev/null; then
        log_info "数据库连接成功"
    else
        log_warn "数据库连接失败，请检查 DATABASE_URL 配置"
        log_warn "当前配置: $DB_URL"
    fi
}

# ============================================================
# 打印完成信息
# ============================================================
print_summary() {
    log_step "项目配置完成！"
    
    echo ""
    echo "启动服务:"
    echo "  cd $PROJECT_ROOT"
    echo "  ./dev_start.sh start"
    echo ""
    echo "常用命令:"
    echo "  ./dev_start.sh start    - 前台启动"
    echo "  ./dev_start.sh daemon   - 后台启动"
    echo "  ./dev_start.sh restart  - 重启"
    echo "  ./dev_start.sh stop     - 停止"
    echo "  ./dev_start.sh logs     - 查看日志"
    echo ""
    echo "访问地址:"
    echo "  https://dev.orcaspace.woa.com"
    echo ""
}

# ============================================================
# 主函数
# ============================================================
main() {
    echo ""
    echo "============================================================"
    echo "    Discourse 项目依赖安装"
    echo "    项目目录: $PROJECT_ROOT"
    echo "============================================================"
    echo ""
    
    load_env
    check_env
    install_ruby_deps
    install_frontend_deps
    setup_permissions
    setup_nginx
    test_database
    print_summary
}

# 运行
main "$@"
