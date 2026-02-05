# frozen_string_literal: true

# name: discourse-tai-hu-auth
# about: Tencent Tai Hu (IOA) authentication plugin for Discourse
# version: 2.0.0
# authors: Tencent
# url: https://github.com/your-org/discourse-tai-hu-auth

enabled_site_setting :tai_hu_auth_enabled

# 注册样式表 - 隐藏 logout 按钮
register_asset "stylesheets/tai-hu-auth.scss"

module ::DiscourseTaiHuAuth
  PLUGIN_NAME = "discourse-tai-hu-auth"
end

after_initialize do
  require_relative "lib/tai_hu_identity_decoder"
  require_relative "lib/tai_hu_user_manager"
  require_relative "lib/tai_hu_authenticator"

  # 扩展 AnonymousCache::Helper，让带有 x-tai-identity header 的请求跳过匿名缓存
  #
  # 问题背景:
  # 当用户清理浏览器 cookie 后，请求没有 _t cookie，AnonymousCache 中间件会认为是匿名用户
  # 如果命中缓存，会直接返回缓存的匿名页面，请求不会到达 Controller
  # 导致 taihu 的 auto_login_with_tai_hu_token 永远不会执行，用户看到未登录状态
  #
  # 解决方案:
  # 使用 prepend 扩展 cacheable? 方法，当请求带有 x-tai-identity header 时返回 false
  # 这样请求会正常到达 Controller，触发 taihu 自动登录
  if defined?(Middleware::AnonymousCache::Helper)
    module ::DiscourseTaiHuAuth::TaiHuAnonymousCacheExtension
      def cacheable?
        # 如果有 taihu header，不使用匿名缓存
        return false if @env["HTTP_X_TAI_IDENTITY"].present?

        super
      end
    end
    Middleware::AnonymousCache::Helper.prepend(DiscourseTaiHuAuth::TaiHuAnonymousCacheExtension)
  end

  # 扩展 ApplicationController，添加太湖认证支持
  reloadable_patch do |plugin|
    ApplicationController.class_eval do
      # 覆盖 handle_unverified_request 以支持太湖认证
      def handle_unverified_request
        # API key 和太湖 token 都是 secret，有效时可跳过 CSRF 验证
        unless is_api? || is_user_api? || has_valid_tai_hu_token?
          super
          clear_current_user
          render plain: "[\"BAD CSRF\"]", status: :forbidden
        end
      end

      # 检查是否有有效的太湖身份认证 token
      def has_valid_tai_hu_token?
        return false unless SiteSetting.tai_hu_auth_enabled

        tai_identity = request.headers["HTTP_X_TAI_IDENTITY"]
        return false if tai_identity.blank?

        # 尝试解密 token
        payload = DiscourseTaiHuAuth::TaiHuIdentityDecoder.decode(tai_identity)

        # 必须成功解密且没有错误
        if payload["_error"].blank?
          Rails.logger.info(
            "太湖认证 token 验证成功，跳过 CSRF 检查: LoginName=#{payload['LoginName']}",
          )
          true
        else
          Rails.logger.warn("太湖认证 token 无效，不跳过 CSRF 检查: #{payload['_error']}")
          false
        end
      rescue StandardError => e
        Rails.logger.error("检查太湖认证 token 时发生错误: #{e.class} - #{e.message}")
        false
      end

      # 太湖认证自动登录
      # 必须在 set_current_user_for_logs 之前执行！
      # 因为 set_current_user_for_logs 会调用 current_user，触发缓存
      # 如果在它之后执行，即使我们登录成功，缓存的 nil 也不会被更新
      prepend_before_action :auto_login_with_tai_hu_token,
                            if: -> { SiteSetting.tai_hu_auth_enabled }

      # 调试用：在 preload 之后检查状态
      after_action :debug_tai_hu_preload_status,
                   if: -> { SiteSetting.tai_hu_auth_enabled && !request.xhr? && !request.format&.json? }

      def auto_login_with_tai_hu_token
        # 检查是否有太湖 header
        tai_identity = request.headers["HTTP_X_TAI_IDENTITY"]
        
        # 如果没有太湖 header，直接返回（不输出日志）
        if tai_identity.blank?
          return
        end
        
        # 设置调试标记，让其他地方知道这是太湖请求
        RequestStore.store[:tai_hu_debug] = true if defined?(RequestStore)
        
        # ========== 调试信息开始 ==========
        begin
          Rails.logger.info("=" * 60)
          Rails.logger.info("太湖认证: ========== 请求开始 ==========")
          Rails.logger.info("太湖认证: [请求信息] path=#{request.path}, method=#{request.method}")
          Rails.logger.info("太湖认证: [请求类型] xhr=#{request.xhr?}, format=#{request.format}, json=#{request.format&.json?}")
          Rails.logger.info("太湖认证: [env缓存状态] key存在=#{request.env.key?(Auth::DefaultCurrentUserProvider::CURRENT_USER_KEY)}, 值=#{request.env[Auth::DefaultCurrentUserProvider::CURRENT_USER_KEY]&.id}")
          Rails.logger.info("太湖认证: [Header] X-TAI-IDENTITY 存在=#{tai_identity.present?}, 长度=#{tai_identity&.length}")
        rescue => e
          Rails.logger.debug("太湖认证: 日志异常 - #{e.message}")
        end

        # 检查 Cookie 状态
        begin
          Rails.logger.info("太湖认证: [Cookie] 原始 _t cookie=#{request.cookies['_t'].present?}")
        rescue => e
          Rails.logger.debug("太湖认证: Cookie 检查异常 - #{e.message}")
        end
        
        # 重要：先检查是否已有有效的 Cookie 登录态
        existing_user = check_existing_session_without_caching
        Rails.logger.info("太湖认证: [会话检查] existing_user=#{existing_user&.username} (id: #{existing_user&.id})")
        
        if existing_user.present?
          Rails.logger.info("太湖认证: [已有会话] 设置 env 缓存")
          request.env[Auth::DefaultCurrentUserProvider::CURRENT_USER_KEY] = existing_user
          
          if !request.xhr? && !request.format&.json? && request.path == "/login"
            Rails.logger.info("太湖认证: [重定向] 从 /login 跳转到首页")
            redirect_to "/"
          end
          Rails.logger.info("=" * 60)
          return
        end

        # 没有有效会话，需要用太湖 header 登录
        if request.xhr? || request.format&.json?
          Rails.logger.info("太湖认证: [跳过] XHR/JSON 请求但无有效会话")
          Rails.logger.info("=" * 60)
          return
        end

        Rails.logger.info("太湖认证: [开始登录] HTML 请求，开始自动登录流程")

        # 解密 token 获取用户信息
        payload = DiscourseTaiHuAuth::TaiHuIdentityDecoder.decode(tai_identity)
        if payload["_error"].present?
          Rails.logger.warn("太湖认证: [错误] Token解密失败 - #{payload['_error']}")
          Rails.logger.info("=" * 60)
          return
        end
        
        Rails.logger.info("太湖认证: [Token解密成功] LoginName=#{payload['LoginName']}")

        # 查找或创建用户
        user_manager = DiscourseTaiHuAuth::TaiHuUserManager.new(payload)
        user = user_manager.lookup_or_create_user(request.remote_ip)

        unless user
          Rails.logger.error("太湖认证: [错误] 用户创建失败 - LoginName=#{payload['LoginName']}")
          Rails.logger.info("=" * 60)
          return
        end

        Rails.logger.info("太湖认证: [用户] 找到/创建用户 #{user.username} (id: #{user.id})")

        # 使用 Discourse 原生的 log_on_user 方法登录
        Rails.logger.info("太湖认证: [登录] 调用 log_on_user...")
        log_on_user(user)
        Rails.logger.info("太湖认证: [登录] log_on_user 完成")

        # 检查 log_on_user 之后的状态
        Rails.logger.info("太湖认证: [登录后] env key存在=#{request.env.key?(Auth::DefaultCurrentUserProvider::CURRENT_USER_KEY)}, 值=#{request.env[Auth::DefaultCurrentUserProvider::CURRENT_USER_KEY]&.id}")

        # 确保 env 缓存正确
        request.env[Auth::DefaultCurrentUserProvider::CURRENT_USER_KEY] = user
        Rails.logger.info("太湖认证: [手动设置] env[CURRENT_USER_KEY]=#{user.id}")

        # 验证 current_user 方法
        cu = current_user
        Rails.logger.info("太湖认证: [验证] current_user=#{cu&.username} (id: #{cu&.id})")
        
        # 验证 guardian
        g = guardian
        Rails.logger.info("太湖认证: [验证] guardian.user=#{g.user&.username}, authenticated=#{g.authenticated?}")

        if request.path == "/login"
          Rails.logger.info("太湖认证: [重定向] 从 /login 页面跳转到首页")
          redirect_to "/"
        end
        
        Rails.logger.info("太湖认证: ========== 请求结束 ==========")
        Rails.logger.info("=" * 60)
      rescue => e
        Rails.logger.error("太湖认证异常: #{e.class.name} - #{e.message}")
        Rails.logger.error(e.backtrace.first(10).join("\n"))
      end

      # 检查是否有有效的现有会话，不触发 current_user 缓存
      def check_existing_session_without_caching
        # 直接查找 Cookie 中的 token
        auth_cookie = Auth::DefaultCurrentUserProvider.find_v1_auth_cookie(request.env)
        auth_cookie ||= Auth::DefaultCurrentUserProvider.find_v0_auth_cookie(request)

        return nil if auth_cookie.blank?

        # 从 v1 cookie 中获取 token
        token = auth_cookie.is_a?(Hash) ? auth_cookie[:token] : auth_cookie
        return nil if token.blank?

        # 查找对应的 UserAuthToken
        user_token = UserAuthToken.lookup(token, seen: false)
        return nil unless user_token

        # 返回用户
        user_token.user
      rescue => e
        Rails.logger.debug("太湖认证: 检查现有会话失败 - #{e.message}")
        nil
      end

      # 调试用：检查 preload 之后的状态
      def debug_tai_hu_preload_status
        return unless request.headers["HTTP_X_TAI_IDENTITY"].present?
        
        Rails.logger.info("=" * 60)
        Rails.logger.info("太湖认证: ========== AFTER ACTION 检查 ==========")
        Rails.logger.info("太湖认证: [after_action] path=#{request.path}")
        Rails.logger.info("太湖认证: [after_action] current_user=#{current_user&.username} (id: #{current_user&.id})")
        Rails.logger.info("太湖认证: [after_action] guardian.user=#{guardian.user&.username}, authenticated=#{guardian.authenticated?}")
        Rails.logger.info("太湖认证: [after_action] @application_layout_preloader 存在=#{@application_layout_preloader.present?}")
        
        if @application_layout_preloader.present?
          # 检查 preloaded 数据
          preloaded = @application_layout_preloader.instance_variable_get(:@preloaded)
          Rails.logger.info("太湖认证: [after_action] preloaded keys=#{preloaded&.keys}")
          Rails.logger.info("太湖认证: [after_action] currentUser 在 preloaded 中=#{preloaded&.key?('currentUser')}")
          if preloaded&.key?('currentUser')
            # 只打印前100个字符
            cu_json = preloaded['currentUser']
            Rails.logger.info("太湖认证: [after_action] currentUser JSON 前100字符=#{cu_json&.slice(0, 100)}")
          end
        end
        
        # 检查响应中是否有 Set-Cookie
        set_cookie = response.headers['Set-Cookie']
        Rails.logger.info("太湖认证: [after_action] Set-Cookie 存在=#{set_cookie.present?}")
        if set_cookie.present?
          # 检查是否包含 _t cookie
          has_t_cookie = set_cookie.include?('_t=')
          Rails.logger.info("太湖认证: [after_action] _t Cookie 在响应中=#{has_t_cookie}")
        end
        
        Rails.logger.info("太湖认证: ========== AFTER ACTION 结束 ==========")
        Rails.logger.info("=" * 60)
      rescue => e
        Rails.logger.error("太湖认证 debug_tai_hu_preload_status 异常: #{e.message}")
      end
    end
  end
end
