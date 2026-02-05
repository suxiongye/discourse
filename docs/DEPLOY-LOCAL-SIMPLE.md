# Discourse 本地 Docker 最简部署

> 用于本地开发测试，从源码构建镜像并运行，直接通过 IP:3000 访问

## 🎯 目标

- ✅ 本地构建 Docker 镜像
- ✅ 使用本地 PostgreSQL 和 Redis
- ✅ 不需要 Nginx，直接访问 http://localhost:3000
- ✅ 最简化配置，快速启动

---

## 前置条件

```bash
# 检查环境
docker --version        # Docker 已安装
psql --version          # PostgreSQL 客户端
redis-cli --version     # Redis 客户端 (可选)

# 确认服务运行
psql -U postgres -c "SELECT version();"  # PostgreSQL 运行中
redis-cli ping                            # Redis 运行中 (应返回 PONG)
```

---

## 快速开始 (5分钟)

### 步骤 1: 准备数据库 (1分钟)

```bash
# 创建数据库和用户
psql -U postgres << 'EOF'
-- 删除旧数据库 (如果存在)
DROP DATABASE IF EXISTS discourse_development;
DROP USER IF EXISTS discourse;

-- 创建用户
CREATE USER discourse WITH PASSWORD 'discourse123';

-- 创建数据库
CREATE DATABASE discourse_development 
  OWNER discourse 
  ENCODING 'UTF8' 
  LC_COLLATE='en_US.UTF-8' 
  LC_CTYPE='en_US.UTF-8';

-- 安装扩展
\c discourse_development postgres
CREATE EXTENSION IF NOT EXISTS hstore;
CREATE EXTENSION IF NOT EXISTS pg_trgm;

-- 授权
GRANT ALL PRIVILEGES ON DATABASE discourse_development TO discourse;
GRANT ALL ON ALL TABLES IN SCHEMA public TO discourse;
GRANT ALL ON ALL SEQUENCES IN SCHEMA public TO discourse;

-- 验证
\l discourse_development
\q
EOF

echo "✅ 数据库创建成功"
```

### 步骤 2: 创建环境变量文件 (1分钟)

```bash
# 在项目根目录创建 .env.local
cd /Users/suxiongye/Code/orca/discourse

cat > .env.local << 'EOF'
# Rails 环境
RAILS_ENV=development
RACK_ENV=development

# 数据库配置 (本地 PostgreSQL)
DISCOURSE_DB_HOST=host.docker.internal  # Docker 访问宿主机
DISCOURSE_DB_PORT=5432
DISCOURSE_DB_NAME=discourse_development
DISCOURSE_DB_USERNAME=discourse
DISCOURSE_DB_PASSWORD=discourse123

# Redis 配置 (本地 Redis)
DISCOURSE_REDIS_HOST=host.docker.internal
DISCOURSE_REDIS_PORT=6379

# 域名配置 (本地测试)
DISCOURSE_HOSTNAME=localhost
DISCOURSE_DEV_HOSTS=localhost

# 开发者邮箱 (用于创建管理员)
DISCOURSE_DEVELOPER_EMAILS=admin@example.com

# Rails Secret (开发环境可用固定值)
SECRET_KEY_BASE=dev_secret_key_base_for_local_testing_only

# 跳过邮件配置 (开发环境不需要真实邮件)
DISCOURSE_SMTP_ADDRESS=
DISCOURSE_SMTP_PORT=
EOF

echo "✅ 环境变量配置完成"
```

### 步骤 3: 构建 Docker 镜像 (5-10分钟)

```bash
# 构建镜像
docker build -t discourse:local .

# 等待构建完成...
# 第一次构建需要 5-10 分钟，后续会利用缓存加速

echo "✅ 镜像构建完成"

# 验证镜像
docker images | grep discourse
```

### 步骤 4: 运行数据库迁移 (1分钟)

```bash
# 运行迁移
docker run --rm \
  --env-file .env.local \
  --add-host=host.docker.internal:host-gateway \
  discourse:local \
  bash -c "bundle exec rake db:migrate"

echo "✅ 数据库迁移完成"
```

### 步骤 5: 启动 Discourse (1分钟)

```bash
# 启动 Web 服务
docker run -d \
  --name discourse_web \
  --env-file .env.local \
  --add-host=host.docker.internal:host-gateway \
  -p 3000:3000 \
  discourse:local

echo "✅ Discourse 启动成功"

# 查看日志
docker logs -f discourse_web

# 等待看到类似以下输出:
# * Listening on http://0.0.0.0:3000
# Use Ctrl-C to stop
```

