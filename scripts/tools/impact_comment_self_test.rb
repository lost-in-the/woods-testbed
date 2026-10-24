# frozen_string_literal: true

# Exercise the impact comment builder without Rails, an index or GitHub.
require_relative 'impact_comment'

failures = []
check = lambda do |name, condition|
  failures << name unless condition
  puts "#{condition ? 'ok  ' : 'FAIL'} #{name}"
end

id = 'a' * 64
report = { 'changed' => [
  { 'identifier' => 'User', 'type' => 'model', 'status' => 'modified' },
  { 'identifier' => 'users/show.html.erb', 'type' => 'view_template', 'status' => 'modified' },
  { 'identifier' => 'users/old.html.erb', 'type' => 'view_template', 'status' => 'removed' }
] }

check.call('focus prefers changed templates', ImpactComment.focus(report) == ['users/show.html.erb'])
check.call('focus falls back to every changed unit',
           ImpactComment.focus('changed' => [report['changed'].first]) == ['User'])
check.call('focus never names a removed unit',
           ImpactComment.focus('changed' => [report['changed'].last]).empty?)
check.call('focus is bounded', ImpactComment.focus('changed' => Array.new(30) do |i|
  { 'identifier' => "U#{i}", 'type' => 'model', 'status' => 'added' }
end).size == ImpactComment::FOCUS_LIMIT)

url = ImpactComment.focus_url('http://localhost:3010/woods/', id, ['users/show.html.erb'])
check.call('focus URL opens the saved report on the Changed lens',
           url == "http://localhost:3010/woods/impacts/#{id}?lens=changed&focus=users%2Fshow.html.erb")
check.call('focus URL without focus keeps the lens',
           ImpactComment.focus_url('http://x/woods', id, []) == "http://x/woods/impacts/#{id}?lens=changed")
begin
  ImpactComment.focus_url('http://x/woods', '../../etc', [])
  check.call('focus URL refuses a non-ID', false)
rescue ArgumentError
  check.call('focus URL refuses a non-ID', true)
end

body = ImpactComment.body(markdown: "# Impact\n\nWoods' text\n", report: report, id: id,
                          map_url: 'http://localhost:3010/woods', artifact: 'impact-index-7',
                          run_url: 'https://github.com/o/r/actions/runs/1')
check.call('body starts with the marker', body.start_with?(ImpactComment::MARKER))
check.call("body carries Woods' Markdown unchanged", body.include?("# Impact\n\nWoods' text"))
check.call('body links the focus URL', body.include?("(#{url})"))
check.call('body names the artifact', body.include?('`impact-index-7`') && body.include?('actions/runs/1'))

long = ImpactComment.body(markdown: 'x' * 70_000, report: report, id: id, map_url: 'http://x/woods')
check.call('body stays under the comment limit', long.length < 65_536 && long.include?('truncated'))

abort "#{failures.size} failure(s): #{failures.join('; ')}" unless failures.empty?
puts 'impact comment self-tests passed'
