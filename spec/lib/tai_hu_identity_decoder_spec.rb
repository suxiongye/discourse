# frozen_string_literal: true

require "tai_hu_identity_decoder"

RSpec.describe TaiHuIdentityDecoder do
  let(:token_key) { "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" }

  describe ".decode" do
    context "with invalid JWE token" do
      it "returns error hash when token format is invalid" do
        result = described_class.decode("invalid_token", token_key)

        expect(result).to be_a(Hash)
        expect(result["_error"]).to be_present
        expect(result["_error"]).to include("解密").or include("失败")
      end

      it "returns error hash when token is empty" do
        result = described_class.decode("", token_key)

        expect(result).to be_a(Hash)
        expect(result["_error"]).to be_present
      end

      it "returns error hash when token is nil" do
        result = described_class.decode(nil, token_key)

        expect(result).to be_a(Hash)
        expect(result["_error"]).to be_present
      end
    end

    context "with wrong decryption key" do
      it "returns error hash" do
        # 创建一个简单的 token
        require "json/jwt"
        jwk = JSON::JWK.new(token_key, kid: "test")
        jwt = JSON::JWT.new({ "test" => "data" })
        jwe = jwt.encrypt(jwk, :dir, :A256GCM)
        encrypted_token = jwe.to_s

        wrong_key = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
        result = described_class.decode(encrypted_token, wrong_key)

        expect(result).to be_a(Hash)
        expect(result["_error"]).to be_present
      end
    end

    context "with valid token" do
      it "successfully decodes token" do
        require "json/jwt"
        payload = {
          "RTXAccount" => "testuser",
          "Expiration" => (Time.now.utc + 3600).iso8601,
        }

        jwk = JSON::JWK.new(token_key, kid: "test")
        jwt = JSON::JWT.new(payload)
        jwe = jwt.encrypt(jwk, :dir, :A256GCM)
        encrypted_token = jwe.to_s

        result = described_class.decode(encrypted_token, token_key)

        expect(result).to be_a(Hash)
        expect(result["_error"]).to be_nil
      end
    end
  end

  describe ".format_payload" do
    context "with successful decode result" do
      let(:payload) do
        {
          "RTXAccount" => "zhangsan",
          "StaffName" => "张三",
          "Department" => "技术部",
        }
      end

      it "formats payload as readable string" do
        result = described_class.format_payload(payload)

        expect(result).to include("太湖身份信息:")
        expect(result).to include("RTXAccount: zhangsan")
        expect(result).to include("StaffName: 张三")
        expect(result).to include("Department: 技术部")
      end

      it "includes warning in formatted output" do
        payload_with_warning = payload.merge("_warning" => "test warning")
        result = described_class.format_payload(payload_with_warning)

        expect(result).to include("RTXAccount: zhangsan")
        expect(result).to include("⚠️  test warning")
      end
    end

    context "with error result" do
      let(:error_payload) { { "_error" => "解密失败: invalid token" } }

      it "shows error message" do
        result = described_class.format_payload(error_payload)

        expect(result).to eq("解密失败: 解密失败: invalid token")
      end
    end
  end

  describe "DEFAULT_KEY" do
    it "has a default key with correct length" do
      expect(TaiHuIdentityDecoder::DEFAULT_KEY).to be_a(String)
      expect(TaiHuIdentityDecoder::DEFAULT_KEY.length).to eq(32)
    end
  end
end
