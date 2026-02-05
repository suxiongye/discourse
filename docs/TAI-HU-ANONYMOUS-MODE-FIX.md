# 太湖认证与匿名模式兼容问题分析与修复

## 问题现象

用户通过太湖认证登录后，点击"切换到匿名模式"无法正常切换。

## 网络架构

```
用户浏览器 (HTTPS) 
    ↓
太湖智能网关 (卸载 SSL，转为 HTTP)
    ↓
腾讯云 CLB (80 端口)
    ↓
业务服务 (Docker, port 3000)
```

## 问题根因分析

### 核心问题：Cookie Secure 标志与 HTTP 内部通信冲突

#### Cookie 设置代码

**Auth Cookie** (`lib/auth/default_current_user_provider.rb`):
```ruby
cookie_jar.encrypted[TOKEN_COOKIE] = {
  value: data,
  httponly: true,
  secure: SiteSetting.force_https,  # force_https=true → Cookie 只在 HTTPS 发送
  expires: expires,
  same_site: same_site,
}
```

**Session Cookie** (`lib/action_dispatch/session/discourse_cookie_store.rb`):
```ruby
def set_cookie(request, session_id, cookie)
  if Hash === cookie
    cookie[:secure] = true if SiteSetting.force_https  # 同样的问题！
    # ...
  end
  cookie_jar(request)[@key] = cookie
end
```

#### 问题分析

1. `force_https = true` → 所有 Cookie 都设置 `Secure` 标志
2. 太湖网关卸载 SSL 后，内部通信是 HTTP
3. Cookie 在 HTTP 响应中可能无法正确传递到浏览器
4. 即使用 Session 存储匿名状态，Session 也是 Cookie 存储，同样有问题

## 解决方案：使用 Redis 存储匿名状态

**核心思路**：完全绕过 Cookie，使用 Redis 存储匿名模式状态。

### 实现原理

```
┌─────────────────────────────────────────────────────────────────────┐
│ Redis 存储结构                                                       │
│ Key: tai_hu_anon_mode:{master_user_id}                              │
│ Value: {anonymous_user_id}                                          │
│ TTL: 使用管理员配置的 anonymous_account_duration_minutes            │
│      默认 10080 分钟（7 天）                                         │
└─────────────────────────────────────────────────────────────────────┘
```

### 配置说明

Redis TTL 使用 Discourse 的站点设置 `anonymous_account_duration_minutes`：

| 设置项 | 默认值 | 说明 |
|-------|--------|------|
| `anonymous_account_duration_minutes` | 10080 | 匿名账户有效期（分钟），默认 7 天 |

管理员可以在 **管理后台 → 设置 → 用户** 中修改此值。

```ruby
# 代码中动态获取配置
def anonymous_mode_ttl
  SiteSetting.anonymous_account_duration_minutes * 60  # 转换为秒
end
```

### 工作流程

```
┌─────────────────────────────────────────────────────────────────────┐
│ 1. 用户点击"切换到匿名模式"                                          │
│    POST /u/toggle-anon                                               │
└────────────────────────────────┬────────────────────────────────────┘
                                 ↓
┌─────────────────────────────────────────────────────────────────────┐
│ 2. toggle_anon 执行                                                  │
│    - 切换到 shadow_user                                              │
│    - track_anonymous_mode_toggle 设置 Redis:                         │
│      Redis.setex("tai_hu_anon_mode:123", 7天, "456")                 │
│      (master_user_id=123, anon_user_id=456)                         │
└────────────────────────────────┬────────────────────────────────────┘
                                 ↓
┌─────────────────────────────────────────────────────────────────────┐
│ 3. window.location.reload() 页面刷新                                 │
│    - 新请求携带太湖 token                                            │
│    - auto_login_with_tai_hu_token 执行                               │
└────────────────────────────────┬────────────────────────────────────┘
                                 ↓
┌─────────────────────────────────────────────────────────────────────┐
│ 4. 从 Token 获取主用户信息                                           │
│    - 解密 Token 得到 LoginName                                       │
│    - 查找主用户 master_user_id = 123                                 │
└────────────────────────────────┬────────────────────────────────────┘
                                 ↓
┌─────────────────────────────────────────────────────────────────────┐
│ 5. 检查 Redis 中的匿名状态                                           │
│    - Redis.get("tai_hu_anon_mode:123") → "456"                      │
│    - 发现用户处于匿名模式                                            │
└────────────────────────────────┬────────────────────────────────────┘
                                 ↓
┌─────────────────────────────────────────────────────────────────────┐
│ 6. 直接登录为匿名用户                                                │
│    - log_on_user(anon_user_456)                                     │
│    - 保持匿名状态！✅                                                │
└─────────────────────────────────────────────────────────────────────┘
```

### 关键代码

#### Redis 操作封装

