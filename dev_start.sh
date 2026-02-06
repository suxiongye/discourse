#!/bin/bash
# Discourse 开发模式启动脚本
# 用法:
#   ./dev_start.sh              - 前台启动完整开发环境（端口 4200，支持热重载）
#   ./dev_start.sh daemon       - 后台启动完整开发环境
#   ./dev_start.sh stop         - 停止服务
#   ./dev_start.sh restart      - 重启服务（后台）
#   ./dev_start.sh status       - 查看状态
#   ./dev_start.sh logs         - 查看日志
#   ./dev_start.sh rails        - 仅启动 Rails 后端（端口 3000）

set -e

# ========================================
# 配置区域（根据需要修改）
# ========================================
APP_ROOT="$(cd "$(dirname "$0")" && pwd)"
PID_FILE="$APP_ROOT/tmp/pids/server.pid"
EMBER_PID_FILE="$APP_ROOT/tmp/pids/ember-cli.pid"
LOG_FILE="$APP_ROOT/log/development.log"
EMBER_LOG_FILE="$APP_ROOT/log/ember-cli.log"
PORT=3000

# ========================================
# 环境变量
# ========================================
export APP_ROOT="$APP_ROOT"

# Redis 配置（本地 Redis）
export DISCOURSE_REDIS_HOST="127.0.0.1"
export DISCOURSE_REDIS_PORT="6379"
# export DISCOURSE_REDIS_PASSWORD="Tshjl!123"  # 本地 Redis 如果没密码就注释掉

# 开发模式
export RAILS_ENV="development"
export RACK_ENV="development"

# Discourse 基础配置
export DISCOURSE_HOSTNAME="dev.orcaspace.woa.com"
export RAILS_DEVELOPMENT_HOSTS="dev.orcaspace.woa.com,9.135.99.230,127.0.0.1,localhost"
export DISCOURSE_DEVELOPER_EMAILS="admin@example.com"
export DISCOURSE_SERVE_STATIC_ASSETS="true"
export DISCOURSE_LOG_LEVEL="debug"
export DISCOURSE_SHOW_ERRORS="true"

# HTTPS/SSL 配置（Nginx 代理 HTTPS，Rails 需要知道）
export DISCOURSE_FORCE_HTTPS="true"
export RAILS_ASSUME_SSL="true"

# CORS 配置
export DISCOURSE_ENABLE_CORS="true"
export DISCOURSE_CORS_ORIGIN="https://dev.orcaspace.woa.com"

# 限流配置
export DISCOURSE_MAX_REQS_PER_IP_MODE="none"
export DISCOURSE_MAX_REQS_RATE_LIMIT_ON_PRIVATE="false"

# Session 和 Cookie
export DISCOURSE_DEBUG_SESSION="true"
export DISCOURSE_SAMESITE_NONE="true"
export DISCOURSE_COOKIE_DOMAIN=""

# 代理配置
export DISCOURSE_TRUSTED_PROXIES="10.0.0.0/8,172.16.0.0/12,192.168.0.0/16"

# 超时配置
export UNICORN_TIMEOUT="180"
export DISCOURSE_REQUEST_TIMEOUT="180"
export DISCOURSE_GIT_TIMEOUT="300"

# S3/COS 存储配置
export DISCOURSE_ENABLE_S3_UPLOADS="true"
export DISCOURSE_S3_REGION="ap-guangzhou"
export DISCOURSE_S3_BUCKET="orcaspace-1255940152"
export DISCOURSE_S3_UPLOAD_BUCKET="orcaspace-1255940152"
export DISCOURSE_S3_ENDPOINT="https://cos.ap-guangzhou.myqcloud.com"

# 太湖身份认证插件
export DISCOURSE_TAI_HU_AUTH_ENABLED="true"
export DISCOURSE_TAI_HU_AUTO_CREATE_USER="true"
export DISCOURSE_TAI_HU_AUTO_ACTIVATE_USER="true"
export DISCOURSE_TAI_HU_EMAIL_DOMAIN="tencent.com"

# Secret Key
export SECRET_KEY_BASE="production_secret_key_base_min_30_chars_long_replace_this"

# Redis 特殊配置
export DISCOURSE_REDIS_SKIP_CLIENT_COMMANDS="true"

# Ember CLI 配置
# 设置为 1 允许直接访问 Rails 绕过 Ember CLI 要求（仅用于 API 测试等场景）
# 如果需要完整的前端开发体验，请使用 ./dev_start.sh ember 启动完整开发环境
export ALLOW_EMBER_CLI_PROXY_BYPASS="${ALLOW_EMBER_CLI_PROXY_BYPASS:-0}"

