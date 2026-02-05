#!/usr/bin/env ruby
# frozen_string_literal: true

# 测试太湖认证插件

puts "=" * 80
puts "太湖认证插件测试"
puts "=" * 80
puts

# 检查插件是否加载
plugin = Discourse.plugins.find { |p| p.name == "discourse-tai-hu-auth" }
if plugin
  puts "✅ 插件已加载: #{plugin.name}"
  puts "   状态: #{plugin.enabled? ? '启用' : '禁用'}"
else
  puts "❌ 插件未找到"
  exit 1
end

puts

# 检查 SiteSetting
puts "配置检查:"
puts "  tai_hu_auth_enabled: #{SiteSetting.tai_hu_auth_enabled}"
puts "  tai_hu_auto_create_user: #{SiteSetting.tai_hu_auto_create_user}"
puts "  tai_hu_email_domain: #{SiteSetting.tai_hu_email_domain}"
puts "  tai_hu_auto_activate_user: #{SiteSetting.tai_hu_auto_activate_user}"
puts

# 测试 Token 解密
puts "测试 Token 解密:"
test_token =
  "eyJhbGciOiJkaXIiLCJlbmMiOiJBMjU2R0NNIiwia2lkIjoieGZueGxzIn0..9dG5-hL0PkOTQfFY.W75S79c9WV36wRqVtUKN4_eoUEJjmMB7wPqgBVzMgZp9W3wX1Z4b8JF7GtVW_kCCX3OcLxYf1eKGnO3dVYH5T_QbhEY_4Jlj2u8Y5xF3F1f3DqDpzW3X4fVd3gY5Y.4F8X1Y5X3F7Y8X2Y5X3F7Y8X"

payload = DiscourseTaiHuAuth::TaiHuIdentityDecoder.decode(test_token)

if payload["_error"]
  puts "  ❌ 解密失败: #{payload['_error']}"
else
  puts "  ✅ 解密成功!"
  puts "     LoginName: #{payload['LoginName']}"
  puts "     StaffId: #{payload['StaffId']}"
  puts "     ChineseName: #{payload['ChineseName']}"
end

puts
puts "=" * 80
puts "测试完成"
puts "=" * 80
