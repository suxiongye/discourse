FROM discourse/base:release

LABEL maintainer="your-email@example.com"
USER root

# ========================================
# 升级 PostgreSQL 客户端到 18
# ========================================
RUN apt-get update && \
    apt-get install -y wget gnupg2 lsb-release && \
    sh -c 'echo "deb http://apt.postgresql.org/pub/repos/apt $(lsb_release -cs)-pgdg main" > /etc/apt/sources.list.d/pgdg.list' && \
    wget --quiet -O - https://www.postgresql.org/media/keys/ACCC4CF8.asc | apt-key add - && \
    apt-get update && \
    apt-get install -y postgresql-client-18 && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/*
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

# 安装调试工具
RUN apt-get update && \
    apt-get install -y tcpdump vim && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/*

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
