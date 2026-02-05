# frozen_string_literal: true

module DiscourseTaiHuAuth
  # 太湖身份认证 JWE 解密工具
  # 用于解密 x-tai-identity header 中的 JWE token
  class TaiHuIdentityDecoder
    # 解密 x-tai-identity header
    # @param authorization_header [String] JWE token
    # @param token_key [String] 解密密钥（从 SiteSetting 获取）
    # @return [Hash] 解密后的 payload
    def self.decode(authorization_header, token_key = nil)
      require "json/jwt"

      token_key ||= SiteSetting.tai_hu_token_key

      begin
        # 创建 JWK 密钥
        jwk = JSON::JWK.new(token_key)

        # 步骤 1: 解密 JWE，得到内部的内容
        jwe = JSON::JWT.decode(authorization_header, jwk)

        # 步骤 2: 获取解密后的 plain text
        plain_text = jwe.instance_variable_get(:@plain_text)

        # 步骤 3: 解析 payload
        payload =
          if plain_text.is_a?(String)
            # 检查是否是 JWT 格式 (以 eyJ 开头且包含点号)
            if plain_text.start_with?("eyJ") && plain_text.include?(".")
              # 是 JWT，需要解码
              inner_jwt = JSON::JWT.decode(plain_text, :skip_verification)
              inner_jwt.to_h
            else
              # 直接是 JSON 字符串，解析即可
              JSON.parse(plain_text)
            end
          else
            # 不是字符串，可能已经是对象了
            plain_text.respond_to?(:to_h) ? plain_text.to_h : plain_text
          end

        Rails.logger.debug("太湖 token 解密成功: #{payload.inspect}")

        # 验证 token 是否过期
        if payload["Expiration"]
          begin
            expiration_time = Time.parse(payload["Expiration"])
            time_diff = Time.now.utc - expiration_time

            # 增加 3 分钟缓冲，避免服务器时间差异
            if time_diff > 180 # 3 minutes
              payload["_error"] = "token expired"
              payload["_expired_seconds"] = time_diff.to_i
              Rails.logger.warn("太湖 token 已过期: #{time_diff.to_i} 秒")
            end
          rescue => e
            payload["_warning"] = "解析过期时间失败: #{e.message}"
          end
        else
          payload["_warning"] = "未找到 token 有效期字段"
        end

        payload
      rescue JSON::JWT::Exception => e
        Rails.logger.error("太湖身份认证解密失败 (JSON::JWT): #{e.class} - #{e.message}")
        { "_error" => "解密 JWE token 失败: #{e.message}" }
      rescue JSON::ParserError => e
        Rails.logger.error("太湖身份认证 JSON 解析失败: #{e.message}")
        { "_error" => "JSON 解析失败: #{e.message}" }
      rescue StandardError => e
        Rails.logger.error(
          "太湖身份认证解析失败: #{e.class} - #{e.message}\n#{e.backtrace.first(3).join("\n")}",
        )
        { "_error" => "解析失败: #{e.class} - #{e.message}" }
      end
    end

    # 格式化打印 payload
    def self.format_payload(payload)
      return "解密失败: #{payload['_error']}" if payload["_error"]

      lines = ["太湖身份信息:"]
      payload.each do |key, value|
        next if key.start_with?("_") # 跳过内部字段
        lines << "  #{key}: #{value}"
      end

      lines << "  ⚠️  #{payload['_warning']}" if payload["_warning"]

      lines.join("\n")
    end
  end
end
