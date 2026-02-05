# 太湖认证插件使用指南

## 快速开始

### 1. 启用插件

有两种方式启用插件：

#### 方式A: 通过 Rails Console

```ruby
# 进入 Rails console
bundle exec rails c

# 启用插件
SiteSetting.tai_hu_auth_enabled = true
SiteSetting.tai_hu_token_key = "your-32-byte-secret-key-here"

# 确认配置
puts "插件已启用: #{SiteSetting.tai_hu_auth_enabled}"
```

#### 方式B: 通过环境变量（推荐生产环境）

在 `/etc/discourse/discourse.conf` 或环境变量中添加：

```bash
DISCOURSE_TAI_HU_AUTH_ENABLED=true
DISCOURSE_TAI_HU_TOKEN_KEY="your-32-byte-secret-key-here"
DISCOURSE_TAI_HU_AUTO_CREATE_USER=true
DISCOURSE_TAI_HU_EMAIL_DOMAIN="tencent.com"
DISCOURSE_TAI_HU_AUTO_ACTIVATE_USER=true
```

然后重启 Discourse：

```bash
cd /var/discourse
./launcher restart app
```

### 2. 配置反向代理

#### Nginx 配置示例

在 Nginx 配置中添加太湖 header 转发：

```nginx
server {
    listen 443 ssl;
    server_name your-forum.example.com;

    location / {
        proxy_pass http://discourse;
        
        # 转发太湖认证 header
        proxy_set_header X-Tai-Identity $http_x_tai_identity;
        
        # 其他标准 headers
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }
}
```

### 3. 测试

使用 curl 测试：

```bash
# 替换为实际的 token
TOKEN="eyJhbGciOiJkaXIiLCJlbmMiOiJBMjU2R0NNIi..."

curl -X GET "https://your-forum.example.com/" \
  -H "x-tai-identity: $TOKEN" \
  -v
```

查看日志验证：

```bash
# 查看最新日志
tail -f /var/discourse/shared/standalone/log/rails/production.log | grep "太湖"
```

预期输出：

```
太湖认证 token 验证成功，跳过 CSRF 检查: LoginName=xiongyesu
太湖认证: 找到已有用户 xiongyesu (id: 123, StaffId: 231825)
太湖认证自动登录成功: xiongyesu (id: 123)
```

## 配置说明

### 必需配置

| 配置项 | 类型 | 说明 | 示例 |
|--------|------|------|------|
| `tai_hu_auth_enabled` | Boolean | 启用插件 | `true` |
| `tai_hu_token_key` | String (Secret) | JWE解密密钥（32字节） | `aaaaa...` |

### 可选配置

| 配置项 | 默认值 | 说明 |
|--------|--------|------|
| `tai_hu_auto_create_user` | `true` | 自动创建新用户 |
| `tai_hu_email_domain` | `tencent.com` | 新用户邮箱域名 |
| `tai_hu_auto_activate_user` | `true` | 跳过邮箱验证 |

## 用户创建规则

### 查找用户

插件按以下顺序查找用户：

1. Email: `{LoginName}@{email_domain}`
2. Username: `{LoginName}`
3. Custom Field: `tai_hu_staff_id = {StaffId}`

### 创建用户

如果用户不存在且 `tai_hu_auto_create_user=true`：

```ruby
{
  username: login_name,              # 如: "xiongyesu"
  email: "#{login_name}@tencent.com", # 如: "xiongyesu@tencent.com"
  name: chinese_name,                 # 如: "苏雄业"
  password: SecureRandom.hex(32),     # 随机密码
  active: true,                       # 自动激活
  custom_fields: {
    tai_hu_staff_id: staff_id        # 保存工号
  }
}
```

## 安全注意事项

### 1. 密钥管理

**重要**: `tai_hu_token_key` 是敏感信息，必须：
- ✅ 使用环境变量或 `discourse.conf`
- ✅ 不要提交到 Git
- ✅ 定期轮换（建议每季度）
- ❌ 不要写在代码中
- ❌ 不要记录在日志中

### 2. Token 验证

插件会验证：
- ✅ Token 签名正确
- ✅ Token 未过期（允许3分钟时钟偏差）
- ✅ Token 格式正确

### 3. CSRF 保护

- 有效的太湖 token 跳过 CSRF 验证
- Token 本身作为身份凭证
- 无效 token 仍会触发 CSRF 检查

## 常见问题

### Q1: 用户无法登录？

**检查清单**:

