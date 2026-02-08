#!/usr/bin/env ruby
# frozen_string_literal: true

# 重建主题样式缓存脚本
#
# 用法:
#   bin/rails runner scripts/rebuild_theme_cache.rb              # 重建所有已启用主题
#   bin/rails runner scripts/rebuild_theme_cache.rb 127          # 重建指定主题 ID
#   bin/rails runner scripts/rebuild_theme_cache.rb --all        # 重建所有主题（含禁用的）

puts "=" * 60
puts "Discourse 主题样式缓存重建工具"
puts "=" * 60
puts

# 解析参数
arg = ARGV.first
themes =
  if arg == "--all"
    puts "模式: 重建所有主题"
    Theme.all
  elsif arg.present? && arg.match?(/\A\d+\z/)
    theme_id = arg.to_i
    puts "模式: 重建指定主题 (ID: #{theme_id})"
    Theme.where(id: theme_id)
  else
    puts "模式: 重建所有已启用主题"
    Theme.where(enabled: true)
  end

themes = themes.to_a
if themes.empty?
  puts "未找到符合条件的主题"
  exit 0
end

puts "找到 #{themes.size} 个主题:"
themes.each do |t|
  type = t.component? ? "组件" : "主题"
  puts "  [#{t.id}] #{t.name} (#{type}, enabled: #{t.enabled})"
end
puts

# 第 1 步: 清除 StylesheetCache
puts "[1/5] 清除 StylesheetCache..."
theme_ids = themes.map(&:id)
deleted = StylesheetCache.where(theme_id: theme_ids).delete_all
puts "  已删除 #{deleted} 条缓存记录"

# 第 2 步: 重置 theme_fields 的 value_baked
puts "[2/5] 重置 theme_fields 编译标记..."
themes.each do |theme|
  count = theme.theme_fields.update_all(value_baked: nil)
  puts "  [#{theme.id}] #{theme.name}: 重置 #{count} 个字段"

  # 同时处理子组件
  theme.child_themes.each do |child|
    child_count = child.theme_fields.update_all(value_baked: nil)
    puts "    └─ [#{child.id}] #{child.name}: 重置 #{child_count} 个字段" if child_count > 0
  end
end

# 第 3 步: 清除文件系统缓存
puts "[3/5] 清除文件系统样式缓存..."
cache_path = "#{Rails.root}/tmp/stylesheet-cache"
if Dir.exist?(cache_path)
  count = Dir.glob("#{cache_path}/*").size
  FileUtils.rm_rf(Dir.glob("#{cache_path}/*"))
  puts "  已清除 #{count} 个缓存文件"
else
  puts "  缓存目录不存在，跳过"
end

# 第 4 步: 清除 DistributedCache
puts "[4/5] 清除 DistributedCache..."
Stylesheet::Manager.cache.clear
Theme.expire_site_cache!
puts "  已清除"

# 第 5 步: 触发重新编译
puts "[5/5] 触发主题重新编译..."
themes.reject(&:component?).each do |theme|
  begin
    print "  [#{theme.id}] #{theme.name}..."
    theme.theme_fields.each(&:ensure_baked!)
    theme.save!
    cached = StylesheetCache.where(theme_id: theme.id).count
    puts " 完成 (缓存: #{cached} 条)"
  rescue => e
    puts " 失败!"
    puts "    错误: #{e.message}"
  end
end

puts
puts "=" * 60
puts "重建完成!"
puts
puts "StylesheetCache 统计:"
theme_ids.each do |tid|
  records = StylesheetCache.where(theme_id: tid).pluck(:target, :created_at)
  theme_name = themes.find { |t| t.id == tid }&.name
  if records.any?
    puts "  [#{tid}] #{theme_name}: #{records.size} 条缓存"
    records.each { |target, created_at| puts "    - #{target} (#{created_at})" }
  else
    next if themes.find { |t| t.id == tid }&.component?
    puts "  [#{tid}] #{theme_name}: 无缓存 (将在首次请求时编译)"
  end
end
puts
puts "请刷新浏览器 (Ctrl+Shift+R) 查看效果"
puts "=" * 60
