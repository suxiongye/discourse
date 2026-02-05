# Discourse Docker OOM 问题解决方案

## 问题诊断

### 症状
- 容器频繁重启，状态显示 `Exited (137)`
- `docker inspect` 显示 `"OOMKilled": true`
- 访问页面时报错：`esbuild` 相关错误或 `The service was stopped`

### 根本原因
1. **跨平台 node_modules 问题**：在 macOS 安装依赖后挂载到 Linux 容器，导致 esbuild 二进制文件不匹配
2. **开发模式内存不足**：Discourse 开发模式实时编译 assets 非常耗内存（> 6GB）

## 解决方案

### 方案 1：使用纯容器构建（推荐）

**优点**：
- ✅ node_modules 在容器内安装，无跨平台问题  
- ✅ esbuild 二进制文件正确匹配 Linux ARM64
- ✅ 不依赖本地 node_modules

**步骤**：

1. 使用 `Dockerfile.local` 构建镜像：
```bash
docker build -f Dockerfile.local -t discourse:local --platform linux/arm64 .
```

2. 启动容器（分配足够内存）：
```bash
docker run -d \
  --name discourse_web \
  --env-file .env.local \
  --add-host=host.docker.internal:host-gateway \
  --memory="8g" \
  --memory-swap="10g" \
  --restart=unless-stopped \
  -p 3000:3000 \
  discourse:local
```

**注意**：
- 开发模式首次访问时会实时编译 assets，需要 **8GB+ 内存**
- 如果机器内存不足，考虑方案 2

### 方案 2：预编译 Assets（生产模式）

**优点**：
- ✅ 运行时内存占用低（~2GB）
- ✅ 启动快，无实时编译开销
- ✅ 适合内存受限环境

**缺点**：
- ❌ 修改前端代码需要重新构建镜像
- ❌ 首次构建慢（需要预编译）

**步骤**：

1. 使用 `Dockerfile.prod` 构建：
```bash
docker build -f Dockerfile.prod -t discourse:prod --platform linux/arm64 .
```

2. 启动容器（内存需求更低）：
```bash
docker run -d \
  --name discourse_web \
  --env-file .env.local \
  --add-host=host.docker.internal:host-gateway \
  --memory="4g" \
  --memory-swap="6g" \
  --restart=unless-stopped \
  -p 3000:3000 \
  discourse:prod
```

3. 首次启动会在容器内预编译 assets（需要 5-10 分钟）

### 方案 3：官方 discourse/base 镜像（如果可用）

如果你不需要修改 Discourse 核心代码，可以直接使用官方镜像：

```dockerfile
FROM discourse/base:latest
# 添加你的自定义配置
```

## 常用命令

### 检查是否 OOM
```bash
docker inspect discourse_web | grep OOMKilled
```

### 查看内存使用
```bash
docker stats discourse_web --no-stream
```

### 查看日志
```bash
docker logs --tail 100 discourse_web
```

### 清理并重启
```bash
docker stop discourse_web && docker rm discourse_web
# 然后重新运行 docker run 命令
```

## 推荐配置

### 开发环境（方案 1）
- **内存**: 8GB RAM, 10GB swap
- **CPU**: 4+ cores
- **用途**: 频繁修改代码，需要实时编译

### 生产环境（方案 2）
- **内存**: 4GB RAM, 6GB swap
- **CPU**: 2+ cores  
- **用途**: 稳定运行，不常修改代码

## 故障排查

### esbuild 错误
```
Error: You installed esbuild for another platform
```
**原因**: node_modules 跨平台不兼容  
**解决**: 使用方案 1 或 2，在容器内安装依赖

### 容器频繁重启
```
Exited (137) X minutes ago
```
**原因**: OOM Killed  
**解决**: 增加内存限制到 8GB+

### Assets 编译失败
```
The service was stopped (esbuild)
```
**原因**: 内存不足导致 esbuild 进程崩溃  
**解决**: 使用方案 2 预编译 assets

## 相关文件

- `Dockerfile.local` - 开发模式镜像（实时编译）
- `Dockerfile.prod` - 生产模式镜像（预编译 assets）
- `docker-entrypoint.sh` - 启动脚本（清理 PID）
- `docker-entrypoint-prod.sh` - 生产模式启动脚本（预编译逻辑）
- `start-local.sh` - 快速启动脚本
- `.env.local` - 环境变量配置

## 更新日志

- 2026-01-29: 初始版本，记录 OOM 问题和解决方案
