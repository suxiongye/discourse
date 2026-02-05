# Discourse Docker 部署指南

> 本文档描述如何**不使用 Kubernetes**，直接在服务器上使用 Docker 或 Docker Compose 部署定制化的 Discourse

## 目录

- [部署架构](#部署架构)
- [适用场景](#适用场景)
- [前置条件](#前置条件)
- [部署方式对比](#部署方式对比)
- [方案一: Docker Compose (推荐)](#方案一-docker-compose-推荐)
- [方案二: 纯 Docker 命令](#方案二-纯-docker-命令)
- [方案三: Docker Swarm](#方案三-docker-swarm)
- [生产环境配置](#生产环境配置)
- [运维管理](#运维管理)
- [故障排查](#故障排查)

---

## 部署架构

### 单服务器架构

```
┌─────────────────────────────────────────────────────────────┐
│                      腾讯云轻量服务器                          │
│                      或 CVM 云服务器                           │
│                                                               │
│  ┌────────────────────────────────────────────────────────┐ │
│  │                    Docker Host                         │ │
│  │                                                        │ │
│  │  ┌──────────────┐  ┌──────────────┐  ┌────────────┐  │ │
│  │  │   Nginx      │  │  Discourse   │  │  Sidekiq   │  │ │
│  │  │  (反向代理)   │→ │   (Rails)    │  │  (后台任务) │  │ │
│  │  │              │  │              │  │            │  │ │
│  │  │  :80/:443    │  │   :3000      │  │            │  │ │
│  │  └──────┬───────┘  └──────┬───────┘  └─────┬──────┘  │ │
│  │         │                 │                 │         │ │
│  │         └─────────────────┴─────────────────┘         │ │
│  │                           │                           │ │
│  │                  ┌────────▼────────┐                  │ │
│  │                  │   Docker Volume │                  │ │
│  │                  │   /var/uploads  │                  │ │
│  │                  └─────────────────┘                  │ │
│  └────────────────────────────────────────────────────────┘ │
└─────────────────────────┬───────────────┬───────────────────┘
                          │               │
              ┌───────────┘               └──────────────┐
              │                                          │
      ┌───────▼────────┐                        ┌────────▼────────┐
      │  TencentDB     │                        │  TencentDB      │
      │  PostgreSQL    │                        │  Redis          │
      │  (云数据库)     │                        │  (云缓存)        │
      └────────────────┘                        └─────────────────┘
                                                         │
                                                ┌────────▼────────┐
                                                │  COS 对象存储    │
                                                │  (图片/附件)     │
                                                └─────────────────┘
```

### 多服务器架构 (高可用)

```
                      ┌──────────────┐
                      │  CLB 负载均衡 │
                      └───────┬──────┘
                              │
                ┌─────────────┼─────────────┐
                │             │             │
        ┌───────▼──────┐ ┌───▼──────┐ ┌───▼──────┐
        │   服务器 1    │ │ 服务器 2  │ │ 服务器 3  │
        │  Nginx +     │ │ Nginx +  │ │ Nginx +  │
        │  Discourse   │ │Discourse │ │Discourse │
        └───────┬──────┘ └───┬──────┘ └───┬──────┘
                │            │            │
                └────────────┼────────────┘
                             │
                   ┌─────────┴─────────┐
                   │                   │
           ┌───────▼────────┐  ┌───────▼────────┐
           │  PostgreSQL    │  │     Redis      │
           │  (主从复制)     │  │  (哨兵模式)     │
           └────────────────┘  └────────────────┘
```

---

## 适用场景

### ✅ 推荐使用 Docker 部署的场景

1. **小型社区** (< 500 用户)
   - 单服务器即可满足
   - 运维成本低

2. **快速原型验证**
   - 快速部署测试
   - 开发环境

3. **资源有限**
   - 不需要 K8s 的复杂度
   - 降低学习成本

4. **传统运维团队**
   - 熟悉 Docker 但不熟悉 K8s
   - 使用 Ansible/脚本自动化

### ❌ 不推荐的场景

1. **大型社区** (> 1000 用户)
   - 需要水平扩展
   - 建议使用 K8s

2. **需要自动扩容**
   - Docker Compose 不支持 HPA
   - 需要手动扩容

3. **多地域部署**
   - K8s 有更好的多集群支持

---

## 前置条件

### 服务器配置

| 用户规模 | 配置 | 推荐机型 | 费用 |
|---------|------|----------|------|
| < 100 人 | 2核4G | 腾讯云轻量 2C4G | ~40元/月 |
| 100-400 人 | 4核8G | 腾讯云 CVM SA2.MEDIUM4 | ~200元/月 |
| 400-1000 人 | 8核16G | 腾讯云 CVM SA2.LARGE8 | ~400元/月 |

### 云资源

1. **PostgreSQL** - TencentDB for PostgreSQL (2C4G)
2. **Redis** - TencentDB for Redis (2GB)
3. **COS** - 对象存储 (按量付费)
4. **域名** - 已备案域名
5. **SSL 证书** - Let's Encrypt 或腾讯云 SSL

### 软件要求

```bash
# 1. Docker
docker --version  # >= 20.10

# 2. Docker Compose
docker compose version  # >= 2.0

# 3. Git
git --version
```

---

## 部署方式对比

| 方式 | 优点 | 缺点 | 推荐度 |
|------|------|------|--------|
| **Docker Compose** | 简单易用，配置清晰 | 单机部署 | ⭐⭐⭐⭐⭐ |
| **纯 Docker 命令** | 灵活控制 | 命令复杂 | ⭐⭐⭐ |
| **Docker Swarm** | 支持集群 | 生态较弱 | ⭐⭐⭐ |
| **Portainer** | 可视化管理 | 额外依赖 | ⭐⭐⭐⭐ |

---

## 方案一: Docker Compose (推荐)

### 步骤 1: 准备云资源 (15分钟)

#### 1.1 创建服务器

```bash
# 腾讯云控制台 -> 轻量应用服务器 -> 新建
# - 地域: 选择离用户近的
# - 镜像: Ubuntu 22.04
# - 套餐: 4核8G (推荐)
# - 系统盘: 80GB SSD

# 登录服务器
ssh ubuntu@your-server-ip
```

#### 1.2 初始化服务器

```bash
# 更新系统
sudo apt-get update
sudo apt-get upgrade -y

# 安装 Docker
curl -fsSL https://get.docker.com | bash -s docker --mirror Aliyun

# 启动 Docker
sudo systemctl start docker
sudo systemctl enable docker

# 添加当前用户到 docker 组 (避免每次用 sudo)
sudo usermod -aG docker $USER

# 重新登录使权限生效
exit
ssh ubuntu@your-server-ip

# 验证
docker --version
docker ps

# 安装 Docker Compose
sudo apt-get install docker-compose-plugin -y
docker compose version
```

#### 1.3 配置防火墙

```bash
# 允许 HTTP/HTTPS
sudo ufw allow 80/tcp
sudo ufw allow 443/tcp
sudo ufw allow 22/tcp  # SSH
sudo ufw enable

# 如果使用腾讯云安全组，在控制台配置:
# - 入站规则: 允许 80, 443, 22
```

### 步骤 2: 创建项目目录 (2分钟)

```bash
# 创建目录结构
mkdir -p ~/discourse/{config,volumes,backups}
cd ~/discourse

# 创建必要的子目录
mkdir -p volumes/uploads
mkdir -p volumes/backups
mkdir -p volumes/logs
mkdir -p config/nginx
```

### 步骤 3: 创建 Docker Compose 配置 (10分钟)

#### 3.1 主配置文件

```bash
cat > docker-compose.yml << 'EOF'
version: '3.8'

services:
  # ==================== Discourse Web ====================
  discourse:
    image: ccr.ccs.tencentyun.com/discourse/discourse:latest
    container_name: discourse_web
    restart: unless-stopped
    
    # 端口映射 (内部使用，不直接暴露)
    expose:
      - "3000"
    
    # 环境变量
    environment:
      # Rails 环境
      RAILS_ENV: production
      RACK_ENV: production
      
      # 域名配置
      DISCOURSE_HOSTNAME: ${DISCOURSE_HOSTNAME}
      DISCOURSE_FORCE_HTTPS: "true"
      
      # 数据库配置 (使用云数据库)
      DISCOURSE_DB_HOST: ${DB_HOST}
      DISCOURSE_DB_PORT: ${DB_PORT:-5432}
      DISCOURSE_DB_NAME: ${DB_NAME}
      DISCOURSE_DB_USERNAME: ${DB_USERNAME}
      DISCOURSE_DB_PASSWORD: ${DB_PASSWORD}
      DISCOURSE_DB_POOL: "25"
      
      # Redis 配置 (使用云 Redis)
      DISCOURSE_REDIS_HOST: ${REDIS_HOST}
      DISCOURSE_REDIS_PORT: ${REDIS_PORT:-6379}
      DISCOURSE_REDIS_PASSWORD: ${REDIS_PASSWORD}
      
      # SMTP 邮件配置
      DISCOURSE_SMTP_ADDRESS: ${SMTP_ADDRESS}
      DISCOURSE_SMTP_PORT: ${SMTP_PORT}
      DISCOURSE_SMTP_USER_NAME: ${SMTP_USERNAME}
      DISCOURSE_SMTP_PASSWORD: ${SMTP_PASSWORD}
      DISCOURSE_SMTP_DOMAIN: ${SMTP_DOMAIN}
      DISCOURSE_SMTP_ENABLE_START_TLS: "true"
      
      # 管理员
      DISCOURSE_DEVELOPER_EMAILS: ${ADMIN_EMAIL}
      
      # Rails Secret
      SECRET_KEY_BASE: ${SECRET_KEY_BASE}
      
      # COS 对象存储
      DISCOURSE_USE_S3: "true"
      DISCOURSE_S3_REGION: ${S3_REGION}
      DISCOURSE_S3_BUCKET: ${S3_BUCKET}
      DISCOURSE_S3_ENDPOINT: ${S3_ENDPOINT}
      DISCOURSE_S3_ACCESS_KEY_ID: ${S3_ACCESS_KEY}
      DISCOURSE_S3_SECRET_ACCESS_KEY: ${S3_SECRET_KEY}
      DISCOURSE_S3_CDN_URL: ${CDN_URL}
      
      # 性能优化
      RUBY_GC_HEAP_GROWTH_MAX_SLOTS: "40000"
      RUBY_GC_HEAP_INIT_SLOTS: "400000"
    
    # 数据卷
    volumes:
      - ./volumes/uploads:/var/www/discourse/public/uploads
      - ./volumes/backups:/var/www/discourse/public/backups
      - ./volumes/logs:/var/www/discourse/log
    
    # 健康检查
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost:3000/srv/status"]
      interval: 30s
      timeout: 10s
      retries: 3
      start_period: 60s
    
    # 资源限制
    deploy:
      resources:
        limits:
          cpus: '2'
          memory: 4G
        reservations:
          cpus: '1'
          memory: 2G
    
    # 网络
    networks:
      - discourse_network
    
    # 依赖
    depends_on:
      migration:
        condition: service_completed_successfully
  
  # ==================== Sidekiq 后台任务 ====================
  sidekiq:
    image: ccr.ccs.tencentyun.com/discourse/discourse:latest
    container_name: discourse_sidekiq
    restart: unless-stopped
    
    # 启动命令
    command: bundle exec sidekiq
    
    # 环境变量 (与 discourse 相同)
    environment:
      RAILS_ENV: production
      DISCOURSE_DB_HOST: ${DB_HOST}
      DISCOURSE_DB_NAME: ${DB_NAME}
      DISCOURSE_DB_USERNAME: ${DB_USERNAME}
      DISCOURSE_DB_PASSWORD: ${DB_PASSWORD}
      DISCOURSE_REDIS_HOST: ${REDIS_HOST}
      DISCOURSE_REDIS_PASSWORD: ${REDIS_PASSWORD}
      SECRET_KEY_BASE: ${SECRET_KEY_BASE}
      DISCOURSE_HOSTNAME: ${DISCOURSE_HOSTNAME}
    
    # 数据卷
    volumes:
      - ./volumes/uploads:/var/www/discourse/public/uploads
      - ./volumes/backups:/var/www/discourse/public/backups
      - ./volumes/logs:/var/www/discourse/log
    
    # 资源限制
    deploy:
      resources:
        limits:
          cpus: '1'
          memory: 2G
        reservations:
          cpus: '0.5'
          memory: 1G
    
    networks:
      - discourse_network
    
    depends_on:
      discourse:
        condition: service_healthy
  
  # ==================== 数据库迁移 (一次性任务) ====================
  migration:
    image: ccr.ccs.tencentyun.com/discourse/discourse:latest
    container_name: discourse_migration
    
    command: ["/bin/bash", "/var/www/discourse/docker/migrate.sh"]
    
    environment:
      RAILS_ENV: production
      DISCOURSE_DB_HOST: ${DB_HOST}
      DISCOURSE_DB_NAME: ${DB_NAME}
      DISCOURSE_DB_USERNAME: ${DB_USERNAME}
      DISCOURSE_DB_PASSWORD: ${DB_PASSWORD}
      SECRET_KEY_BASE: ${SECRET_KEY_BASE}
      DISCOURSE_HOSTNAME: ${DISCOURSE_HOSTNAME}
    
    networks:
      - discourse_network
  
  # ==================== Nginx 反向代理 ====================
  nginx:
    image: nginx:alpine
    container_name: discourse_nginx
    restart: unless-stopped
    
    # 端口映射
    ports:
      - "80:80"
      - "443:443"
    
    # 配置文件
    volumes:
      - ./config/nginx/nginx.conf:/etc/nginx/nginx.conf:ro
      - ./config/nginx/ssl:/etc/nginx/ssl:ro
      - ./volumes/uploads:/var/www/discourse/public/uploads:ro
    
    networks:
      - discourse_network
    
    depends_on:
      discourse:
        condition: service_healthy

# ==================== 网络 ====================
networks:
  discourse_network:
    driver: bridge

# ==================== 数据卷 ====================
volumes:
  uploads_data:
  backups_data:
  logs_data:
EOF
```

#### 3.2 环境变量配置

```bash
cat > .env << 'EOF'
# ==================== 基本配置 ====================
DISCOURSE_HOSTNAME=forum.yourcompany.com

# ==================== 数据库配置 ====================
# 使用腾讯云 TencentDB PostgreSQL
DB_HOST=postgres-xxx.tencentcdb.com
DB_PORT=5432
DB_NAME=discourse_production
DB_USERNAME=discourse
DB_PASSWORD=your-strong-db-password

# ==================== Redis 配置 ====================
# 使用腾讯云 Redis
REDIS_HOST=redis-xxx.tencentredis.com
REDIS_PORT=6379
REDIS_PASSWORD=your-redis-password

# ==================== SMTP 邮件配置 ====================
SMTP_ADDRESS=smtp.exmail.qq.com
SMTP_PORT=465
SMTP_USERNAME=noreply@yourcompany.com
SMTP_PASSWORD=your-smtp-password
SMTP_DOMAIN=yourcompany.com

# ==================== 管理员配置 ====================
ADMIN_EMAIL=admin@yourcompany.com

# ==================== Rails Secret ====================
# 生成方法: docker run --rm ccr.ccs.tencentyun.com/discourse/discourse:latest bundle exec rake secret
SECRET_KEY_BASE=your-very-long-secret-key-here

# ==================== COS 对象存储 ====================
S3_REGION=ap-guangzhou
S3_BUCKET=discourse-uploads-1234567890
S3_ENDPOINT=https://cos.ap-guangzhou.myqcloud.com
S3_ACCESS_KEY=AKIDxxxxxx
S3_SECRET_KEY=xxxxxxxxxx
CDN_URL=https://cdn.yourcompany.com
EOF

# 设置权限 (保护敏感信息)
chmod 600 .env
```

#### 3.3 Nginx 配置

```bash
cat > config/nginx/nginx.conf << 'EOF'
user nginx;
worker_processes auto;
error_log /var/log/nginx/error.log warn;
pid /var/run/nginx.pid;

events {
    worker_connections 1024;
    use epoll;
}

http {
    include /etc/nginx/mime.types;
    default_type application/octet-stream;

    log_format main '$remote_addr - $remote_user [$time_local] "$request" '
                    '$status $body_bytes_sent "$http_referer" '
                    '"$http_user_agent" "$http_x_forwarded_for"';

    access_log /var/log/nginx/access.log main;

    sendfile on;
    tcp_nopush on;
    tcp_nodelay on;
    keepalive_timeout 65;
    types_hash_max_size 2048;
    client_max_body_size 100m;

    # Gzip 压缩
    gzip on;
    gzip_vary on;
    gzip_proxied any;
    gzip_comp_level 6;
    gzip_types text/plain text/css text/xml text/javascript 
               application/json application/javascript application/xml+rss 
               application/rss+xml font/truetype font/opentype 
               application/vnd.ms-fontobject image/svg+xml;

    # Upstream
    upstream discourse {
        server discourse:3000;
        keepalive 32;
    }

    # HTTP -> HTTPS 重定向
    server {
        listen 80;
        server_name forum.yourcompany.com;
        return 301 https://$server_name$request_uri;
    }

    # HTTPS 配置
    server {
        listen 443 ssl http2;
        server_name forum.yourcompany.com;

        # SSL 证书 (Let's Encrypt 或手动上传)
        ssl_certificate /etc/nginx/ssl/fullchain.pem;
        ssl_certificate_key /etc/nginx/ssl/privkey.pem;
        
        # SSL 优化
        ssl_protocols TLSv1.2 TLSv1.3;
        ssl_ciphers HIGH:!aNULL:!MD5;
        ssl_prefer_server_ciphers on;
        ssl_session_cache shared:SSL:10m;
        ssl_session_timeout 10m;

        # 安全头
        add_header Strict-Transport-Security "max-age=31536000; includeSubDomains" always;
        add_header X-Content-Type-Options "nosniff" always;
        add_header X-Frame-Options "SAMEORIGIN" always;
        add_header X-XSS-Protection "1; mode=block" always;

        # 日志
        access_log /var/log/nginx/discourse_access.log main;
        error_log /var/log/nginx/discourse_error.log warn;

        # 静态文件 (上传的图片等)
        location /uploads/ {
            alias /var/www/discourse/public/uploads/;
            expires 1y;
            add_header Cache-Control "public, immutable";
        }

        # 代理到 Discourse
        location / {
            proxy_pass http://discourse;
            proxy_set_header Host $host;
            proxy_set_header X-Real-IP $remote_addr;
            proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
            proxy_set_header X-Forwarded-Proto $scheme;
            
            # WebSocket 支持
            proxy_http_version 1.1;
            proxy_set_header Upgrade $http_upgrade;
            proxy_set_header Connection "upgrade";
            
            # 超时设置
            proxy_connect_timeout 60s;
            proxy_send_timeout 600s;
            proxy_read_timeout 600s;
            
            # 缓冲设置
            proxy_buffering on;
            proxy_buffer_size 4k;
            proxy_buffers 8 4k;
        }

        # 健康检查
        location /srv/status {
            proxy_pass http://discourse;
            access_log off;
        }
    }
}
EOF
```

### 步骤 4: 配置 SSL 证书 (5分钟)

#### 方法 1: 使用 Let's Encrypt (推荐)

```bash
# 安装 Certbot
sudo apt-get install certbot -y

# 申请证书 (使用 standalone 模式，需要先停止 Nginx)
sudo certbot certonly --standalone \
  -d forum.yourcompany.com \
  --email admin@yourcompany.com \
  --agree-tos \
  --non-interactive

# 复制证书到项目目录
sudo mkdir -p config/nginx/ssl
sudo cp /etc/letsencrypt/live/forum.yourcompany.com/fullchain.pem config/nginx/ssl/
sudo cp /etc/letsencrypt/live/forum.yourcompany.com/privkey.pem config/nginx/ssl/
sudo chown -R $USER:$USER config/nginx/ssl

# 设置自动续期
sudo crontab -e
# 添加这行:
# 0 3 * * * certbot renew --quiet --deploy-hook "docker compose -f /home/ubuntu/discourse/docker-compose.yml restart nginx"
```

#### 方法 2: 手动上传证书

```bash
# 上传你的证书文件
mkdir -p config/nginx/ssl
# 将证书文件放到这个目录:
# - fullchain.pem (完整证书链)
# - privkey.pem (私钥)
```

### 步骤 5: 初始化数据库 (5分钟)

```bash
# 连接到 PostgreSQL 并创建数据库
# (在你的本地电脑或跳板机执行)
psql -h postgres-xxx.tencentcdb.com -U postgres << EOF
CREATE DATABASE discourse_production ENCODING 'UTF8';
CREATE USER discourse WITH PASSWORD 'your-strong-db-password';
GRANT ALL PRIVILEGES ON DATABASE discourse_production TO discourse;
\c discourse_production postgres
CREATE EXTENSION IF NOT EXISTS hstore;
CREATE EXTENSION IF NOT EXISTS pg_trgm;
GRANT ALL ON ALL TABLES IN SCHEMA public TO discourse;
GRANT ALL ON ALL SEQUENCES IN SCHEMA public TO discourse;
EOF
```

### 步骤 6: 构建镜像 (10分钟)

```bash
# 方法 1: 在服务器上构建 (推荐用于开发/测试)
# 上传代码到服务器
cd ~/discourse
git clone https://github.com/yourcompany/discourse.git source
cd source

# 构建镜像
docker build -t ccr.ccs.tencentyun.com/discourse/discourse:latest .

# 方法 2: 本地构建并推送 (推荐用于生产)
# (在本地开发机执行)
cd /path/to/discourse
docker build -t ccr.ccs.tencentyun.com/discourse/discourse:v1.0.0 .
docker login ccr.ccs.tencentyun.com
docker push ccr.ccs.tencentyun.com/discourse/discourse:v1.0.0

# 在服务器上拉取
docker pull ccr.ccs.tencentyun.com/discourse/discourse:v1.0.0
docker tag ccr.ccs.tencentyun.com/discourse/discourse:v1.0.0 \
           ccr.ccs.tencentyun.com/discourse/discourse:latest
```

### 步骤 7: 启动服务 (2分钟)

```bash
cd ~/discourse

# 1. 检查配置
docker compose config

# 2. 拉取镜像 (如果还没有)
docker compose pull

# 3. 启动服务
docker compose up -d

# 4. 查看日志
docker compose logs -f

# 等待启动完成 (约 1-2 分钟)
# 看到类似 "Listening on http://0.0.0.0:3000" 表示成功

# 5. 检查服务状态
docker compose ps

# 输出应该类似:
# NAME                   STATUS              PORTS
# discourse_web          healthy             3000/tcp
# discourse_sidekiq      running
# discourse_nginx        running             0.0.0.0:80->80/tcp, 0.0.0.0:443->443/tcp
```

### 步骤 8: 创建管理员 (2分钟)

```bash
# 进入 Web 容器
docker exec -it discourse_web bash

# 创建管理员
cd /var/www/discourse
bundle exec rake admin:create

# 按提示输入:
# Email: admin@yourcompany.com
# Password: (输入强密码)
# Repeat password: (再次输入)

# 退出容器
exit
```

### 步骤 9: 验证部署 (5分钟)

```bash
# 1. 检查健康检查
curl http://localhost:3000/srv/status
# 应该返回: {"success":"OK"}

# 2. 访问网站
# 浏览器打开: https://forum.yourcompany.com

# 3. 登录管理后台
# https://forum.yourcompany.com/admin

# 4. 测试邮件
# 后台 -> Settings -> Email -> Send Test Email

# 5. 测试图片上传
# 创建帖子，上传图片
```

---

## 方案二: 纯 Docker 命令

> 适合需要精细控制的场景

```bash
# 1. 创建网络
docker network create discourse_network

# 2. 运行数据库迁移
docker run --rm \
  --name discourse_migration \
  --network discourse_network \
  -e RAILS_ENV=production \
  -e DISCOURSE_DB_HOST=postgres-xxx.tencentcdb.com \
  -e DISCOURSE_DB_NAME=discourse_production \
  -e DISCOURSE_DB_USERNAME=discourse \
  -e DISCOURSE_DB_PASSWORD=your-password \
  -e SECRET_KEY_BASE=your-secret \
  ccr.ccs.tencentyun.com/discourse/discourse:latest \
  bash -c "bundle exec rake db:migrate"

# 3. 运行 Discourse Web
docker run -d \
  --name discourse_web \
  --network discourse_network \
  --restart unless-stopped \
  -p 3000:3000 \
  -e RAILS_ENV=production \
  -e DISCOURSE_HOSTNAME=forum.yourcompany.com \
  -e DISCOURSE_DB_HOST=postgres-xxx.tencentcdb.com \
  -e DISCOURSE_DB_NAME=discourse_production \
  -e DISCOURSE_DB_USERNAME=discourse \
  -e DISCOURSE_DB_PASSWORD=your-password \
  -e DISCOURSE_REDIS_HOST=redis-xxx.tencentredis.com \
  -e SECRET_KEY_BASE=your-secret \
  -v discourse_uploads:/var/www/discourse/public/uploads \
  -v discourse_logs:/var/www/discourse/log \
  ccr.ccs.tencentyun.com/discourse/discourse:latest

# 4. 运行 Sidekiq
docker run -d \
  --name discourse_sidekiq \
  --network discourse_network \
  --restart unless-stopped \
  -e RAILS_ENV=production \
  -e DISCOURSE_DB_HOST=postgres-xxx.tencentcdb.com \
  -e DISCOURSE_DB_NAME=discourse_production \
  -e DISCOURSE_DB_USERNAME=discourse \
  -e DISCOURSE_DB_PASSWORD=your-password \
  -e DISCOURSE_REDIS_HOST=redis-xxx.tencentredis.com \
  -e SECRET_KEY_BASE=your-secret \
  -v discourse_uploads:/var/www/discourse/public/uploads \
  ccr.ccs.tencentyun.com/discourse/discourse:latest \
  bundle exec sidekiq

# 5. 运行 Nginx
docker run -d \
  --name discourse_nginx \
  --network discourse_network \
  --restart unless-stopped \
  -p 80:80 \
  -p 443:443 \
  -v ~/discourse/config/nginx/nginx.conf:/etc/nginx/nginx.conf:ro \
  -v ~/discourse/config/nginx/ssl:/etc/nginx/ssl:ro \
  -v discourse_uploads:/var/www/discourse/public/uploads:ro \
  nginx:alpine
```

---

## 方案三: Docker Swarm

> 适合需要简单集群的场景

```bash
# 1. 初始化 Swarm
docker swarm init

# 2. 创建配置
docker config create discourse_nginx_conf config/nginx/nginx.conf

# 3. 创建 Secret
echo "your-db-password" | docker secret create db_password -
echo "your-secret-key-base" | docker secret create secret_key_base -

# 4. 部署 Stack
docker stack deploy -c docker-compose.yml discourse

# 5. 查看服务
docker service ls

# 6. 扩容
docker service scale discourse_discourse=3
docker service scale discourse_sidekiq=2
```

---

## 生产环境配置

### 1. 自动备份

```bash
# 创建备份脚本
cat > ~/discourse/backup.sh << 'EOF'
#!/bin/bash
set -e

BACKUP_DIR="/home/ubuntu/discourse/backups"
DATE=$(date +%Y%m%d_%H%M%S)

# 1. 备份数据库
echo "Backing up database..."
docker exec discourse_web \
  pg_dump -h postgres-xxx.tencentcdb.com \
          -U discourse \
          -d discourse_production \
          -Fc -f /tmp/db_backup_${DATE}.dump

docker cp discourse_web:/tmp/db_backup_${DATE}.dump ${BACKUP_DIR}/

# 2. 备份上传文件
echo "Backing up uploads..."
tar -czf ${BACKUP_DIR}/uploads_${DATE}.tar.gz -C ~/discourse/volumes uploads/

# 3. 清理旧备份 (保留 7 天)
find ${BACKUP_DIR} -name "*.dump" -mtime +7 -delete
find ${BACKUP_DIR} -name "*.tar.gz" -mtime +7 -delete

echo "Backup completed: ${DATE}"
EOF

chmod +x ~/discourse/backup.sh

# 配置定时任务
crontab -e
# 添加: 每天凌晨 3 点备份
# 0 3 * * * /home/ubuntu/discourse/backup.sh >> /home/ubuntu/discourse/backup.log 2>&1
```

### 2. 监控脚本

```bash
cat > ~/discourse/monitor.sh << 'EOF'
#!/bin/bash

# 检查容器状态
if ! docker compose -f ~/discourse/docker-compose.yml ps | grep -q "healthy\|running"; then
    echo "ERROR: Some containers are not running!"
    docker compose -f ~/discourse/docker-compose.yml ps
    
    # 发送告警邮件
    echo "Discourse containers status abnormal" | \
      mail -s "Discourse Alert" admin@yourcompany.com
fi

# 检查磁盘空间
DISK_USAGE=$(df -h / | tail -1 | awk '{print $5}' | sed 's/%//')
if [ $DISK_USAGE -gt 80 ]; then
    echo "WARNING: Disk usage is ${DISK_USAGE}%"
fi

# 检查内存
MEM_USAGE=$(free | grep Mem | awk '{printf("%.0f"), $3/$2 * 100}')
if [ $MEM_USAGE -gt 90 ]; then
    echo "WARNING: Memory usage is ${MEM_USAGE}%"
fi
EOF

chmod +x ~/discourse/monitor.sh

# 每 5 分钟检查一次
crontab -e
# */5 * * * * /home/ubuntu/discourse/monitor.sh >> /home/ubuntu/discourse/monitor.log 2>&1
```

### 3. 日志轮转

```bash
# 配置 Docker 日志轮转
cat > /etc/docker/daemon.json << 'EOF'
{
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "10m",
    "max-file": "3"
  }
}
EOF

sudo systemctl restart docker
```

### 4. 自动重启

```bash
# Docker Compose 配置中已包含 restart: unless-stopped
# 但可以额外配置 systemd 服务确保开机启动

sudo cat > /etc/systemd/system/discourse.service << 'EOF'
[Unit]
Description=Discourse Docker Compose Service
Requires=docker.service
After=docker.service

[Service]
Type=oneshot
RemainAfterExit=yes
WorkingDirectory=/home/ubuntu/discourse
ExecStart=/usr/bin/docker compose up -d
ExecStop=/usr/bin/docker compose down
TimeoutStartSec=0

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl enable discourse.service
sudo systemctl start discourse.service
```

---

## 运维管理

### 日常操作

```bash
# 查看日志
docker compose logs -f                    # 所有服务
docker compose logs -f discourse          # Web 服务
docker compose logs -f sidekiq            # Sidekiq

# 重启服务
docker compose restart                    # 所有服务
docker compose restart discourse          # 单个服务

# 停止服务
docker compose stop                       # 停止
docker compose start                      # 启动
docker compose down                       # 停止并删除容器

# 更新镜像
docker compose pull                       # 拉取最新镜像
docker compose up -d --force-recreate     # 重建容器

# 进入容器
docker exec -it discourse_web bash
docker exec -it discourse_sidekiq bash

# 查看资源使用
docker stats

# 清理无用资源
docker system prune -a
```

### 代码更新

```bash
# 1. 构建新镜像
cd /path/to/discourse
docker build -t ccr.ccs.tencentyun.com/discourse/discourse:v1.0.1 .
docker push ccr.ccs.tencentyun.com/discourse/discourse:v1.0.1

# 2. 在服务器上更新
cd ~/discourse
docker pull ccr.ccs.tencentyun.com/discourse/discourse:v1.0.1
docker tag ccr.ccs.tencentyun.com/discourse/discourse:v1.0.1 \
           ccr.ccs.tencentyun.com/discourse/discourse:latest

# 3. 滚动更新 (零停机)
docker compose up -d --no-deps --build discourse
docker compose up -d --no-deps --build sidekiq

# 4. 检查
docker compose ps
docker compose logs -f discourse
```

---

## 故障排查

### 问题 1: 容器无法启动

```bash
# 查看详细日志
docker compose logs discourse

# 常见原因:
# 1. 数据库连接失败
docker compose exec discourse bash
nc -zv postgres-xxx.tencentcdb.com 5432

# 2. Redis 连接失败
nc -zv redis-xxx.tencentredis.com 6379

# 3. 环境变量错误
docker compose config
```

### 问题 2: 网站无法访问

```bash
# 1. 检查 Nginx 状态
docker logs discourse_nginx

# 2. 测试 Discourse 端口
curl http://localhost:3000/srv/status

# 3. 检查防火墙
sudo ufw status
sudo netstat -tlnp | grep -E '80|443'

# 4. 检查 SSL 证书
openssl s_client -connect forum.yourcompany.com:443 -servername forum.yourcompany.com
```

### 问题 3: 性能问题

```bash
# 1. 查看资源使用
docker stats

# 2. 查看数据库连接
docker compose exec discourse bash
bundle exec rails dbconsole -p
SELECT COUNT(*) FROM pg_stat_activity;

# 3. 查看 Sidekiq 队列
# 浏览器访问: https://forum.yourcompany.com/sidekiq

# 4. 优化建议:
# - 增加服务器配置
# - 调整 DISCOURSE_DB_POOL
# - 启用 CDN
# - 优化数据库索引
```

---

## 成本对比

| 项目 | K8s 方案 | Docker 方案 | 节省 |
|------|----------|-------------|------|
| 服务器 | 2x 4C8G = ~800元 | 1x 4C8G = ~200元 | 600元/月 |
| 数据库 | 2C4G = ~300元 | 2C4G = ~300元 | 0 |
| Redis | 2GB = ~100元 | 2GB = ~100元 | 0 |
| COS | ~50元 | ~50元 | 0 |
| 负载均衡 | ~100元 | 0 (Nginx) | 100元/月 |
| **总计** | **~1350元/月** | **~650元/月** | **52%** |

---

## 总结

### Docker Compose 方案适合:
- ✅ 小型社区 (< 500 用户)
- ✅ 预算有限
- ✅ 运维团队熟悉 Docker
- ✅ 单服务器足够

### K8s 方案适合:
- ✅ 大型社区 (> 500 用户)
- ✅ 需要自动扩容
- ✅ 多地域部署
- ✅ 企业级可靠性

**推荐**: 先用 Docker Compose 快速上线，业务增长后迁移到 K8s。

---

## 附录

### 完整的一键部署脚本

```bash
#!/bin/bash
# deploy-discourse-docker.sh

set -e

echo "=== Discourse Docker 一键部署脚本 ==="

# 检查环境
command -v docker >/dev/null 2>&1 || { echo "请先安装 Docker"; exit 1; }
command -v docker compose >/dev/null 2>&1 || { echo "请先安装 Docker Compose"; exit 1; }

# 创建目录
mkdir -p ~/discourse/{config/nginx,volumes/{uploads,backups,logs}}
cd ~/discourse

# 下载配置文件
echo "下载配置文件..."
curl -o docker-compose.yml https://raw.githubusercontent.com/yourcompany/discourse/main/docker-compose.prod.yml
curl -o config/nginx/nginx.conf https://raw.githubusercontent.com/yourcompany/discourse/main/nginx.conf

# 配置环境变量
echo "请输入配置信息..."
read -p "域名: " HOSTNAME
read -p "数据库地址: " DB_HOST
read -sp "数据库密码: " DB_PASSWORD
echo

# 生成 .env
cat > .env << EOF
DISCOURSE_HOSTNAME=${HOSTNAME}
DB_HOST=${DB_HOST}
DB_PASSWORD=${DB_PASSWORD}
# ... 其他配置
EOF

# 配置 SSL
echo "配置 SSL 证书..."
sudo certbot certonly --standalone -d ${HOSTNAME}
sudo cp /etc/letsencrypt/live/${HOSTNAME}/fullchain.pem config/nginx/ssl/
sudo cp /etc/letsencrypt/live/${HOSTNAME}/privkey.pem config/nginx/ssl/

# 启动服务
echo "启动服务..."
docker compose up -d

echo "=== 部署完成! ==="
echo "访问: https://${HOSTNAME}"
```

保存为 `deploy-discourse-docker.sh`，一键执行！