### 步骤 6: 启动 Sidekiq (可选)

```bash
# 启动后台任务处理
docker run -d \
  --name discourse_sidekiq \
  --env-file .env.local \
  --add-host=host.docker.internal:host-gateway \
  discourse:local \
  bundle exec sidekiq

echo "✅ Sidekiq 启动成功"
```

### 步骤 7: 创建管理员 (1分钟)

```bash
# 进入容器
docker exec -it discourse_web bash

# 创建管理员
bundle exec rake admin:create

# 按提示输入:
# Email: admin@example.com
# Password: password123
# Repeat password: password123
# Grant admin? Y

# 退出
exit

echo "✅ 管理员创建完成"
```

### 步骤 8: 访问网站

```bash
# 浏览器打开
open http://localhost:3000

# 或使用 curl 测试
curl http://localhost:3000/srv/status
# 应该返回: {"success":"OK"}
```

---

## 一键启动脚本

创建快捷脚本 `start-local.sh`:

```bash
#!/bin/bash
set -e

echo "=== Discourse 本地启动脚本 ==="

# 检查容器是否已运行
if docker ps | grep -q discourse_web; then
    echo "✅ Discourse 已在运行"
    echo "访问: http://localhost:3000"
    exit 0
fi

# 检查容器是否存在但已停止
if docker ps -a | grep -q discourse_web; then
    echo "🔄 启动已存在的容器..."
    docker start discourse_web
    docker start discourse_sidekiq 2>/dev/null || true
else
    echo "🚀 首次启动..."
    
    # 启动 Web
    docker run -d \
      --name discourse_web \
      --env-file .env.local \
      --add-host=host.docker.internal:host-gateway \
      -p 3000:3000 \
      discourse:local
    
    # 启动 Sidekiq
    docker run -d \
      --name discourse_sidekiq \
      --env-file .env.local \
      --add-host=host.docker.internal:host-gateway \
      discourse:local \
      bundle exec sidekiq
fi

echo ""
echo "✅ 启动完成!"
echo "📍 访问地址: http://localhost:3000"
echo "📊 查看日志: docker logs -f discourse_web"
echo "🛑 停止服务: ./stop-local.sh"
```

创建停止脚本 `stop-local.sh`:

```bash
#!/bin/bash
echo "=== 停止 Discourse ==="

docker stop discourse_web discourse_sidekiq 2>/dev/null || true

echo "✅ 已停止"
echo "🗑️  删除容器: docker rm discourse_web discourse_sidekiq"
```

创建重启脚本 `restart-local.sh`:

```bash
#!/bin/bash
echo "=== 重启 Discourse ==="

# 停止
docker stop discourse_web discourse_sidekiq 2>/dev/null || true
docker rm discourse_web discourse_sidekiq 2>/dev/null || true

# 启动
./start-local.sh
```

**设置权限:**

```bash
chmod +x start-local.sh stop-local.sh restart-local.sh
```

---

## 常用命令

### 日常操作

```bash
# 启动
./start-local.sh

# 停止
./stop-local.sh

# 重启
./restart-local.sh

# 查看日志
docker logs -f discourse_web          # Web 日志
docker logs -f discourse_sidekiq      # Sidekiq 日志

# 进入容器
docker exec -it discourse_web bash

# 查看容器状态
docker ps | grep discourse
```

### 数据库操作

```bash
# 进入 Rails Console
docker exec -it discourse_web bundle exec rails console

# 常用命令:
# User.count                          # 用户数
# User.first                          # 第一个用户
# SiteSetting.title = "My Forum"      # 修改标题
# exit

# 进入数据库
docker exec -it discourse_web \
  psql -h host.docker.internal \
       -U discourse \
       -d discourse_development

# SQL 查询:
# \dt                                 # 查看表
# SELECT COUNT(*) FROM users;         # 用户数
# \q
```

### 代码修改后重启

```bash
# 修改代码后

# 方法 1: 重新构建镜像 (如果修改了 Ruby 代码或 Gemfile)
docker build -t discourse:local .
./restart-local.sh

# 方法 2: 热重载 (如果只修改了 JS/CSS)
# 不需要重启，刷新浏览器即可
```

### 清理和重置