```ruby
module ::DiscourseTaiHuAuth
  ANONYMOUS_MODE_REDIS_PREFIX = "tai_hu_anon_mode:"
  
  class << self
    # 动态获取 TTL，使用管理员配置的 anonymous_account_duration_minutes
    def anonymous_mode_ttl
      SiteSetting.anonymous_account_duration_minutes * 60  # 转换为秒
    end
    
    # 获取匿名用户 ID
    def get_anonymous_user_id(master_user_id)
      key = "#{ANONYMOUS_MODE_REDIS_PREFIX}#{master_user_id}"
      Discourse.redis.get(key)&.to_i
    end
    
    # 设置匿名模式
    def set_anonymous_mode(master_user_id, anonymous_user_id)
      key = "#{ANONYMOUS_MODE_REDIS_PREFIX}#{master_user_id}"
      ttl = anonymous_mode_ttl
      Discourse.redis.setex(key, ttl, anonymous_user_id.to_s)
    end
    
    # 清除匿名模式
    def clear_anonymous_mode(master_user_id)
      key = "#{ANONYMOUS_MODE_REDIS_PREFIX}#{master_user_id}"
      Discourse.redis.del(key)
    end
  end
end
```

#### auto_login_with_tai_hu_token 中检查 Redis

```ruby
def auto_login_with_tai_hu_token
  # 解密 token 获取主用户信息
  payload = DiscourseTaiHuAuth::TaiHuIdentityDecoder.decode(tai_identity)
  
  # 从 Redis 检查匿名模式状态
  master_user = DiscourseTaiHuAuth.find_master_user_from_payload(payload)
  if master_user
    anon_user_id = DiscourseTaiHuAuth.get_anonymous_user_id(master_user.id)
    if anon_user_id
      anon_user = User.find_by(id: anon_user_id)
      if anon_user&.anonymous?
        # 直接登录为匿名用户，保持匿名状态
        log_on_user(anon_user)
        return
      end
    end
  end
  
  # ... 正常登录流程
end
```

#### toggle_anon 中更新 Redis

```ruby
def track_anonymous_mode_toggle
  master_user_id = current_user&.anonymous? ? 
    AnonymousShadowCreator.get_master(current_user)&.id : 
    current_user&.id
  
  yield  # 执行原方法
  
  new_user = User.find_by(id: session[:current_user_id])
  
  if new_user&.anonymous?
    # 切换到匿名模式，设置 Redis
    DiscourseTaiHuAuth.set_anonymous_mode(master_user_id, new_user.id)
  else
    # 切换回正常模式，清除 Redis
    DiscourseTaiHuAuth.clear_anonymous_mode(master_user_id)
  end
end
```

## 为什么 Redis 方案有效

| 方案 | 存储位置 | 问题 |
|------|---------|------|
| Auth Cookie (`_t`) | 浏览器 Cookie | Secure 标志在 HTTP 中无效 |
| Session Cookie (`_forum_session`) | 浏览器 Cookie | 同样有 Secure 标志问题 |
| **Redis** | **服务端** | **完全绕过 Cookie 问题！** |

**Redis 方案的优势**：
1. 匿名状态存储在服务端，不依赖浏览器 Cookie
2. 通过太湖 Token 可以可靠地识别主用户
3. 即使 Cookie 完全失效，也能正确恢复匿名状态

## 部署和验证

### 部署步骤

1. 更新插件代码
2. 重启 Discourse 服务
3. 测试匿名模式切换

### 日志验证

```bash
# 查看相关日志
kubectl logs -f <pod-name> -n orca | grep "太湖认证"
```

期望看到的日志：
```
太湖认证: toggle_anon 开始, was_anonymous=false, master_user_id=123
太湖认证: toggle_anon 完成, is_now_anonymous=true, new_user_id=456
太湖认证: Redis 设置匿名模式 master=123 -> anon=456

# 刷新页面后
太湖认证: Redis 标记为匿名模式，使用匿名用户 (master=123, anon=456)
太湖认证: 匿名模式重定向以刷新页面状态
```

### Redis 验证

```bash
# 进入 Rails console
kubectl exec -it <pod-name> -n orca -- bin/rails c

# 检查 Redis 中的匿名状态
Discourse.redis.keys("tai_hu_anon_mode:*")
Discourse.redis.get("tai_hu_anon_mode:123")  # 返回匿名用户 ID
```

## 注意事项

1. **TTL 配置**：匿名模式有效期使用管理员配置的 `anonymous_account_duration_minutes`（默认 7 天）
2. **配置修改立即生效**：
   - Redis 存储的是「关系 + 开始时间」，不依赖 Redis TTL
   - 每次访问时用当前配置的有效期判断是否过期
   - 管理员修改 `anonymous_account_duration_minutes` 后**立即生效**
   - 例如：管理员将有效期从 7 天改为 1 小时，已运行超过 1 小时的匿名会话会**立即失效**
3. **Redis 数据结构**：`{ "anon_id": 匿名用户ID, "started_at": 时间戳 }`
4. **用户切换**：如果用户从另一个设备登录，不会影响匿名状态（因为是按主用户 ID 存储）
5. **清理**：正常退出匿名模式会手动删除 Redis key
