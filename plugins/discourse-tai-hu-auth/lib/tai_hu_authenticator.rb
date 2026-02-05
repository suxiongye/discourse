# frozen_string_literal: true

module DiscourseTaiHuAuth
  # 太湖认证器（预留，用于未来可能的 OAuth 集成）
  class TaiHuAuthenticator < ::Auth::ManagedAuthenticator
    def name
      "tai_hu"
    end

    def enabled?
      SiteSetting.tai_hu_auth_enabled
    end

    # 当前使用 header token 方式，不需要 OAuth 流程
    # 此类预留用于未来可能的 OAuth 集成
  end
end