```bash
# 停止并删除容器
docker stop discourse_web discourse_sidekiq
docker rm discourse_web discourse_sidekiq

# 删除镜像
docker rmi discourse:local

# 重置数据库
psql -U postgres << 'EOF'
DROP DATABASE IF EXISTS discourse_development;
CREATE DATABASE discourse_development OWNER discourse;
\c discourse_development postgres
CREATE EXTENSION IF NOT EXISTS hstore;
CREATE EXTENSION IF NOT EXISTS pg_trgm;
EOF

# 重新开始
docker build -t discourse:local .
docker run --rm --env-file .env.local --add-host=host.docker.internal:host-gateway \
  discourse:local bundle exec rake db:migrate
./start-local.sh
```

---

## 故障排查

### 问题 1: 无法连接数据库

**症状:**
```
could not connect to server: Connection refused
```

**解决:**
```bash
# 1. 检查 PostgreSQL 是否运行
psql -U postgres -c "SELECT 1;"

# 2. 检查 PostgreSQL 监听地址
# 编辑 postgresql.conf
# listen_addresses = '*'  # 或 'localhost'

# 3. 检查 pg_hba.conf
# 添加这行允许 Docker 网络:
# host    all             all             172.17.0.0/16           md5

# 4. 重启 PostgreSQL
# macOS: brew services restart postgresql
# Linux: sudo systemctl restart postgresql

# 5. 测试连接
psql -h localhost -U discourse -d discourse_development
```

### 问题 2: 无法连接 Redis

**症状:**
```
Error connecting to Redis
```

**解决:**
```bash
# 1. 检查 Redis 是否运行
redis-cli ping
# 应该返回: PONG

# 2. 启动 Redis
# macOS: brew services start redis
# Linux: sudo systemctl start redis

# 3. 检查 Redis 配置
# 编辑 redis.conf
# bind 127.0.0.1 ::1  # 或 0.0.0.0

# 4. 测试连接
redis-cli -h localhost ping
```

### 问题 3: 端口被占用

**症状:**
```
Bind for 0.0.0.0:3000 failed: port is already allocated
```

**解决:**
```bash
# 1. 查看谁占用了端口
lsof -i :3000

# 2. 杀掉占用进程
kill -9 <PID>

# 3. 或使用其他端口
docker run -d \
  --name discourse_web \
  --env-file .env.local \
  --add-host=host.docker.internal:host-gateway \
  -p 4000:3000 \  # 映射到 4000 端口
  discourse:local

# 访问: http://localhost:4000
```

### 问题 4: 镜像构建失败

**症状:**
```
ERROR: failed to solve: process "/bin/sh -c bundle install" did not complete successfully
```

**解决:**
```bash
# 1. 清理 Docker 缓存
docker builder prune -a

# 2. 使用国内镜像源
# 在 Dockerfile 中添加:
# RUN sed -i 's/deb.debian.org/mirrors.tencent.com/g' /etc/apt/sources.list

# 3. 增加构建超时
docker build --build-arg BUILDKIT_STEP_TIMEOUT=1800 -t discourse:local .

# 4. 检查网络连接
ping rubygems.org
ping registry.npmjs.org
```

### 问题 5: 静态资源编译失败

**症状:**
```
Rake task assets:precompile failed
```

**解决:**
```bash
# 开发环境可以跳过预编译
# 修改 Dockerfile，注释掉预编译步骤:
# RUN SECRET_KEY_BASE=placeholder DISCOURSE_HOSTNAME=placeholder \
#     bundle exec rake assets:precompile

# 或在容器内手动编译
docker exec -it discourse_web bash
cd /var/www/discourse
RAILS_ENV=development bundle exec rake assets:precompile
exit
```

---

## 开发技巧

### 1. 挂载代码实现热重载

如果需要频繁修改代码，可以挂载本地目录:

```bash
docker run -d \
  --name discourse_web \
  --env-file .env.local \
  --add-host=host.docker.internal:host-gateway \
  -p 3000:3000 \
  -v $(pwd)/app:/var/www/discourse/app \
  -v $(pwd)/lib:/var/www/discourse/lib \
  -v $(pwd)/plugins:/var/www/discourse/plugins \
  discourse:local
```

### 2. 调试模式

```bash
# 启用详细日志
docker run -d \
  --name discourse_web \
  --env-file .env.local \
  --add-host=host.docker.internal:host-gateway \
  -p 3000:3000 \
  -e DISCOURSE_LOG_LEVEL=debug \
  discourse:local

# 查看详细日志
docker logs -f discourse_web
```

### 3. 使用 pry 调试

