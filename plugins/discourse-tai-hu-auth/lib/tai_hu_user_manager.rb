# frozen_string_literal: true

module DiscourseTaiHuAuth
  # 太湖身份认证用户管理
  # 负责根据太湖 token payload 查找或创建用户
  class TaiHuUserManager
    attr_reader :payload

    def initialize(payload)
      @payload = payload
    end

    # 查找或创建用户
    # @param ip_address [String] 用户 IP 地址
    # @return [User, nil] 用户对象，失败返回 nil
    def lookup_or_create_user(ip_address = nil)
      return nil if payload["_error"].present?

      login_name = payload["LoginName"]
      staff_id = payload["StaffId"]
      chinese_name = payload["ChineseName"]

      # 必须有 LoginName
      if login_name.blank?
        Rails.logger.error("太湖认证缺少 LoginName")
        return nil
      end

      Rails.logger.info("太湖认证: 开始查找/创建用户 #{login_name} (StaffId: #{staff_id})")

      # 使用分布式锁防止并发创建
      external_id = staff_id || login_name
      result = DistributedMutex.synchronize("tai_hu_user_#{external_id}") do
        lookup_or_create_user_unsafe(login_name, staff_id, chinese_name, ip_address)
      end

      if result.nil?
        Rails.logger.warn("太湖认证: 用户查找/创建返回 nil (LoginName: #{login_name})")
      end

      result
    rescue StandardError => e
      Rails.logger.error(
        "太湖用户查找/创建失败: #{e.class} - #{e.message}\n#{e.backtrace.first(5).join("\n")}",
      )
      nil
    end

    private

    def lookup_or_create_user_unsafe(login_name, staff_id, chinese_name, ip_address)
      # 构造 email
      email = "#{login_name}@#{SiteSetting.tai_hu_email_domain}"

      Rails.logger.debug("太湖认证: 查找用户 - email: #{email}, login_name: #{login_name}, staff_id: #{staff_id}")

      # 优先使用 email 查找
      user = User.find_by_email(email)

      # 如果没有找到，尝试使用 username 查找
      user ||= User.find_by_username(login_name)

      # 如果还没找到，尝试从 custom_fields 中查找（使用 StaffId）
      if user.nil? && staff_id.present?
        user_ids =
          UserCustomField
            .where(name: "tai_hu_staff_id", value: staff_id.to_s)
            .pluck(:user_id)
            .uniq
        user = User.find_by(id: user_ids.first) if user_ids.present?
      end

      # 如果还是没找到，创建新用户
      if user.nil?
        unless SiteSetting.tai_hu_auto_create_user
          Rails.logger.warn("太湖认证: 用户不存在且自动创建已禁用 (LoginName: #{login_name})")
          return nil
        end

        Rails.logger.info("太湖认证: 准备创建新用户 #{login_name}")
        user = create_user(login_name, staff_id, chinese_name, email, ip_address)
        if user
          Rails.logger.info("太湖认证: 创建新用户 #{user.username} (StaffId: #{staff_id})")
        else
          Rails.logger.error("太湖认证: 创建用户失败 (LoginName: #{login_name})")
          return nil
        end
      else
        # 更新用户的太湖信息
        update_user_tai_hu_info(user, staff_id, chinese_name)
        Rails.logger.info(
          "太湖认证: 找到已有用户 #{user.username} (id: #{user.id}, StaffId: #{staff_id})",
        )
      end

      # 确保用户是激活的
      if user.staged?
        user.unstage!
        Rails.logger.info("太湖认证: 取消用户暂存状态 #{user.username}")
      end

      # 激活用户（跳过邮箱验证）
      if !user.active? && SiteSetting.tai_hu_auto_activate_user
        user.active = true
        user.save!
        user.set_automatic_groups
        Rails.logger.info("太湖认证: 自动激活用户 #{user.username}")
      end

      user
    end

    def create_user(login_name, staff_id, chinese_name, email, ip_address)
      # 生成用户名（确保唯一）
      username = generate_unique_username(login_name)

      # 使用中文名作为 name，如果没有则使用 login_name
      name = chinese_name.presence || login_name

      user_params = {
        username: username,
        name: name,
        email: email,
        password: SecureRandom.hex(32), # 生成随机密码
        ip_address: ip_address,
        registration_ip_address: ip_address,
        active: SiteSetting.tai_hu_auto_activate_user,
      }

      user = User.new(user_params)

      # 保存用户
      begin
        user.save!

        # 保存 StaffId 到 custom_fields
        if staff_id.present?
          user.custom_fields["tai_hu_staff_id"] = staff_id.to_s
          user.save_custom_fields
        end

        # 如果需要审核用户，自动批准
        if SiteSetting.must_approve_users?
          ReviewableUser.set_approved_fields!(user, Discourse.system_user)
        end

        # 设置自动组
        user.set_automatic_groups if user.active?

        Rails.logger.info("太湖认证: 成功创建用户 #{username} (email: #{email})")
        user
      rescue ActiveRecord::RecordInvalid => e
        Rails.logger.error(
          "太湖认证: 用户创建失败 - #{e.message}\n" + "  Params: #{user_params.inspect}\n" +
            "  Errors: #{user.errors.full_messages.join(', ')}",
        )
        nil
      end
    end

    def update_user_tai_hu_info(user, staff_id, chinese_name)
      changed = false

      # 更新 StaffId
      if staff_id.present? && user.custom_fields["tai_hu_staff_id"] != staff_id.to_s
        user.custom_fields["tai_hu_staff_id"] = staff_id.to_s
        changed = true
      end

      # 更新中文名（可选）
      if chinese_name.present? && user.name != chinese_name
        # 只在用户名为空或者与 username 相同时才更新
        if user.name.blank? || user.name == user.username
          user.name = chinese_name
          changed = true
        end
      end

      if changed
        user.save_custom_fields
        user.save! if user.name_changed?
        Rails.logger.debug("太湖认证: 更新用户信息 #{user.username}")
      end
    end

    def generate_unique_username(base_username)
      # 清理用户名（移除特殊字符）
      username = base_username.gsub(/[^a-zA-Z0-9_]/, "")

      # 确保不为空
      username = "user#{SecureRandom.hex(4)}" if username.blank?

      # 确保唯一
      return username unless User.username_exists?(username)

      # 如果已存在，添加数字后缀
      (1..100).each do |i|
        candidate = "#{username}#{i}"
        return candidate unless User.username_exists?(candidate)
      end

      # 如果还是不行，使用随机后缀
      "#{username}_#{SecureRandom.hex(4)}"
    end
  end
end
