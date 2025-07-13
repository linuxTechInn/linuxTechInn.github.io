require 'date'
require 'time'
# 生成文件名
date = Date.today.strftime("%Y-%m-%d")
time = Time.parse(DateTime.now.to_s).localtime("+08:00").strftime("%Y-%m-%d %H:%M:%S %Z")
title = "我的文章"
file_name = "#{date}-#{title}.md"

# 添加 YAML 头信息
yaml_header = <<~YAML
  ---
  layout: post
  title: #{title}
  date: #{time}
  last_modified_at: #{time}
  tags: []
  author: Daniel
  toc: true
  description: 文章描述
  ---
YAML

content = <<~MD
  # My Title
MD

File.write("#{file_name}", yaml_header + content)
