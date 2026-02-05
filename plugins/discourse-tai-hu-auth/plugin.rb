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
      # 在 redirect_to_login_if_required 之前执行，自动登录用户
      # 使用 Discourse 原生的 Cookie 机制
      before_action :auto_login_with_tai_hu_token,
                    if: -> { SiteSetting.tai_hu_auth_enabled },
                    before: :redirect_to_login_if_required

      def auto_login_with_tai_hu_token
        # 调试：打印 User-Agent 和爬虫检测结果
        Rails.logger.info("太湖认证: [DEBUG] UA=#{request.user_agent}, use_crawler_layout?=#{use_crawler_layout?}")
        
        # 如果已经登录，跳过
        if current_user.present?
          # 特殊处理：如果用户已登录但访问的是 /login 页面，直接跳转首页
          if request.path == "/login"
            Rails.logger.info("太湖认证: 用户已登录，从 /login 跳转到首页")
            redirect_to "/"
          end
          return
        end

        tai_identity = request.headers["HTTP_X_TAI_IDENTITY"]
        return if tai_identity.blank?

        # 解密 token 获取用户信息
        payload = DiscourseTaiHuAuth::TaiHuIdentityDecoder.decode(tai_identity)
        if payload["_error"].present?
          Rails.logger.warn("太湖认证: Token解密失败 - #{payload['_error']}")
          return
        end

        # 查找或创建用户
        user_manager = DiscourseTaiHuAuth::TaiHuUserManager.new(payload)
        user = user_manager.lookup_or_create_user(request.remote_ip)

        if user
          Rails.logger.info("太湖认证: 自动登录用户 #{payload['LoginName']} (id: #{user.id})")
          
          # 调试：记录 log_on_user 之前的状态
          Rails.logger.info("太湖认证: [DEBUG] 登录前 env key存在=#{request.env.key?(Auth::DefaultCurrentUserProvider::CURRENT_USER_KEY)}, 值=#{request.env[Auth::DefaultCurrentUserProvider::CURRENT_USER_KEY]&.id}")
          
          # 使用 Discourse 原生的 log_on_user 方法登录
          # 这会正确设置 Cookie，在 HTTPS 下工作正常
          log_on_user(user)
          
          # 调试：记录 log_on_user 之后的状态
          Rails.logger.info("太湖认证: [DEBUG] log_on_user后 env key存在=#{request.env.key?(Auth::DefaultCurrentUserProvider::CURRENT_USER_KEY)}, 值=#{request.env[Auth::DefaultCurrentUserProvider::CURRENT_USER_KEY]&.id}")
          
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
          
          # 调试：验证 current_user 和 guardian
          Rails.logger.info("太湖认证: [DEBUG] 最终 current_user=#{current_user&.username}, guardian.user=#{guardian.user&.username}, guardian.authenticated?=#{guardian.authenticated?}")
          
          # 对于 XHR/AJAX 请求，需要特殊处理
          # 因为前端的 currentUser service 不会因为 AJAX 请求而更新
          # 需要告知前端刷新页面或重新加载用户信息
          if request.xhr?
            Rails.logger.info("太湖认证: XHR 请求中首次登录，设置 refresh header")
            response.set_header("X-Discourse-Refresh", "true")
          end
          
          # 如果是在 /login 页面登录成功，跳转到首页
          if request.path == "/login"
            Rails.logger.info("太湖认证: 从 /login 页面跳转到首页")
            redirect_to "/"
          end
        else
          Rails.logger.error("太湖认证: 用户创建失败 - LoginName=#{payload['LoginName']}")
        end
      rescue => e
        Rails.logger.error("太湖认证异常: #{e.class.name} - #{e.message}")
        Rails.logger.error(e.backtrace.first(10).join("\n"))
      end
    end
  end
end