# Ember CLI 需要代理到本地 Rails，而不是域名
export EMBER_CLI_PROXY_HOST="127.0.0.1"

# ========================================
# 函数定义
# ========================================

# 颜色输出
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# 检查进程是否运行
is_running() {
    if [ -f "$PID_FILE" ]; then
        pid=$(cat "$PID_FILE")
        if ps -p "$pid" > /dev/null 2>&1; then
            return 0
        fi
    fi
    return 1
}

# 停止服务
stop_server() {
    if is_running; then
        pid=$(cat "$PID_FILE")
        log_info "停止 Discourse 服务 (PID: $pid)..."
        kill -TERM "$pid" 2>/dev/null || true
        
        # 等待进程结束
        for i in {1..10}; do
            if ! ps -p "$pid" > /dev/null 2>&1; then
                break
            fi
            sleep 1
        done
        
        # 强制杀掉
        if ps -p "$pid" > /dev/null 2>&1; then
            log_warn "进程未响应，强制终止..."
            kill -9 "$pid" 2>/dev/null || true
        fi
        
        rm -f "$PID_FILE"
        log_info "服务已停止"
    else
        log_warn "服务未运行"
    fi
    
    # 清理可能残留的 Rails 进程
    pkill -f "puma.*$APP_ROOT" 2>/dev/null || true
    pkill -f "rails.*server.*$PORT" 2>/dev/null || true
}

# 启动服务
start_server() {
    if is_running; then
        log_warn "服务已在运行 (PID: $(cat $PID_FILE))"
        return 1
    fi
    
    cd "$APP_ROOT"
    
    # 创建必要目录
    mkdir -p tmp/pids tmp/sockets log
    
    log_info "启动 Discourse 开发服务..."
    log_info "目录: $APP_ROOT"
    log_info "端口: $PORT"
    log_info "环境: $RAILS_ENV"
    log_info "数据库: $DATABASE_URL"
    log_info "Redis: $DISCOURSE_REDIS_HOST:$DISCOURSE_REDIS_PORT"
    echo ""
    
    # 启动 Rails 服务器
    bundle exec rails server -b 0.0.0.0 -p $PORT -P "$PID_FILE"
}

# 后台启动
start_daemon() {
    if is_running; then
        log_warn "服务已在运行 (PID: $(cat $PID_FILE))"
        return 1
    fi
    
    cd "$APP_ROOT"
    mkdir -p tmp/pids tmp/sockets log
    
    log_info "后台启动 Discourse 开发服务..."
    nohup bundle exec rails server -b 0.0.0.0 -p $PORT -P "$PID_FILE" >> "$LOG_FILE" 2>&1 &
    
    sleep 2
    if is_running; then
        log_info "服务已启动 (PID: $(cat $PID_FILE))"
        log_info "日志: tail -f $LOG_FILE"
    else
        log_error "启动失败，请检查日志: $LOG_FILE"
    fi
}

# 重启服务
restart_server() {
    log_info "重启服务..."
    stop_server
    sleep 2
    start_server
}

# 启动完整开发环境（Rails + Ember CLI）- 前台
start_ember() {
    cd "$APP_ROOT"
    mkdir -p tmp/pids log
    
    log_info "启动 Discourse 完整开发环境（Rails + Ember CLI）..."
    log_info "目录: $APP_ROOT"
    log_info "Ember CLI 端口: 4200"
    log_info "Rails 后端端口: $PORT"
    log_info "环境: $RAILS_ENV"
    log_info "Redis: $DISCOURSE_REDIS_HOST:$DISCOURSE_REDIS_PORT"
    echo ""
    log_info "访问地址: http://$DISCOURSE_HOSTNAME:4200"
    echo ""
    
    # 使用 bin/ember-cli -u 同时启动 Unicorn 和 Ember CLI
    bin/ember-cli -u
}

# 启动完整开发环境（Rails + Ember CLI）- 后台
start_ember_daemon() {
    cd "$APP_ROOT"
    mkdir -p tmp/pids log
    
    # 检查是否已在运行
    if [ -f "$EMBER_PID_FILE" ]; then
        pid=$(cat "$EMBER_PID_FILE")
        if ps -p "$pid" > /dev/null 2>&1; then
            log_warn "服务已在运行 (PID: $pid)"
            log_info "日志: tail -f $EMBER_LOG_FILE"
            return 1
        fi
    fi
    
    log_info "后台启动 Discourse 完整开发环境..."
    log_info "Ember CLI 端口: 4200"
    log_info "Rails 后端端口: $PORT"
    log_info "日志文件: $EMBER_LOG_FILE"
    echo ""
    
    # 后台启动，日志写入文件
    nohup bin/ember-cli -u >> "$EMBER_LOG_FILE" 2>&1 &
    echo $! > "$EMBER_PID_FILE"
    
    sleep 3
    if [ -f "$EMBER_PID_FILE" ] && ps -p $(cat "$EMBER_PID_FILE") > /dev/null 2>&1; then
        log_info "服务已在后台启动 (PID: $(cat $EMBER_PID_FILE))"
        log_info "访问地址: http://$DISCOURSE_HOSTNAME:4200"
        log_info "查看日志: ./dev_start.sh logs"
        log_info "或: tail -f $EMBER_LOG_FILE"
    else
        log_error "启动失败，请检查日志: $EMBER_LOG_FILE"
        rm -f "$EMBER_PID_FILE"
        return 1
    fi
}

