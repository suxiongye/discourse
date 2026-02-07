FROM discourse/base:release

LABEL maintainer="your-email@example.com"

# 配置国内镜像源（用户级配置）
USER discourse
RUN bundle config set --global mirror.https://rubygems.org https://gems.ruby-china.com

# 清理 base 镜像的代码（但保留系统级依赖和工具）
USER root
RUN rm -rf /var/www/discourse/*

WORKDIR /var/www/discourse
USER discourse

# ========================================
# 阶段 1: 安装 Ruby 依赖（优先，可缓存）
# ========================================
# 只复制依赖文件，Gemfile 不变时此层会被缓存
COPY --chown=discourse:discourse Gemfile Gemfile.lock ./

# 修改 Gemfile 使用国内镜像源
RUN sed -i 's|https://rubygems.org|https://gems.ruby-china.com|g' Gemfile

# 彻底清理 bundle 配置，重新设置
RUN rm -rf .bundle && \
    bundle config unset deployment && \
    bundle config set --local path 'vendor/bundle' && \
    bundle config set --local without 'development test' && \
    bundle install --jobs 4 --retry 5 --verbose

# ========================================
# 阶段 2: 复制完整代码（包含前端 workspace 结构）
# ========================================
COPY --chown=discourse:discourse . /var/www/discourse/

# ========================================
# 阶段 3: 安装前端依赖（需要完整代码）
# ========================================
RUN if [ -f pnpm-lock.yaml ]; then \
        pnpm install --frozen-lockfile; \
    elif [ -f yarn.lock ]; then \
        yarn install --frozen-lockfile && yarn cache clean; \
    fi

# Unicorn 不需要修复路径，它通过 discourse_path 自动检测

USER root

# 安装调试工具 & 修复 git GnuTLS 不稳定问题
# Ubuntu 默认 git 使用 libcurl-gnutls，在腾讯云连接 GitHub 时 TLS 不稳定
# 从源码编译 git-remote-http 使其链接 OpenSSL 版 libcurl，然后手动替换
# (make install 无法覆盖系统包管理的文件，必须手动 cp)
RUN apt-get update && \
    apt-get install -y tcpdump vim \
      libcurl4-openssl-dev libssl-dev libexpat1-dev gettext zlib1g-dev make gcc pkg-config && \
    GIT_VER=$(git --version | awk '{print $3}') && \
    cd /tmp && \
    curl -fsSL "https://mirrors.edge.kernel.org/pub/software/scm/git/git-${GIT_VER}.tar.gz" -o git.tar.gz && \
    tar xzf git.tar.gz && \
    cd "git-${GIT_VER}" && \
    make prefix=/usr CURLDIR=/usr CURL_CONFIG=/usr/bin/curl-config -j$(nproc) NO_TCLTK=1 git-remote-http && \
    # 验证编译产物链接 OpenSSL 版 libcurl
    echo "=== 编译产物验证 ===" && readelf -d git-remote-http | grep curl && \
    # 手动替换系统 git-remote-http 并重建符号链接
    cp git-remote-http /usr/lib/git-core/git-remote-http && \
    ln -sf git-remote-http /usr/lib/git-core/git-remote-https && \
    ln -sf git-remote-http /usr/lib/git-core/git-remote-ftp && \
    ln -sf git-remote-http /usr/lib/git-core/git-remote-ftps && \
    # 验证安装结果
    echo "=== 安装后验证 ===" && ldd /usr/lib/git-core/git-remote-https | grep curl && \
    cd / && rm -rf /tmp/git* && \
    # 清理编译依赖，保留 libcurl4(openssl) 运行时库
    apt-get purge -y make gcc libcurl4-openssl-dev libssl-dev libexpat1-dev gettext zlib1g-dev pkg-config && \
    apt-get install -y libcurl4 && \
    apt-get autoremove -y && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/* && \
    # 最终验证（清理后 libcurl 运行时仍在）
    echo "=== 最终验证 ===" && ldd /usr/lib/git-core/git-remote-https | grep curl

# 创建必要目录
RUN mkdir -p /shared/log/rails \
             /shared/uploads \
             /shared/backups \
             /var/www/discourse/tmp/sockets \
             /var/www/discourse/tmp/pids \
             /var/www/discourse/log \
             /var/www/discourse/public/assets && \
    chown -R discourse:discourse /shared /var/www/discourse/tmp /var/www/discourse/log /var/www/discourse/public && \
    chmod 1777 /tmp

EXPOSE 3000

USER discourse

ENV RUBYOPT=""
ENV DISCOURSE_DOWNLOAD_PRE_BUILT_ASSETS=0

# 启动时检查并预编译 assets，然后启动 Unicorn
CMD ["/bin/bash", "-c", "\
    if [ ! -f /var/www/discourse/tmp/asset-processor.js ]; then \
        echo '📦 Precompiling assets...' && \
        bundle exec rake assets:precompile; \
    fi && \
    echo '🚀 Starting Unicorn...' && \
    bundle exec unicorn -c config/unicorn.conf.rb"]
