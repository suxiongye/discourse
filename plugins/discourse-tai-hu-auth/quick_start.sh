#!/bin/bash
# 太湖认证插件快速启动脚本

set -e

echo "================================================================================"
echo "太湖认证插件 - 快速启动"
echo "================================================================================"
echo

# 颜色定义
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m' # No Color

# 检查是否在正确的目录
if [ ! -f "bin/rails" ]; then
    echo -e "${RED}❌ 错误: 请在 Discourse 根目录运行此脚本${NC}"
    exit 1
fi

echo -e "${YELLOW}步骤 1: 检查插件文件${NC}"
if [ -f "plugins/discourse-tai-hu-auth/plugin.rb" ]; then
    echo -e "${GREEN}✅ 插件文件存在${NC}"
else
    echo -e "${RED}❌ 插件文件不存在${NC}"
    exit 1
fi

echo
echo -e "${YELLOW}步骤 2: 检查依赖${NC}"
if bundle show json-jwt > /dev/null 2>&1; then
    echo -e "${GREEN}✅ json-jwt gem 已安装${NC}"
else
    echo -e "${YELLOW}⚠️  json-jwt gem 未安装，正在安装...${NC}"
    bundle install
fi

echo
echo -e "${YELLOW}步骤 3: 启用插件${NC}"
echo "正在配置..."

bundle exec rails runner "
SiteSetting.tai_hu_auth_enabled = true
SiteSetting.tai_hu_auto_create_user = true
SiteSetting.tai_hu_email_domain = 'tencent.com'
SiteSetting.tai_hu_auto_activate_user = true

puts '✅ 插件已启用'
puts '   tai_hu_auth_enabled: ' + SiteSetting.tai_hu_auth_enabled.to_s
puts '   tai_hu_auto_create_user: ' + SiteSetting.tai_hu_auto_create_user.to_s
puts '   tai_hu_email_domain: ' + SiteSetting.tai_hu_email_domain
puts '   tai_hu_auto_activate_user: ' + SiteSetting.tai_hu_auto_activate_user.to_s
"

echo
echo -e "${YELLOW}步骤 4: 验证插件加载${NC}"
bundle exec rails runner plugins/discourse-tai-hu-auth/test_plugin.rb

echo
echo "================================================================================"
echo -e "${GREEN}✅ 插件启动完成！${NC}"
echo "================================================================================"
echo
echo "后续步骤:"
echo "  1. 配置 Token Key:"
echo "     bundle exec rails c"
echo "     SiteSetting.tai_hu_token_key = 'your-32-byte-key'"
echo
echo "  2. 启动开发服务器:"
echo "     bin/rails s"
echo
echo "  3. 测试认证:"
echo "     curl -H 'x-tai-identity: YOUR_TOKEN' http://localhost:3000"
echo
echo "  4. 查看日志:"
echo "     tail -f log/development.log | grep '太湖'"
echo
echo "详细文档: plugins/discourse-tai-hu-auth/USAGE.md"
echo "================================================================================"