# 停止所有开发服务
stop_all() {
    log_info "停止所有开发服务..."
    
    # 停止 Ember CLI 主进程
    if [ -f "$EMBER_PID_FILE" ]; then
        pid=$(cat "$EMBER_PID_FILE")
        if ps -p "$pid" > /dev/null 2>&1; then
            log_info "停止 Ember CLI (PID: $pid)..."
            kill -TERM "$pid" 2>/dev/null || true
            sleep 2
            if ps -p "$pid" > /dev/null 2>&1; then
                kill -9 "$pid" 2>/dev/null || true
            fi
        fi
        rm -f "$EMBER_PID_FILE"
    fi
    
    stop_server
    
    # 停止 Ember CLI 相关进程
    pkill -f "ember.*server" 2>/dev/null || true
    pkill -f "pnpm.*ember" 2>/dev/null || true
    pkill -f "unicorn.*discourse" 2>/dev/null || true
    pkill -f "ember-tsc" 2>/dev/null || true
    
    log_info "所有服务已停止"
}

# 查看状态（更新版）
show_status() {
    echo ""
    # 检查 Ember CLI 进程
    if [ -f "$EMBER_PID_FILE" ]; then
        pid=$(cat "$EMBER_PID_FILE")
        if ps -p "$pid" > /dev/null 2>&1; then
            log_info "Ember CLI 运行中 (PID: $pid)"
            log_info "访问地址: http://$DISCOURSE_HOSTNAME:4200"
        else
            log_warn "Ember CLI PID 文件存在但进程未运行"
            rm -f "$EMBER_PID_FILE"
        fi
    else
        # 检查是否有相关进程在运行
        if pgrep -f "ember.*server" > /dev/null 2>&1; then
            log_info "Ember CLI 运行中（前台模式）"
            log_info "访问地址: http://$DISCOURSE_HOSTNAME:4200"
        else
            log_warn "Ember CLI 未运行"
        fi
    fi
    
    # 检查 Unicorn 进程
    if pgrep -f "unicorn.*master" > /dev/null 2>&1; then
        log_info "Unicorn 运行中"
    fi
    echo ""
}

# 查看日志
show_logs() {
    if [ -f "$EMBER_LOG_FILE" ]; then
        log_info "查看日志: $EMBER_LOG_FILE"
        tail -f "$EMBER_LOG_FILE"
    elif [ -f "$LOG_FILE" ]; then
        log_info "查看日志: $LOG_FILE"
        tail -f "$LOG_FILE"
    else
        log_warn "日志文件不存在"
        log_info "尝试查看: $EMBER_LOG_FILE 或 $LOG_FILE"
    fi
}

# ========================================
# 主逻辑
# ========================================

case "${1:-start}" in
    start)
        # 前台启动完整开发环境，支持热重载
        start_ember
        ;;
    daemon)
        # 后台启动完整开发环境
        start_ember_daemon
        ;;
    stop)
        stop_all
        ;;
    restart)
        stop_all
        sleep 2
        start_ember_daemon
        ;;
    status)
        show_status
        ;;
    logs)
        show_logs
        ;;
    rails)
        # 仅启动 Rails 后端（绕过 Ember CLI）
        export ALLOW_EMBER_CLI_PROXY_BYPASS="1"
        start_server
        ;;
    *)
        echo "用法: $0 {start|daemon|stop|restart|status|logs|rails}"
        echo ""
        echo "  start   - 前台启动完整开发环境（Rails + Ember CLI，支持热重载）"
        echo "            访问: http://$DISCOURSE_HOSTNAME:4200"
        echo "  daemon  - 后台启动完整开发环境"
        echo "  stop    - 停止服务"
        echo "  restart - 重启服务（后台）"
        echo "  status  - 查看状态"
        echo "  logs    - 查看日志"
        echo ""
        echo "  rails   - 仅启动 Rails 后端（端口 3000，用于 API 测试）"
        echo ""
        echo "日志文件: $EMBER_LOG_FILE"
        exit 1
        ;;
esac