```bash
# 1. 检查插件是否启用
bundle exec rails runner "puts SiteSetting.tai_hu_auth_enabled"

# 2. 检查 token key 是否配置
bundle exec rails runner "puts SiteSetting.tai_hu_token_key.present?"

# 3. 查看日志
tail -f log/production.log | grep "太湖\|Tai"

# 4. 测试 token 解密
bundle exec rails runner "
  token = 'YOUR_TOKEN_HERE'
  payload = DiscourseTaiHuAuth::TaiHuIdentityDecoder.decode(token)
  puts payload.inspect
"
```

### Q2: 用户被创建但无法登录？

可能原因：
1. 用户未激活 → 设置 `tai_hu_auto_activate_user=true`
2. 用户被禁用 → 检查用户状态
3. Email 验证未通过 → 启用自动激活

### Q3: Token 过期怎么办？

Token 有效期由太湖服务器控制。插件：
- 允许3分钟时钟偏差
- 过期 token 会被拒绝
- 日志会记录过期时间

### Q4: 如何批量导入现有用户？

```ruby
# 批量添加 StaffId 映射
User.where("email LIKE '%@tencent.com'").find_each do |user|
  login_name = user.email.split('@').first
  staff_id = "YOUR_STAFF_ID_MAPPING[login_name]"
  
  if staff_id
    user.custom_fields["tai_hu_staff_id"] = staff_id
    user.save_custom_fields
    puts "Updated #{user.username}: #{staff_id}"
  end
end
```

## 性能考虑

### 缓存

插件不缓存 token 解密结果，因为：
- Token 有短期过期时间
- 每次请求都需要验证最新状态
- 避免安全风险

### 并发控制

使用分布式锁防止重复创建用户：

```ruby
DistributedMutex.synchronize("tai_hu_user_#{staff_id}") do
  # 创建用户
end
```

### 性能指标

- Token 解密: ~5ms
- 用户查找: ~2ms
- 用户创建: ~50ms（首次）
- 总计: ~10-60ms（取决于是否需要创建用户）

## 监控和日志

### 关键日志

```bash
# 成功登录
"太湖认证自动登录成功: username (id: 123)"

# Token 验证失败
"太湖认证 token 无效，不跳过 CSRF 检查: token expired"

# 用户创建
"太湖认证: 创建新用户 username (StaffId: 12345)"

# 错误
"太湖认证自动登录时发生错误: ..."
```

### 监控指标

建议监控：
1. 登录成功率
2. 用户创建数量
3. Token 验证失败次数
4. 响应时间

## 升级和维护

### 升级 Discourse

插件独立于 Discourse 核心，升级 Discourse 不影响插件功能。

### 插件更新

```bash
cd /var/discourse/plugins/discourse-tai-hu-auth
git pull
cd /var/discourse
./launcher rebuild app
```

### 数据备份

重要数据：
- 用户 `custom_fields["tai_hu_staff_id"]`
- 配置 `SiteSetting.tai_hu_*`

常规备份已包含这些数据。

## 开发和测试

### 本地开发

```bash
# 启动开发服务器
bin/rails s

# 运行测试
bundle exec rspec plugins/discourse-tai-hu-auth/spec

# 查看日志
tail -f log/development.log | grep "太湖"
```

### 测试脚本

```ruby
# test_token_decode.rb
require_relative "config/environment"

token = "YOUR_TEST_TOKEN"
payload = DiscourseTaiHuAuth::TaiHuIdentityDecoder.decode(token)

puts "Token 解密结果:"
puts JSON.pretty_generate(payload)
```

## 技术支持

如遇问题：

1. 查看日志: `/var/discourse/shared/standalone/log/rails/`
2. 检查配置: `bundle exec rails runner "puts SiteSetting.tai_hu_*"`
3. 测试解密: 使用上面的测试脚本
4. 联系团队: 云产品一部

## 附录

### 完整配置示例

```bash
# /etc/discourse/discourse.conf

# 太湖认证配置
DISCOURSE_TAI_HU_AUTH_ENABLED=true
DISCOURSE_TAI_HU_TOKEN_KEY="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
DISCOURSE_TAI_HU_AUTO_CREATE_USER=true
DISCOURSE_TAI_HU_EMAIL_DOMAIN="tencent.com"
DISCOURSE_TAI_HU_AUTO_ACTIVATE_USER=true

# 其他 Discourse 配置
DISCOURSE_HOSTNAME="your-forum.example.com"
DISCOURSE_DEVELOPER_EMAILS="admin@tencent.com"
DISCOURSE_SMTP_ADDRESS="smtp.example.com"
# ...
```

### Token 格式参考

```json
{
  "LoginName": "xiongyesu",
  "StaffId": "231825",
  "ChineseName": "苏雄业",
  "DeptId": "22989",
  "DeptName": "云产品一部",
  "Expiration": "2024-02-02T12:00:00Z"
}
```
