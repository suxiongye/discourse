# Discourse K8s 部署指南

> 本文档描述如何将定制化的 Discourse 部署到腾讯云 TKE (Kubernetes) 容器服务

## 目录

- [前置条件](#前置条件)
- [架构说明](#架构说明)
- [准备工作](#准备工作)
- [部署步骤](#部署步骤)
- [验证与测试](#验证与测试)
- [日常运维](#日常运维)
- [故障排查](#故障排查)

---

## 前置条件

### 必需的云资源

| 资源 | 规格 | 用途 | 费用估算 |
|------|------|------|----------|
| **TKE 集群** | 2节点 x 4核8G | 容器运行环境 | ~800元/月 |
| **TencentDB PostgreSQL** | 2核4G + 50GB | 主数据库 | ~300元/月 |
| **TencentDB Redis** | 2GB 标准版 | 缓存和队列 | ~100元/月 |
| **COS 对象存储** | 按量付费 | 用户上传文件 | ~50元/月 |
| **CFS 文件存储** | 100GB | Pod 共享存储 | ~40元/月 |
| **负载均衡 CLB** | 标准型 | Ingress 入口 | ~100元/月 |
| **总计** | - | - | **~1390元/月** |

### 本地工具

```bash
# 1. Docker
docker --version  # >= 20.10

# 2. kubectl
kubectl version --client  # >= 1.24

# 3. Git
git --version

# 4. 可选: helm
helm version  # >= 3.0
```

---

## 架构说明

### 系统架构图

```
┌─────────────────────────────────────────────────────────────┐
│                       腾讯云 TKE 集群                          │
│                                                               │
│  ┌──────────────┐     ┌──────────────┐                      │
│  │  Ingress     │────▶│   Service    │                      │
│  │  (CLB)       │     │  discourse   │                      │
│  └──────────────┘     └──────┬───────┘                      │
│         │                     │                               │
│         │            ┌────────┴────────┐                     │
│         │            │                 │                     │
│   ┌─────▼──────┐  ┌──▼──────────┐  ┌──▼──────────┐         │
│   │ Web Pod 1  │  │ Web Pod 2   │  │ Web Pod 3   │         │
│   │ (2C/4G)    │  │ (2C/4G)     │  │ (2C/4G)     │         │
│   └────────────┘  └─────────────┘  └─────────────┘         │
│                                                               │
│   ┌──────────────┐  ┌──────────────┐                        │
│   │Sidekiq Pod 1 │  │Sidekiq Pod 2 │                        │
│   │  (1C/2G)     │  │  (1C/2G)     │                        │
│   └──────┬───────┘  └──────┬───────┘                        │
│          │                  │                                │
│          └──────────┬───────┘                                │
│                     │                                        │
│            ┌────────▼────────┐                              │
│            │   CFS 存储      │                              │
│            │   (共享文件)     │                              │
│            └─────────────────┘                              │
└─────────────────────────────────────────────────────────────┘
                      │          │
          ┌───────────┘          └──────────────┐
          │                                     │
  ┌───────▼────────┐                   ┌────────▼────────┐
  │ TencentDB      │                   │ TencentDB       │
  │ PostgreSQL     │                   │ Redis           │
  │ (2C/4G/50GB)   │                   │ (2GB)           │
  └────────────────┘                   └─────────────────┘
                                                │
                                       ┌────────▼────────┐
                                       │  COS 对象存储    │
                                       │  (图片/附件)     │
                                       └─────────────────┘
```

### Pod 资源配置

| 组件 | 副本数 | Requests | Limits | 说明 |
|------|--------|----------|--------|------|
| **discourse-web** | 3 | 1C/2G | 2C/4G | Rails 应用主进程 |
| **discourse-sidekiq** | 2 | 0.5C/1G | 1C/2G | 后台任务处理 |
| **migration-job** | 1次性 | 0.5C/1G | 1C/2G | 数据库迁移 |

---

## 准备工作

### 1. 创建云资源

#### 1.1 创建 PostgreSQL 数据库

```bash
# 登录腾讯云控制台 -> 云数据库 PostgreSQL -> 新建实例
# 或使用 Terraform:

resource "tencentcloud_postgresql_instance" "discourse_db" {
  name              = "discourse-prod-db"
  availability_zone = "ap-guangzhou-3"
  charge_type       = "POSTPAID_BY_HOUR"
  vpc_id            = var.vpc_id
  subnet_id         = var.subnet_id
  db_version        = "13.3"
  
  # 规格
  memory            = 4
  storage           = 50
  
  # 自动备份
  backup_plan {
    min_backup_start_time = "02:00:00"
    max_backup_start_time = "03:00:00"
    backup_period         = ["monday", "wednesday", "friday"]
  }
}
```

**手动配置步骤:**

```sql
-- 1. 连接到 PostgreSQL (使用控制台提供的内网地址)
psql -h postgres-xxx.tencentcdb.com -U postgres

-- 2. 创建数据库和用户
CREATE DATABASE discourse_production ENCODING 'UTF8' LC_COLLATE='en_US.UTF-8' LC_CTYPE='en_US.UTF-8';
CREATE USER discourse WITH PASSWORD 'your-strong-password';
GRANT ALL PRIVILEGES ON DATABASE discourse_production TO discourse;

-- 3. 切换数据库并安装扩展
\c discourse_production postgres
CREATE EXTENSION IF NOT EXISTS hstore;
CREATE EXTENSION IF NOT EXISTS pg_trgm;

-- 4. 授权扩展给 discourse 用户
GRANT ALL ON ALL TABLES IN SCHEMA public TO discourse;
GRANT ALL ON ALL SEQUENCES IN SCHEMA public TO discourse;

-- 5. 验证
\l  -- 查看数据库列表
\dx -- 查看扩展
\q
```

**记录连接信息:**
```bash
DISCOURSE_DB_HOST=postgres-xxx.tencentcdb.com
DISCOURSE_DB_PORT=5432
DISCOURSE_DB_NAME=discourse_production
DISCOURSE_DB_USERNAME=discourse
DISCOURSE_DB_PASSWORD=your-strong-password
```

#### 1.2 创建 Redis

```bash
# 控制台 -> 云数据库 Redis -> 新建实例
# - 规格: 2GB 标准版
# - 版本: Redis 7.x
# - 网络: 与 TKE 同 VPC
```

**记录连接信息:**
```bash
DISCOURSE_REDIS_HOST=redis-xxx.tencentredis.com
DISCOURSE_REDIS_PORT=6379
DISCOURSE_REDIS_PASSWORD=your-redis-password  # 如果有
```

#### 1.3 创建 COS 存储桶

```bash
# 控制台 -> 对象存储 COS -> 创建存储桶
# - 名称: discourse-uploads-{appid}
# - 区域: ap-guangzhou
# - 访问权限: 私有读写

# 配置 CORS (重要!)
# 允许来源: https://forum.yourcompany.com
# 允许方法: GET, POST, PUT, DELETE, HEAD
# 允许头部: *
# 最大缓存: 600
```

**生成密钥:**
```bash
# 控制台 -> 访问管理 -> 访问密钥 -> API密钥管理
DISCOURSE_S3_ACCESS_KEY_ID=AKIDxxxxxx
DISCOURSE_S3_SECRET_ACCESS_KEY=xxxxxxxxxx
```

#### 1.4 创建 TKE 集群

```bash
# 控制台 -> 容器服务 TKE -> 创建集群
# - 集群类型: 标准集群
# - Kubernetes 版本: 1.24+
# - 网络: VPC-CNI (支持 Pod IP)
# - 节点规格: SA2.MEDIUM4 (4核8G)
# - 节点数量: 2 (高可用)
```

**配置 kubectl:**
```bash
# 1. 下载集群凭证
# TKE 控制台 -> 集群 -> 基本信息 -> 集群APIServer信息 -> 下载 kubeconfig

# 2. 配置
mkdir -p ~/.kube
cp /path/to/kubeconfig ~/.kube/config

# 3. 验证连接
kubectl get nodes
```

### 2. 准备镜像仓库

```bash
# 1. 创建 TCR 镜像仓库
# 控制台 -> 容器镜像服务 TCR -> 创建实例
# 或使用默认的 CCR

# 2. 创建命名空间
# 命名空间名称: discourse

# 3. 登录镜像仓库
docker login ccr.ccs.tencentyun.com
# 输入腾讯云账号密码
```

### 3. 配置域名和 SSL

```bash
# 1. 购买域名 (如果还没有)
# forum.yourcompany.com

# 2. 配置 DNS (先配置一个临时 A 记录)
# 等待 TKE Ingress 创建后，会分配 CLB IP，再更新 DNS

# 3. 申请 SSL 证书
# 控制台 -> SSL 证书 -> 申请免费证书
# 或使用 cert-manager 自动申请 Let's Encrypt
```

---

## 部署步骤

### 步骤 1: 构建 Docker 镜像 (10分钟)

```bash
# 1. 进入项目目录
cd /path/to/discourse

# 2. 确保 Dockerfile 存在
ls -l Dockerfile docker/

# 3. 构建镜像 (第一次需要 10-15 分钟)
docker build \
  --build-arg RUBY_VERSION=3.3.8 \
  -t ccr.ccs.tencentyun.com/discourse/discourse:v1.0.0 \
  -t ccr.ccs.tencentyun.com/discourse/discourse:latest \
  .

# 4. 推送镜像
docker push ccr.ccs.tencentyun.com/discourse/discourse:v1.0.0
docker push ccr.ccs.tencentyun.com/discourse/discourse:latest

# 5. 验证镜像
docker images | grep discourse
```

**常见问题:**
```bash
# 问题 1: 构建速度慢
# 解决: 使用国内镜像源
# 在 Dockerfile 中添加:
RUN sed -i 's/deb.debian.org/mirrors.tencent.com/g' /etc/apt/sources.list

# 问题 2: 推送失败
# 解决: 检查登录状态
docker login ccr.ccs.tencentyun.com
```

### 步骤 2: 配置 K8s 资源文件 (10分钟)

```bash
# 1. 生成 SECRET_KEY_BASE
SECRET_KEY_BASE=$(docker run --rm \
  ccr.ccs.tencentyun.com/discourse/discourse:latest \
  bundle exec rake secret)
echo "SECRET_KEY_BASE: $SECRET_KEY_BASE"

# 2. 备份原配置
cp k8s/deployment.yaml k8s/deployment.yaml.bak

# 3. 编辑配置文件
vim k8s/deployment.yaml
```

**必须修改的配置项:**

```yaml
# ===== ConfigMap 部分 =====
data:
  # 1. 修改域名
  DISCOURSE_HOSTNAME: "forum.yourcompany.com"  # ← 改成你的域名
  
  # 2. 修改数据库连接
  DISCOURSE_DB_HOST: "postgres-xxx.tencentcdb.com"  # ← 改成你的
  DISCOURSE_DB_NAME: "discourse_production"
  
  # 3. 修改 Redis 连接
  DISCOURSE_REDIS_HOST: "redis-xxx.tencentredis.com"  # ← 改成你的
  
  # 4. 修改 SMTP 邮件配置
  DISCOURSE_SMTP_ADDRESS: "smtp.exmail.qq.com"  # ← 改成你的邮件服务器
  DISCOURSE_SMTP_PORT: "465"
  DISCOURSE_SMTP_DOMAIN: "yourcompany.com"  # ← 改成你的域名
  
  # 5. 修改 COS 配置
  DISCOURSE_S3_REGION: "ap-guangzhou"  # ← 改成你的区域
  DISCOURSE_S3_BUCKET: "discourse-uploads-1234567890"  # ← 改成你的桶名
  DISCOURSE_S3_CDN_URL: "https://cdn.yourcompany.com"  # ← 改成你的CDN

# ===== Secret 部分 =====
stringData:
  # 6. 数据库密码
  DISCOURSE_DB_PASSWORD: "your-strong-db-password-here"  # ← 改成你的
  
  # 7. Redis 密码
  DISCOURSE_REDIS_PASSWORD: "your-redis-password"  # ← 如果有
  
  # 8. Rails Secret
  SECRET_KEY_BASE: "paste-the-generated-secret-here"  # ← 粘贴上面生成的
  
  # 9. SMTP 密码
  DISCOURSE_SMTP_PASSWORD: "your-smtp-password"  # ← 改成你的
  
  # 10. COS 密钥
  DISCOURSE_S3_ACCESS_KEY_ID: "AKIDxxxxxx"  # ← 改成你的
  DISCOURSE_S3_SECRET_ACCESS_KEY: "xxxxxxxxxx"  # ← 改成你的
  
  # 11. 管理员邮箱
  DISCOURSE_DEVELOPER_EMAILS: "admin@yourcompany.com"  # ← 改成你的

# ===== Deployment 部分 =====
spec:
  template:
    spec:
      containers:
      - name: discourse
        # 12. 修改镜像地址
        image: ccr.ccs.tencentyun.com/discourse/discourse:latest  # ← 改成你的
```

**快速替换脚本:**

```bash
# 使用 sed 批量替换 (谨慎使用!)
cd k8s

# 替换域名
sed -i 's/forum.yourcompany.com/forum.yourdomain.com/g' deployment.yaml

# 替换镜像地址
sed -i 's|your-registry.com/discourse|ccr.ccs.tencentyun.com/discourse/discourse|g' deployment.yaml

# 查看修改
git diff deployment.yaml
```

### 步骤 3: 部署到 K8s (5分钟)

```bash
# 1. 创建 Namespace
kubectl create namespace discourse

# 2. 部署所有资源
kubectl apply -f k8s/deployment.yaml

# 3. 查看部署进度
kubectl get all -n discourse

# 输出示例:
# NAME                                   READY   STATUS    RESTARTS   AGE
# pod/discourse-web-xxx                  0/3     Init:0/1  0          10s
# pod/discourse-sidekiq-xxx              0/2     Pending   0          10s
# job/discourse-migrate-xxx              0/1     Running   0          10s

# 4. 等待 Migration Job 完成 (约 2-3 分钟)
kubectl wait --for=condition=complete --timeout=600s \
  job/discourse-migrate-$(kubectl get job -n discourse -o jsonpath='{.items[0].metadata.name}' | cut -d'-' -f3-) \
  -n discourse

# 5. 查看 Migration 日志
kubectl logs -f -n discourse job/discourse-migrate-xxx

# 6. 等待所有 Pod Running (约 1-2 分钟)
kubectl get pods -n discourse -w

# 所有 Pod 应该显示:
# discourse-web-xxx      3/3     Running   0          3m
# discourse-sidekiq-xxx  2/2     Running   0          3m
```

**部署状态检查:**

```bash
# 详细检查脚本
cat > check_deployment.sh << 'EOF'
#!/bin/bash
echo "=== Namespace ==="
kubectl get ns discourse

echo -e "\n=== ConfigMap & Secret ==="
kubectl get configmap,secret -n discourse

echo -e "\n=== PVC ==="
kubectl get pvc -n discourse

echo -e "\n=== Jobs ==="
kubectl get jobs -n discourse

echo -e "\n=== Deployments ==="
kubectl get deployments -n discourse

echo -e "\n=== Pods ==="
kubectl get pods -n discourse -o wide

echo -e "\n=== Services ==="
kubectl get svc -n discourse

echo -e "\n=== Ingress ==="
kubectl get ingress -n discourse

echo -e "\n=== Pod Health ==="
kubectl get pods -n discourse -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.status.phase}{"\t"}{range .status.conditions[?(@.type=="Ready")]}{.status}{end}{"\n"}{end}'
EOF

chmod +x check_deployment.sh
./check_deployment.sh
```

### 步骤 4: 配置 Ingress (5分钟)

```bash
# 1. 创建 Ingress 资源
cat > /tmp/ingress.yaml << 'EOF'
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: discourse-ingress
  namespace: discourse
  annotations:
    # 使用腾讯云 CLB
    kubernetes.io/ingress.class: "qcloud"
    # 如果使用 Nginx Ingress
    # kubernetes.io/ingress.class: "nginx"
    
    # SSL 重定向
    ingress.cloud.tencent.com/redirect-to-https: "true"
    
    # 上传文件大小限制
    nginx.ingress.kubernetes.io/proxy-body-size: "100m"
    
    # 超时设置
    nginx.ingress.kubernetes.io/proxy-read-timeout: "600"
    nginx.ingress.kubernetes.io/proxy-send-timeout: "600"
    
    # WebSocket 支持
    nginx.ingress.kubernetes.io/proxy-http-version: "1.1"
    nginx.ingress.kubernetes.io/proxy-set-headers: "Upgrade $http_upgrade\nConnection 'upgrade'"
spec:
  tls:
  - hosts:
    - forum.yourcompany.com
    secretName: discourse-tls  # SSL 证书
  rules:
  - host: forum.yourcompany.com
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: discourse-web
            port:
              number: 80
EOF

kubectl apply -f /tmp/ingress.yaml

# 2. 获取 Ingress 分配的 CLB IP
kubectl get ingress -n discourse -o wide

# 输出示例:
# NAME                 CLASS    HOSTS                  ADDRESS        PORTS     AGE
# discourse-ingress    <none>   forum.yourcompany.com  192.168.1.100  80, 443   1m

# 3. 更新 DNS 记录
# 到域名服务商添加 A 记录:
# forum.yourcompany.com  ->  192.168.1.100

# 4. 配置 SSL 证书
# 方法 1: 手动上传证书
kubectl create secret tls discourse-tls \
  --cert=/path/to/cert.crt \
  --key=/path/to/cert.key \
  -n discourse

# 方法 2: 使用 cert-manager 自动申请 (推荐)
# 参考: https://cert-manager.io/docs/
```

### 步骤 5: 创建管理员账户 (3分钟)

```bash
# 1. 进入 Web Pod
WEB_POD=$(kubectl get pod -n discourse -l component=web -o jsonpath='{.items[0].metadata.name}')
kubectl exec -it -n discourse $WEB_POD -- bash

# 2. 在 Pod 内执行
cd /var/www/discourse

# 3. 创建管理员
bundle exec rake admin:create

# 按提示输入:
# Email:  admin@yourcompany.com
# Password:  ********** (输入强密码，至少10位)
# Repeat password:  **********
# 
# Ensuring account is active!
# 
# Account created successfully with username admin
# Do you want to grant Admin privileges to this account? (Y/n)  Y
# 
# User admin promoted to admin successfully!

# 4. 退出 Pod
exit
```

---

## 验证与测试

### 1. 健康检查

```bash
# 1. 检查 Pod 健康状态
kubectl get pods -n discourse

# 2. 检查健康检查端点
kubectl exec -n discourse $WEB_POD -- curl -f http://localhost:3000/srv/status

# 输出应该是: {"success": "OK"}

# 3. 检查数据库连接
kubectl exec -it -n discourse $WEB_POD -- \
  bundle exec rails dbconsole -p << EOF
SELECT version();
SELECT COUNT(*) FROM schema_migrations;
\q
EOF
```

### 2. 功能测试

```bash
# 1. 访问首页
curl -I https://forum.yourcompany.com

# 应该返回 200 OK

# 2. 访问管理后台
# 浏览器打开: https://forum.yourcompany.com/admin
# 使用刚才创建的管理员账户登录

# 3. 测试邮件发送
# 后台 -> Settings -> Email -> Send Test Email
# 填入一个邮箱地址，点击发送

# 4. 测试图片上传
# 创建一个帖子，上传一张图片
# 检查图片是否保存到 COS
```

### 3. 性能测试

```bash
# 1. 安装 Apache Bench (如果没有)
sudo apt-get install apache2-utils

# 2. 并发测试
ab -n 1000 -c 10 https://forum.yourcompany.com/

# 3. 查看 Pod 资源使用
kubectl top pods -n discourse

# 4. 查看数据库连接数
kubectl exec -it -n discourse $WEB_POD -- \
  bundle exec rails dbconsole -p << EOF
SELECT COUNT(*) FROM pg_stat_activity WHERE datname = 'discourse_production';
\q
EOF
```

---

## 日常运维

### 1. 代码更新部署

```bash
# 场景: 修改了源码或添加了新插件

# 1. 提交代码
git add .
git commit -m "Add custom feature"
git push

# 2. 重新构建镜像 (使用新版本号)
docker build -t ccr.ccs.tencentyun.com/discourse/discourse:v1.0.1 .
docker push ccr.ccs.tencentyun.com/discourse/discourse:v1.0.1

# 3. 更新镜像 (滚动更新，零停机)
kubectl set image deployment/discourse-web -n discourse \
  discourse=ccr.ccs.tencentyun.com/discourse/discourse:v1.0.1

kubectl set image deployment/discourse-sidekiq -n discourse \
  sidekiq=ccr.ccs.tencentyun.com/discourse/discourse:v1.0.1

# 4. 查看更新进度
kubectl rollout status deployment/discourse-web -n discourse
kubectl rollout status deployment/discourse-sidekiq -n discourse

# 5. 如果有数据库迁移，需要先运行 Migration Job
# 编辑 k8s/deployment.yaml 中的 Job 名称，然后:
kubectl apply -f k8s/deployment.yaml
```

### 2. 扩容缩容

```bash
# Web 扩容到 5 个副本
kubectl scale deployment discourse-web --replicas=5 -n discourse

# Sidekiq 扩容到 3 个副本
kubectl scale deployment discourse-sidekiq --replicas=3 -n discourse

# 验证
kubectl get pods -n discourse -l component=web
kubectl get pods -n discourse -l component=sidekiq

# 自动扩容 (HPA)
kubectl autoscale deployment discourse-web -n discourse \
  --min=3 --max=10 --cpu-percent=70

# 查看 HPA 状态
kubectl get hpa -n discourse
```

### 3. 备份与恢复

```bash
# 1. 备份数据库
kubectl exec -n discourse $WEB_POD -- \
  pg_dump -h postgres-xxx.tencentcdb.com \
          -U discourse \
          -d discourse_production \
          -Fc -f /tmp/backup_$(date +%Y%m%d).dump

# 复制备份到本地
kubectl cp discourse/$WEB_POD:/tmp/backup_*.dump ./backup_$(date +%Y%m%d).dump

# 2. 恢复数据库 (谨慎操作!)
# 上传备份到 Pod
kubectl cp ./backup_20250129.dump discourse/$WEB_POD:/tmp/

# 恢复
kubectl exec -n discourse $WEB_POD -- \
  pg_restore -h postgres-xxx.tencentcdb.com \
             -U discourse \
             -d discourse_production \
             -c /tmp/backup_20250129.dump

# 3. 备份 COS 文件
# 使用腾讯云控制台的 COS 备份功能
# 或使用 COSCMD 工具
```

### 4. 日志查看

```bash
# 查看 Web 日志
kubectl logs -f -n discourse -l component=web

# 查看 Sidekiq 日志
kubectl logs -f -n discourse -l component=sidekiq

# 查看特定 Pod 日志
kubectl logs -f -n discourse $WEB_POD

# 查看之前的日志 (Pod 重启后)
kubectl logs -p -n discourse $WEB_POD

# 导出所有日志
kubectl logs -n discourse --all-containers=true --prefix=true > discourse_logs.txt
```

### 5. 进入 Pod 调试

```bash
# 进入 Web Pod
kubectl exec -it -n discourse $WEB_POD -- bash

# 进入 Rails Console
kubectl exec -it -n discourse $WEB_POD -- \
  bundle exec rails console

# 在 Console 中:
# User.count  # 查看用户数
# SiteSetting.title = "My Forum"  # 修改站点标题
# exit

# 查看数据库
kubectl exec -it -n discourse $WEB_POD -- \
  bundle exec rails dbconsole
```

### 6. 监控和告警

```bash
# 安装 Prometheus + Grafana (可选)
# 使用 kube-prometheus-stack Helm Chart

# 添加 Helm 仓库
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo update

# 安装
helm install kube-prometheus-stack prometheus-community/kube-prometheus-stack \
  --namespace monitoring --create-namespace

# 访问 Grafana
kubectl port-forward -n monitoring svc/kube-prometheus-stack-grafana 3000:80

# 浏览器打开: http://localhost:3000
# 默认用户名: admin
# 默认密码: prom-operator

# 导入 Discourse 监控面板
# Dashboard ID: 12230 (Rails Prometheus)
```

---

## 故障排查

### 问题 1: Pod 无法启动

**症状:**
```bash
kubectl get pods -n discourse
# discourse-web-xxx   0/3   Init:Error   0   5m
```

**排查步骤:**

```bash
# 1. 查看 Pod 详情
kubectl describe pod discourse-web-xxx -n discourse

# 2. 查看 Pod 日志
kubectl logs discourse-web-xxx -n discourse -c discourse

# 3. 查看 Init Container 日志
kubectl logs discourse-web-xxx -n discourse -c wait-for-migration

# 4. 常见原因:
# - 镜像拉取失败: 检查镜像地址和仓库权限
# - 环境变量错误: 检查 ConfigMap 和 Secret
# - 数据库连接失败: 检查数据库配置和网络
# - 迁移任务未完成: 检查 Migration Job
```

### 问题 2: 数据库连接失败

**症状:**
```bash
# Pod 日志显示:
# could not connect to server: Connection refused
```

**排查步骤:**

```bash
# 1. 检查数据库地址
kubectl get configmap discourse-config -n discourse -o yaml | grep DB_HOST

# 2. 测试网络连接
kubectl exec -it -n discourse $WEB_POD -- \
  nc -zv postgres-xxx.tencentcdb.com 5432

# 3. 测试数据库认证
kubectl exec -it -n discourse $WEB_POD -- \
  psql -h postgres-xxx.tencentcdb.com \
       -U discourse \
       -d discourse_production \
       -c "SELECT version();"

# 4. 检查安全组规则
# 确保 TKE 节点可以访问 PostgreSQL 的内网地址

# 5. 检查密码是否正确
kubectl get secret discourse-secrets -n discourse -o yaml
echo "<base64-encoded-password>" | base64 -d
```

### 问题 3: 图片上传到 COS 失败

**症状:**
```bash
# 上传图片时报错: Upload failed
```

**排查步骤:**

```bash
# 1. 检查 COS 配置
kubectl get configmap discourse-config -n discourse -o yaml | grep S3

# 2. 检查 COS 密钥
kubectl get secret discourse-secrets -n discourse -o yaml | grep S3

# 3. 测试 COS 连接 (在 Pod 内)
kubectl exec -it -n discourse $WEB_POD -- bash

# 安装 COSCMD (如果没有)
pip3 install coscmd

# 配置
coscmd config -a $DISCOURSE_S3_ACCESS_KEY_ID \
              -s $DISCOURSE_S3_SECRET_ACCESS_KEY \
              -b discourse-uploads-xxx \
              -r ap-guangzhou

# 测试上传
echo "test" > /tmp/test.txt
coscmd upload /tmp/test.txt test.txt

# 4. 检查 CORS 配置
# 控制台 -> COS -> 你的存储桶 -> 安全管理 -> 跨域访问 CORS
```

### 问题 4: 邮件发送失败

**症状:**
```bash
# 后台测试邮件失败: SMTP connection failed
```

**排查步骤:**

```bash
# 1. 检查 SMTP 配置
kubectl get configmap discourse-config -n discourse -o yaml | grep SMTP

# 2. 测试 SMTP 连接 (在 Pod 内)
kubectl exec -it -n discourse $WEB_POD -- bash

# 安装 telnet
apt-get update && apt-get install -y telnet

# 测试连接
telnet smtp.exmail.qq.com 465

# 3. 在 Rails Console 中测试
kubectl exec -it -n discourse $WEB_POD -- bundle exec rails console

# 发送测试邮件
Email::Sender.new(
  message: "Test",
  to_address: "test@example.com"
).send

# 4. 查看 Sidekiq 队列
# 浏览器访问: https://forum.yourcompany.com/sidekiq
# (需要管理员权限)
```

### 问题 5: 性能问题

**症状:**
```bash
# 网站响应慢，Pod CPU/内存使用率高
```

**排查步骤:**

```bash
# 1. 查看资源使用
kubectl top pods -n discourse

# 2. 查看 Pod 事件
kubectl get events -n discourse --sort-by='.lastTimestamp'

# 3. 检查数据库性能
kubectl exec -it -n discourse $WEB_POD -- \
  bundle exec rails dbconsole -p << EOF
-- 慢查询
SELECT query, mean_exec_time, calls
FROM pg_stat_statements
ORDER BY mean_exec_time DESC
LIMIT 10;
EOF

# 4. 检查 Redis 性能
kubectl exec -it -n discourse $WEB_POD -- bash
redis-cli -h redis-xxx.tencentredis.com
INFO stats
SLOWLOG GET 10

# 5. 增加资源限制或扩容
kubectl edit deployment discourse-web -n discourse
# 修改 resources.limits
```

---

## 安全加固

### 1. 网络策略

```bash
# 创建 NetworkPolicy 限制 Pod 间通信
cat > /tmp/network-policy.yaml << 'EOF'
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: discourse-network-policy
  namespace: discourse
spec:
  podSelector:
    matchLabels:
      app: discourse
  policyTypes:
  - Ingress
  - Egress
  ingress:
  - from:
    - namespaceSelector:
        matchLabels:
          name: ingress-nginx
    ports:
    - protocol: TCP
      port: 3000
  egress:
  - to:
    - namespaceSelector: {}
    ports:
    - protocol: TCP
      port: 5432  # PostgreSQL
    - protocol: TCP
      port: 6379  # Redis
    - protocol: TCP
      port: 443   # HTTPS
    - protocol: TCP
      port: 80    # HTTP
EOF

kubectl apply -f /tmp/network-policy.yaml
```

### 2. Pod Security Policy

```bash
# 使用 Pod Security Standards
kubectl label namespace discourse \
  pod-security.kubernetes.io/enforce=baseline \
  pod-security.kubernetes.io/audit=restricted \
  pod-security.kubernetes.io/warn=restricted
```

### 3. 定期更新

```bash
# 1. 更新 Discourse 核心
git remote add upstream https://github.com/discourse/discourse.git
git fetch upstream
git merge upstream/main

# 2. 更新 Ruby 依赖
bundle update

# 3. 更新前端依赖
pnpm update

# 4. 重新构建镜像
docker build -t ccr.ccs.tencentyun.com/discourse/discourse:v1.0.2 .
docker push ccr.ccs.tencentyun.com/discourse/discourse:v1.0.2

# 5. 滚动更新
kubectl set image deployment/discourse-web -n discourse \
  discourse=ccr.ccs.tencentyun.com/discourse/discourse:v1.0.2
```

---

## 附录

### A. 完整的部署脚本

```bash
#!/bin/bash
# deploy-discourse-k8s.sh

set -e

# 配置变量
NAMESPACE="discourse"
IMAGE_REGISTRY="ccr.ccs.tencentyun.com"
IMAGE_NAME="discourse/discourse"
VERSION="v1.0.0"

echo "=== Discourse K8s 部署脚本 ==="

# 1. 构建镜像
echo "1. 构建 Docker 镜像..."
docker build -t ${IMAGE_REGISTRY}/${IMAGE_NAME}:${VERSION} .
docker tag ${IMAGE_REGISTRY}/${IMAGE_NAME}:${VERSION} ${IMAGE_REGISTRY}/${IMAGE_NAME}:latest

# 2. 推送镜像
echo "2. 推送镜像到仓库..."
docker push ${IMAGE_REGISTRY}/${IMAGE_NAME}:${VERSION}
docker push ${IMAGE_REGISTRY}/${IMAGE_NAME}:latest

# 3. 创建命名空间
echo "3. 创建 Namespace..."
kubectl create namespace ${NAMESPACE} --dry-run=client -o yaml | kubectl apply -f -

# 4. 部署资源
echo "4. 部署 K8s 资源..."
kubectl apply -f k8s/deployment.yaml

# 5. 等待 Migration Job
echo "5. 等待数据库迁移完成..."
kubectl wait --for=condition=complete --timeout=600s \
  -l app=discourse,component=migrate \
  job -n ${NAMESPACE}

# 6. 等待 Pod 就绪
echo "6. 等待 Pod 就绪..."
kubectl wait --for=condition=ready --timeout=300s \
  pod -l component=web -n ${NAMESPACE}

# 7. 检查状态
echo "7. 检查部署状态..."
kubectl get all -n ${NAMESPACE}

echo "=== 部署完成! ==="
echo "下一步:"
echo "1. 配置 DNS 解析"
echo "2. 创建管理员账户: kubectl exec -it -n ${NAMESPACE} <pod-name> -- bundle exec rake admin:create"
echo "3. 访问网站测试"
```

### B. 监控指标

| 指标 | 正常值 | 警告阈值 | 说明 |
|------|--------|----------|------|
| CPU 使用率 | < 50% | > 70% | 单个 Pod |
| 内存使用率 | < 60% | > 80% | 单个 Pod |
| Pod 重启次数 | 0 | > 3/小时 | 频繁重启 |
| 响应时间 | < 500ms | > 2s | 首页加载 |
| 数据库连接数 | < 20 | > 80 | 连接池 25 |
| Sidekiq 队列长度 | < 100 | > 1000 | 积压任务 |

### C. 成本优化建议

1. **使用竞价实例** (非生产环境)
   - 节省 50-70% 成本
   - 适合测试/开发环境

2. **启用 HPA 自动扩缩容**
   - 低峰期自动缩容
   - 节省 30-40% 成本

3. **COS 生命周期管理**
   - 90 天后转归档存储
   - 节省 60% 存储成本

4. **数据库按量付费 → 包年包月**
   - 稳定后改包年包月
   - 节省 15-20% 成本

---

## 联系支持

如有问题，请联系:
- 邮件: devops@yourcompany.com
- 企业微信群: Discourse 运维支持群
- 文档反馈: https://github.com/yourcompany/discourse/issues
