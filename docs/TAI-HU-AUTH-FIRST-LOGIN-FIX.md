# 太湖认证首次登录页面状态不同步问题分析与修复

## 问题现象

1. **首次登录后页面不显示用户信息**：用户通过太湖认证首次访问时，后端已经成功登录（Cookie 已设置），但页面上不显示用户头像、用户名等信息
2. **需要手动刷新**：用户必须手动刷新浏览器（F5）才能看到已登录状态
3. **点击交互跳转登录页**：不刷新的情况下，点击"回复"等需要登录的操作，会被前端路由跳转到 `/login`

## 问题根因分析（深入）

### Discourse 的请求处理流程

Discourse 是一个 **SPA（单页应用）**，首次访问时服务器会：
1. 在 `before_action` 中处理认证
2. 渲染 HTML 并预加载 JSON 数据（包含 `currentUser` 信息）
3. 前端 Ember.js 使用预加载的数据初始化应用状态

### before_action 执行顺序

```ruby
# ApplicationController 中的 before_action 顺序：
before_action :redirect_to_login_if_required  # 第 46 行
# ...
before_action :preload_json                   # 第 49 行
before_action :initialize_application_layout_preloader  # 第 50 行
```

我们的插件：
```ruby
before_action :auto_login_with_tai_hu_token,
              if: -> { SiteSetting.tai_hu_auth_enabled },
              before: :redirect_to_login_if_required  # 在最前面执行
```

### 缓存机制导致的问题

**关键文件：`lib/auth/default_current_user_provider.rb` 第 99-100 行**

```ruby
def current_user
  return @env[CURRENT_USER_KEY] if @env.key?(CURRENT_USER_KEY)  # ← 这里有缓存！
  # ... 查找用户的逻辑
end
```

### 详细执行流程

```
┌─────────────────────────────────────────────────────────────────────────────┐
│ 1. auto_login_with_tai_hu_token 开始                                         │
│    └─ current_user.present? 被调用                                           │
│       └─ current_user_provider.current_user 被调用                           │
│          └─ 此时没有 Cookie，@env[CURRENT_USER_KEY] = nil 被缓存             │
├─────────────────────────────────────────────────────────────────────────────┤
│ 2. 找到太湖身份，查找/创建用户                                                │
├─────────────────────────────────────────────────────────────────────────────┤
│ 3. log_on_user(user) 被调用                                                  │
│    └─ 设置了 _t Cookie ✓                                                     │
│    └─ 但是 @env[CURRENT_USER_KEY] 仍然是 nil ✗                              │
├─────────────────────────────────────────────────────────────────────────────┤
│ 4. initialize_application_layout_preloader 执行                              │
│    └─ 创建 ApplicationLayoutPreloader.new(guardian: guardian, ...)          │
│       └─ guardian 方法被调用                                                  │
│          └─ current_user 被调用                                              │
│             └─ @env.key?(CURRENT_USER_KEY) == true，返回缓存的 nil！         │
│                └─ guardian.authenticated? == false                           │
├─────────────────────────────────────────────────────────────────────────────┤
│ 5. preloaded_data 生成                                                       │
│    └─ if @guardian.authenticated? → false                                    │
│       └─ preload_current_user_data 不被调用！                                │
│          └─ @preloaded["currentUser"] 没有被设置                             │
├─────────────────────────────────────────────────────────────────────────────┤
│ 6. 前端收到 HTML，预加载数据中 currentUser = null                             │
│    └─ 用户看起来是未登录状态                                                  │
│    └─ 但刷新后 Cookie 生效，currentUser 有值                                  │
└─────────────────────────────────────────────────────────────────────────────┘
```

## 修复方案

### 核心修复：更新 env 缓存

在 `log_on_user` 之后，手动更新 `@env[CURRENT_USER_KEY]`：

```ruby
# 在 log_on_user(user) 之后添加：

# 关键修复: 更新 env 中缓存的 current_user
request.env[Auth::DefaultCurrentUserProvider::CURRENT_USER_KEY] = user

# 同时重置 @guardian，让它用新的 current_user 重建
@guardian = nil
```

