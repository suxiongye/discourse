# frozen_string_literal: true

require "rails_helper"

describe DiscourseTaiHuAuth::TaiHuIdentityDecoder do
  describe ".decode" do
    it "returns error for invalid token" do
      result = DiscourseTaiHuAuth::TaiHuIdentityDecoder.decode("invalid_token")
      expect(result["_error"]).to be_present
    end

    it "returns error for empty token" do
      result = DiscourseTaiHuAuth::TaiHuIdentityDecoder.decode("")
      expect(result["_error"]).to be_present
    end
  end

  describe ".format_payload" do
    it "formats error message" do
      payload = { "_error" => "test error" }
      result = DiscourseTaiHuAuth::TaiHuIdentityDecoder.format_payload(payload)
      expect(result).to include("解密失败")
      expect(result).to include("test error")
    end

    it "formats successful payload" do
      payload = { "LoginName" => "testuser", "StaffId" => "12345", "_warning" => "test warning" }
      result = DiscourseTaiHuAuth::TaiHuIdentityDecoder.format_payload(payload)
      expect(result).to include("LoginName")
      expect(result).to include("testuser")
      expect(result).to include("StaffId")
      expect(result).to include("12345")
      expect(result).to include("⚠️")
      expect(result).to include("test warning")
    end
  end
end