```bash
# 在代码中添加断点
# require 'pry'; binding.pry

# 以交互模式启动
docker run -it \
  --name discourse_web \
  --env-file .env.local \
  --add-host=host.docker.internal:host-gateway \
  -p 3000:3000 \
  discourse:local \
  bash -c "bundle exec rails server -b 0.0.0.0"

# 当代码执行到断点时，会进入 pry 交互界面
```

### 4. 查看邮件 (MailCatcher)

```bash
# 启动 MailCatcher (可选)
docker run -d \
  --name mailcatcher \
  -p 1080:1080 \
  -p 1025:1025 \
  schickling/mailcatcher

# 修改 .env.local
# DISCOURSE_SMTP_ADDRESS=host.docker.internal
# DISCOURSE_SMTP_PORT=1025

# 访问 Web 界面查看邮件
open http://localhost:1080
```

---

## 生产环境部署准备

当本地测试完成，准备部署到 TKE 时:

```bash
# 1. 构建生产镜像
docker build \
  --build-arg RAILS_ENV=production \
  -t ccr.ccs.tencentyun.com/your-namespace/discourse:v1.0.0 \
  .

# 2. 推送到 TCR
docker login ccr.ccs.tencentyun.com
docker push ccr.ccs.tencentyun.com/your-namespace/discourse:v1.0.0

# 3. 使用 TKE CLB 部署
# 参考 docs/DEPLOY-K8S.md
```

---

## 完整的重新开始流程

如果需要完全重新开始:

```bash
#!/bin/bash
# reset-all.sh

echo "=== 完全重置 Discourse ==="

# 1. 停止并删除容器
docker stop discourse_web discourse_sidekiq 2>/dev/null || true
docker rm discourse_web discourse_sidekiq 2>/dev/null || true

# 2. 删除镜像
docker rmi discourse:local 2>/dev/null || true

# 3. 重置数据库
psql -U postgres << 'EOF'
DROP DATABASE IF EXISTS discourse_development;
DROP USER IF EXISTS discourse;
CREATE USER discourse WITH PASSWORD 'discourse123';
CREATE DATABASE discourse_development OWNER discourse ENCODING 'UTF8';
\c discourse_development postgres
CREATE EXTENSION IF NOT EXISTS hstore;
CREATE EXTENSION IF NOT EXISTS pg_trgm;
GRANT ALL PRIVILEGES ON DATABASE discourse_development TO discourse;
EOF

# 4. 清空 Redis
redis-cli FLUSHALL

# 5. 重新构建
docker build -t discourse:local .

# 6. 运行迁移
docker run --rm \
  --env-file .env.local \
  --add-host=host.docker.internal:host-gateway \
  discourse:local \
  bash -c "bundle exec rake db:migrate"

# 7. 启动服务
./start-local.sh

# 8. 创建管理员
docker exec -it discourse_web bash -c "bundle exec rake admin:create"

echo "✅ 重置完成!"
```

---

## 总结

### ✅ 最简化部署只需 4 步:

1. **准备数据库**: `psql -U postgres -f setup-db.sql`
2. **构建镜像**: `docker build -t discourse:local .`
3. **运行迁移**: `docker run --rm --env-file .env.local ... rake db:migrate`
4. **启动服务**: `./start-local.sh`

### 📝 常用命令速查:

```bash
./start-local.sh                     # 启动
./stop-local.sh                      # 停止
docker logs -f discourse_web         # 查看日志
docker exec -it discourse_web bash   # 进入容器
open http://localhost:3000           # 访问网站
```

### 🔧 下一步:

- 本地开发完成后，参考 `docs/DEPLOY-K8S.md` 部署到 TKE
- 使用 TKE 的 CLB 做负载均衡，不需要 Nginx
- 环境变量配置保持一致，只需修改数据库/Redis 地址

---

## 快速参考

### 环境变量说明

| 变量 | 说明 | 本地值 |
|------|------|--------|
| `DISCOURSE_DB_HOST` | 数据库地址 | `host.docker.internal` |
| `DISCOURSE_REDIS_HOST` | Redis 地址 | `host.docker.internal` |
| `DISCOURSE_HOSTNAME` | 访问域名 | `localhost` |
| `RAILS_ENV` | 运行环境 | `development` |

### Docker 网络说明

```
┌─────────────────┐
│  Docker 容器     │
│  discourse:3000 │
└────────┬────────┘
         │
         │ host.docker.internal
         │
┌────────▼────────┐
│  宿主机 macOS    │
│  PostgreSQL:5432│
│  Redis:6379     │
└─────────────────┘
```

使用 `host.docker.internal` 让 Docker 容器访问宿主机的服务。

---

需要帮助？查看日志或提 Issue！
