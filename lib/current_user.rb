# frozen_string_literal: true

module CurrentUser
  def self.has_auth_cookie?(env)
    Discourse.current_user_provider.new(env).has_auth_cookie?
  end

  def self.lookup_from_env(env)
    Discourse.current_user_provider.new(env).current_user
  end

  # can be used to pretend current user does no exist, for CSRF attacks
  def clear_current_user
    @current_user_provider = Discourse.current_user_provider.new({})
  end

  def log_on_user(user, opts = {})
    # ===== 太湖调试日志 =====
    begin
      if request&.headers && request.headers["HTTP_X_TAI_IDENTITY"].present?
        Rails.logger.info("[DEBUG-MODULE] log_on_user 被调用, user=#{user&.id rescue 'error'}")
        Rails.logger.info("[DEBUG-MODULE] @current_user_provider 已存在=#{@current_user_provider.present? rescue false}")
      end
    rescue => e
      Rails.logger.debug("[DEBUG-MODULE] 日志异常: #{e.message}")
    end
    # ===== 太湖调试日志结束 =====
    
    current_user_provider.log_on_user(user, session, cookies, opts)
    user.logged_in
    
    # ===== 太湖调试日志 =====
    begin
      if request&.headers && request.headers["HTTP_X_TAI_IDENTITY"].present?
        Rails.logger.info("[DEBUG-MODULE] log_on_user 完成")
      end
    rescue => e
      Rails.logger.debug("[DEBUG-MODULE] 日志异常: #{e.message}")
    end
    # ===== 太湖调试日志结束 =====
  end

  def log_off_user
    current_user_provider.log_off_user(session, cookies)
  end

  def start_impersonating_user(user)
    current_user_provider.start_impersonating_user(user)
  end

  def stop_impersonating_user
    current_user_provider.stop_impersonating_user
  end

  def is_api?
    current_user_provider.is_api?
  end

  def is_user_api?
    current_user_provider.is_user_api?
  end

  def current_user
    # ===== 太湖调试日志 =====
    begin
      if request&.headers && request.headers["HTTP_X_TAI_IDENTITY"].present?
        Rails.logger.info("[DEBUG-MODULE] current_user 被调用 (CurrentUser module)")
        Rails.logger.info("[DEBUG-MODULE] @current_user_provider 已存在=#{@current_user_provider.present? rescue false}")
      end
    rescue => e
      Rails.logger.debug("[DEBUG-MODULE] 日志异常: #{e.message}")
    end
    # ===== 太湖调试日志结束 =====
    
    result = current_user_provider.current_user
    
    # ===== 太湖调试日志 =====
    begin
      if request&.headers && request.headers["HTTP_X_TAI_IDENTITY"].present?
        Rails.logger.info("[DEBUG-MODULE] current_user 返回=#{result&.id rescue 'error'}")
      end
    rescue => e
      Rails.logger.debug("[DEBUG-MODULE] 日志异常: #{e.message}")
    end
    # ===== 太湖调试日志结束 =====
    
    result
  end

  def refresh_session(user)
    current_user_provider.refresh_session(user, session, cookies)
  end

  private

  def current_user_provider
    @current_user_provider ||= Discourse.current_user_provider.new(request.env)
  end
end
