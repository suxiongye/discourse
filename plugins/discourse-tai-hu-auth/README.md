# Discourse Tai Hu Auth Plugin

腾讯太湖（IOA）身份认证插件，用于 Discourse 论坛。

## 功能特性

- ✅ 解密 `x-tai-identity` header 中的 JWE token
- ✅ 自动查找或创建用户
- ✅ 自动登录（建立 session）
- ✅ 跳过 CSRF 验证（太湖 token 作为身份凭证）
- ✅ 跳过邮箱验证（可配置）
- ✅ 支持用户信息同步（StaffId、中文名等）

## 安装

此插件已内置在项目中，位于 `plugins/discourse-tai-hu-auth/` 目录。

## 配置

### 1. 启用插件

在 Discourse 管理后台：

1. 进入 **Settings → Plugins**
2. 找到 **tai_hu_auth_enabled**
3. 勾选启用

### 2. 配置密钥

设置太湖 JWE token 解密密钥：

```bash
# 方式1: 通过环境变量
export TAI_HU_TOKEN_KEY="your-32-byte-secret-key"

# 方式2: 通过 Discourse 管理后台
# Settings → Plugins → tai_hu_token_key
```

### 3. 其他配置

| 配置项 | 默认值 | 说明 |
|--------|--------|------|
| `tai_hu_auth_enabled` | `false` | 是否启用太湖认证 |
| `tai_hu_token_key` | `aaaaa...` | JWE token 解密密钥（32字节） |
| `tai_hu_auto_create_user` | `true` | 是否自动创建不存在的用户 |
| `tai_hu_email_domain` | `tencent.com` | 自动创建用户时的邮箱域名 |
| `tai_hu_auto_activate_user` | `true` | 自动激活新用户（跳过邮箱验证） |

## 工作原理

### 1. 请求流程

```
用户请求 → Nginx/反向代理（添加 x-tai-identity header）
         → Discourse（插件解密 header）
         → 查找/创建用户
         → 自动登录
         → 返回响应
```

### 2. 用户匹配规则

插件按以下顺序查找用户：

1. **Email 匹配**: `{LoginName}@{tai_hu_email_domain}`
2. **Username 匹配**: 使用 `LoginName`
3. **StaffId 匹配**: 通过 `custom_fields` 中的 `tai_hu_staff_id`

如果都找不到且 `tai_hu_auto_create_user=true`，则自动创建新用户。

### 3. 新用户创建

创建用户时：
- **Username**: 使用 `LoginName`（确保唯一）
- **Email**: `{LoginName}@{tai_hu_email_domain}`
- **Name**: 使用 `ChineseName`（如有）
- **Password**: 随机生成（用户通过太湖认证，不需要密码）
- **Active**: 根据 `tai_hu_auto_activate_user` 配置
- **Custom Fields**: 保存 `tai_hu_staff_id`

## Token 格式

太湖 token 是一个 JWE (JSON Web Encryption) token，解密后包含：

```json
{
  "LoginName": "xiongyesu",
  "StaffId": "231825",
  "ChineseName": "苏雄业",
  "DeptId": "22989",
  "DeptName": "云产品一部",
  "Expiration": "2024-01-01T12:00:00Z"
}
```

## 安全特性

1. **Token 验证**: 验证签名、过期时间（3分钟缓冲）
2. **CSRF 保护**: 有效的太湖 token 跳过 CSRF 验证
3. **并发控制**: 使用分布式锁防止重复创建用户
4. **日志记录**: 完整的审计日志

## 调试

查看日志：

```bash
# 开发环境
tail -f log/development.log | grep "太湖"

# 生产环境
tail -f log/production.log | grep "太湖"
```

日志示例：

```
太湖认证 token 验证成功，跳过 CSRF 检查: LoginName=xiongyesu
太湖认证: 找到已有用户 xiongyesu (id: 123, StaffId: 231825)
太湖认证自动登录成功: xiongyesu (id: 123)
```

## 故障排查

### 问题1: Token 解密失败

**错误**: `解密 JWE token 失败`

**解决**:
1. 检查 `tai_hu_token_key` 是否正确（必须是32字节）
2. 检查 token 格式是否正确
3. 检查 header 名称是否为 `x-tai-identity`

### 问题2: 用户未自动登录

**解决**:
1. 确认 `tai_hu_auth_enabled=true`
2. 检查日志查看是否有错误
3. 确认 token 未过期
4. 检查用户是否被禁用

### 问题3: 无法创建用户

**解决**:
1. 确认 `tai_hu_auto_create_user=true`
2. 检查邮箱域名配置
3. 查看日志中的详细错误信息

## 开发

### 运行测试

```bash
bundle exec rspec plugins/discourse-tai-hu-auth/spec
```

### 代码结构

```
plugins/discourse-tai-hu-auth/
├── plugin.rb                          # 插件入口
├── config/
│   ├── settings.yml                   # 配置定义
│   └── locales/                       # 国际化
├── lib/
│   ├── tai_hu_identity_decoder.rb    # Token 解密
│   ├── tai_hu_user_manager.rb        # 用户管理
│   └── tai_hu_authenticator.rb       # 认证器（预留）
└── spec/                              # 测试文件
```

## 版本历史

### 1.0.0 (2024-02-02)
- ✨ 初始版本
- ✅ JWE token 解密
- ✅ 自动用户创建
- ✅ 自动登录
- ✅ CSRF 跳过

## 许可证

内部使用

## 支持

如有问题，请联系：云产品一部
