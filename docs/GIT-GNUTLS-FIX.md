# Git GnuTLS 连接不稳定问题修复

## 问题概述

Discourse 主题组件更新在腾讯云环境中偶发失败，错误提示：
```
克隆 git 仓库时出错，访问被拒绝或找不到仓库
```

本地测试显示 `git clone https://github.com/...` 耗时 1 分 34 秒后报 GnuTLS TLS 握手错误，而 curl 同一 URL 仅需 0.6 秒。

---

## 根因分析

### 问题链路

```
Ubuntu 系统默认 git 配置
  ↓
git 使用 libcurl-gnutls (GnuTLS SSL 后端)
  ↓
腾讯云网络环境下 GnuTLS TLS 握手不稳定
  ↓
连接超时或中止（默认超时 20 秒）
  ↓
主题组件更新失败
```

### 为什么 curl 正常？

系统上同时存在两个 libcurl 版本：
- `libcurl.so.4` - OpenSSL 后端（curl 命令使用）
- `libcurl-gnutls.so.4` - GnuTLS 后端（git 使用）

OpenSSL 在腾讯云网络环境中 TLS 握手更稳定。

---

## 解决方案

### 1. 容器镜像修复（Dockerfile）

从源码编译 git-remote-http，强制链接 OpenSSL 版 libcurl：

```dockerfile
RUN apt-get install -y libcurl4-openssl-dev libssl-dev ... && \
    GIT_VER=$(git --version | awk '{print $3}') && \
    cd /tmp && curl -fsSL "https://mirrors.edge.kernel.org/pub/software/scm/git/git-${GIT_VER}.tar.gz" -o git.tar.gz && \
    tar xzf git.tar.gz && cd "git-${GIT_VER}" && \
    make prefix=/usr CURLDIR=/usr CURL_CONFIG=/usr/bin/curl-config -j$(nproc) NO_TCLTK=1 git-remote-http && \
    # 手动替换（make install 无法覆盖系统包管理的文件）
    cp git-remote-http /usr/lib/git-core/git-remote-http && \
    ln -sf git-remote-http /usr/lib/git-core/git-remote-https && \
    ln -sf git-remote-http /usr/lib/git-core/git-remote-ftp && \
    ln -sf git-remote-http /usr/lib/git-core/git-remote-ftps && \
    apt-get purge -y ... && apt-get install -y libcurl4
```

**关键点：**
- 指定 `CURLDIR=/usr CURL_CONFIG=/usr/bin/curl-config` 强制使用 OpenSSL 版
- 用 `cp + ln -sf` 手动替换，不依赖 `make install`
- 保留 `libcurl4` 运行时库

### 2. 开发机修复

```bash
# 编译
cd /tmp/git-2.43.0
make prefix=/usr CURLDIR=/usr CURL_CONFIG=/usr/bin/curl-config -j$(nproc) NO_TCLTK=1 git-remote-http

# 手动安装
sudo cp git-remote-http /usr/lib/git-core/git-remote-http
sudo ln -sf git-remote-http /usr/lib/git-core/git-remote-https
sudo ln -sf git-remote-http /usr/lib/git-core/git-remote-ftp
sudo ln -sf git-remote-http /usr/lib/git-core/git-remote-ftps

# 验证
ldd /usr/lib/git-core/git-remote-https | grep curl
# 应输出：libcurl.so.4 => /lib/x86_64-linux-gnu/libcurl.so.4
```

### 3. 验证修复

```bash
time git clone https://github.com/drforever/header-style.git /tmp/test-clone
# 应在 5-10 秒内完成
rm -rf /tmp/test-clone
```

---

## 其他配置

### 超时时间扩展（可选）

通过插件 `plugins/discourse-git-timeout/plugin.rb` 支持读取 `DISCOURSE_GIT_TIMEOUT` 环境变量扩展 git clone 超时时间（默认 20 秒）。

---

## 相关文件

- `Dockerfile` - 容器镜像编译配置
- `plugins/discourse-git-timeout/plugin.rb` - 超时时间扩展插件
- `lib/theme_store/git_importer.rb` - 主题 git 导入逻辑（未修改）