### 修复原理

| 步骤 | 修复前 | 修复后 |
|------|--------|--------|
| `@env[CURRENT_USER_KEY]` | `nil`（缓存未更新） | `user`（手动更新） |
| `current_user` 返回值 | `nil` | `user` |
| `guardian.authenticated?` | `false` | `true` |
| `preload_current_user_data` | 不调用 | 调用 |
| 前端 `currentUser` | `null` | `{id: 3, username: "xiongyesu", ...}` |

## 代码变更详情

### 文件：`plugins/discourse-tai-hu-auth/plugin.rb`

**变更位置**：`auto_login_with_tai_hu_token` 方法

**新增代码**（在 `log_on_user(user)` 之后）：

```ruby
# 关键修复: 更新 env 中缓存的 current_user
#
# 问题根因:
# 1. 上面的 current_user.present? 检查触发了 current_user_provider.current_user
# 2. 此时还没有 Cookie，所以 @env[CURRENT_USER_KEY] 被设置为 nil
# 3. log_on_user 设置了 Cookie，但没有更新 @env[CURRENT_USER_KEY]
# 4. 后续的 initialize_application_layout_preloader 调用 guardian -> current_user
# 5. current_user 返回缓存的 nil（因为 @env.key?(CURRENT_USER_KEY) 为 true）
# 6. 导致 preload_current_user_data 不被调用，前端收到 currentUser = null
#
# 解决方案: 手动更新 @env 中的缓存
request.env[Auth::DefaultCurrentUserProvider::CURRENT_USER_KEY] = user

# 同时重置 @guardian，让它用新的 current_user 重建
@guardian = nil

Rails.logger.info("太湖认证: 登录成功，已更新 env 缓存，current_user=#{current_user&.username}")
```

## 回滚方案

如果出现问题，可以通过以下方式回滚：

### 方法 1: Git 回滚

```bash
cd /Users/suxiongye/Code/orca/discourse
git checkout HEAD -- plugins/discourse-tai-hu-auth/plugin.rb
```

### 方法 2: 手动回滚

删除 `auto_login_with_tai_hu_token` 方法中 `log_on_user(user)` 后面的所有代码，直到 `else` 行。

## 验证方法

### 日志验证

修复后，首次登录应该看到这样的日志：

```
太湖认证: 开始查找/创建用户 xiongyesu (StaffId: 231825)
太湖认证: 找到已有用户 xiongyesu (id: 3, StaffId: 231825)
太湖认证: 自动登录用户 xiongyesu (id: 3)
太湖认证: 登录成功，已更新 env 缓存，current_user=xiongyesu  ← 新增的日志
```

### 功能验证

1. 清除浏览器 Cookie
2. 访问 https://orcaspace.woa.com/
3. 页面应该直接显示用户头像和用户名，**无需手动刷新**

## 之前失败的修复尝试

### 尝试 1: 只重置 `@guardian` 和 `@application_layout_preloader`

```ruby
@guardian = nil
@application_layout_preloader = nil
```

**失败原因**：
- `@application_layout_preloader = nil` 导致后续 `store_preloaded` 调用报错 `NoMethodError: undefined method 'store_preloaded' for nil:NilClass`
- 只重置 `@guardian` 没用，因为 `current_user` 仍然返回缓存的 `nil`

### 尝试 2: 前端检测 Cookie 自动刷新

```javascript
// 检测有 _t cookie 但没有 currentUser 时自动刷新
if (hasTCookie && !currentUser) {
  window.location.reload();
}
```

**失败原因**：
- `_t` Cookie 是 `HttpOnly` 的，JavaScript 无法读取
- 无法在前端判断"后端已登录但前端数据不同步"的情况

## 相关文件

- `lib/auth/default_current_user_provider.rb` - `current_user` 缓存逻辑
- `lib/current_user.rb` - `current_user_provider` 缓存逻辑
- `app/controllers/application_controller.rb` - `before_action` 执行顺序
- `lib/application_layout_preloader.rb` - 预加载数据生成逻辑

## 历史记录

- **2026-02-03**: 初次分析并修复
