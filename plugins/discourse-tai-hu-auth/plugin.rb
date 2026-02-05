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

  # 扩展 ApplicationController 的 mixin
  module ApplicationControllerExtension
    # 覆盖 use_crawler_layout? 方法
    # 当有太湖认证 header 时，强制使用正常布局（不使用爬虫布局）
    # 原因：太湖网关转发的请求可能没有正确传递 User-Agent，导致被误识别为爬虫
    def use_crawler_layout?
      # 如果有太湖认证 header，强制使用正常布局
      return false if request.headers["HTTP_X_TAI_IDENTITY"].present?

      # 否则使用原来的逻辑
      @use_crawler_layout ||=
        request.user_agent && (request.media_type.blank? || request.media_type.include?("html")) &&
          !%w[json rss].include?(params[:format]) &&
          (
            has_escaped_fragment? || params.key?("print") || show_browser_update? ||
              CrawlerDetection.crawler?(request.user_agent, request.headers["HTTP_VIA"])
          )
    end

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
      payload["_error"].blank?
    rescue StandardError => e
      Rails.logger.error("太湖认证: 检查 token 异常 - #{e.class} - #{e.message}")
      false
    end

    # 太湖认证自动登录
    def auto_login_with_tai_hu_token
      # 检查是否有太湖 header
      tai_identity = request.headers["HTTP_X_TAI_IDENTITY"]
      return if tai_identity.blank?

      # 重要：先检查是否已有有效的 Cookie 登录态
      existing_user = check_existing_session_without_caching

      if existing_user.present?
        # 已有会话，设置 env 缓存
        request.env[Auth::DefaultCurrentUserProvider::CURRENT_USER_KEY] = existing_user
        redirect_to "/" if request.path == "/login" && !request.xhr? && !request.format&.json?
        return
      end

      # 没有有效会话，XHR/JSON 请求跳过登录
      return if request.xhr? || request.format&.json?

      # 解密 token 获取用户信息
      payload = DiscourseTaiHuAuth::TaiHuIdentityDecoder.decode(tai_identity)
      return if payload["_error"].present?

      # 查找或创建用户
      user_manager = DiscourseTaiHuAuth::TaiHuUserManager.new(payload)
      user = user_manager.lookup_or_create_user(request.remote_ip)
      return unless user

      # 使用 Discourse 原生的 log_on_user 方法登录
      log_on_user(user)

      # 确保 env 缓存正确
      request.env[Auth::DefaultCurrentUserProvider::CURRENT_USER_KEY] = user

      # 登录后重定向
      redirect_to "/" if request.path == "/login"
    rescue StandardError => e
      Rails.logger.error("太湖认证异常: #{e.class.name} - #{e.message}")
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
    rescue StandardError
      nil
    end
  end

  # 扩展 AnonymousCache::Helper 的 mixin
  module AnonymousCacheHelperExtension
    def cacheable?
      # 如果有 taihu header，不使用匿名缓存
      return false if @env["HTTP_X_TAI_IDENTITY"].present?

      super
    end
  end
end

after_initialize do
  require_relative "lib/tai_hu_identity_decoder"
  require_relative "lib/tai_hu_user_manager"
  require_relative "lib/tai_hu_authenticator"

  # 使用 prepend 扩展 ApplicationController
  # 问题背景:
  # 太湖网关转发的请求可能没有正确传递 User-Agent，导致被误识别为爬虫
  # 需要覆盖 use_crawler_layout? 和 handle_unverified_request 方法
  reloadable_patch do |plugin|
    ApplicationController.prepend(DiscourseTaiHuAuth::ApplicationControllerExtension)
  end

  # 注册 before_action
  # 必须在 set_current_user_for_logs 之前执行！
  # 因为 set_current_user_for_logs 会调用 current_user，触发缓存
  # 如果在它之后执行，即使我们登录成功，缓存的 nil 也不会被更新
  ApplicationController.prepend_before_action :auto_login_with_tai_hu_token,
                                              if: -> { SiteSetting.tai_hu_auth_enabled }

  # 扩展 AnonymousCache::Helper，让带有 x-tai-identity header 的请求跳过匿名缓存
  #
  # 问题背景:
  # 当用户清理浏览器 cookie 后，请求没有 _t cookie，AnonymousCache 中间件会认为是匿名用户
  # 如果命中缓存，会直接返回缓存的匿名页面，请求不会到达 Controller
  # 导致 taihu 的 auto_login_with_tai_hu_token 永远不会执行，用户看到未登录状态
  if defined?(Middleware::AnonymousCache::Helper)
    Middleware::AnonymousCache::Helper.prepend(DiscourseTaiHuAuth::AnonymousCacheHelperExtension)
  end
end
