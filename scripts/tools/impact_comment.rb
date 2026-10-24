# frozen_string_literal: true

# Build the pull request's impact comment (woods-map#4, the M4b exit criterion).
#
# The comment body is Woods' own Markdown renderer output (`woods:impact`,
# FORMAT=markdown) followed by one focus link into the Woods Map. This script
# derives nothing about the change: the focus set is read from the saved
# report Woods wrote, and the link opens that saved report by its ID.
#
#   ruby scripts/tools/impact_comment.rb --markdown impact.md --report impact.json \
#     --id <sha256> --map-url http://localhost:3010/woods --artifact impact-index-12
#
# Prints the comment body on stdout. The first line is a hidden marker so the
# workflow updates one comment per pull request instead of adding another.
require 'erb'
require 'json'
require 'optparse'

module ImpactComment
  MARKER = '<!-- woods-impact-comment -->'
  # GitHub refuses comment bodies over 65,536 characters; leave room for the footer.
  MARKDOWN_LIMIT = 60_000
  FOCUS_LIMIT = 10
  # Unit types whose change the M4b criterion highlights first.
  TEMPLATE_TYPES = %w[view_template].freeze
  ID = /\A[0-9a-f]{64}\z/

  module_function

  # @param report [Hash] the saved schema 1 report
  # @return [Array<String>] identifiers to focus: changed templates first, else
  #   every changed unit; never a removed one (it has no current page)
  def focus(report)
    current = Array(report['changed']).reject { |record| record['status'] == 'removed' }
    templates = current.select { |record| TEMPLATE_TYPES.include?(record['type']) }
    (templates.empty? ? current : templates).map { |record| record['identifier'].to_s }
                                            .reject(&:empty?).uniq.first(FOCUS_LIMIT)
  end

  # @param map_url [String] the engine's mount, e.g. http://localhost:3010/woods
  # @param id [String] the saved report ID woods:impact printed
  # @param focus [Array<String>]
  # @return [String]
  def focus_url(map_url, id, focus)
    raise ArgumentError, "not a saved report ID: #{id.inspect}" unless ID.match?(id)

    query = ['lens=changed']
    query << "focus=#{ERB::Util.url_encode(focus.join(','))}" unless focus.empty?
    "#{map_url.to_s.chomp('/')}/impacts/#{id}?#{query.join('&')}"
  end

  # @param markdown [String] Woods' rendered report
  # @param report [Hash] the saved report
  # @param id [String]
  # @param map_url [String]
  # @param artifact [String, nil] the uploaded index artifact's name
  # @param run_url [String, nil] the workflow run, where the artifact lives
  # @return [String] the comment body
  def body(markdown:, report:, id:, map_url:, artifact: nil, run_url: nil)
    focus = focus(report)
    text = markdown.to_s.strip
    text = "#{text[0, MARKDOWN_LIMIT]}\n\n_Report truncated; open it in the map for the rest._" if text.length > MARKDOWN_LIMIT
    [MARKER, text, '---', footer(focus_url(map_url, id, focus), focus, artifact, run_url)].join("\n\n") + "\n"
  end

  def footer(url, focus, artifact, run_url)
    label = focus.empty? ? 'Open this report in Woods Map' : "Open in Woods Map, focused on #{focus.map { |f| "`#{f}`" }.join(', ')}"
    lines = ["**[#{label}](#{url})**"]
    if artifact
      where = run_url ? "[this run](#{run_url})" : 'this run'
      lines << "The link opens saved report `#{url[%r{/impacts/(\h{64})}, 1]}` in a Woods Map that reads this index: " \
               "download the `#{artifact}` artifact from #{where} into `apps/rails-8.0/tmp/woods` and start " \
               '`rails-8.0` (`docker compose up -d rails-8.0`).'
    end
    lines.join("\n\n")
  end
  private_class_method :footer
end

if $PROGRAM_NAME == __FILE__
  options = {}
  OptionParser.new do |parser|
    parser.on('--markdown PATH') { |value| options[:markdown] = value }
    parser.on('--report PATH') { |value| options[:report] = value }
    parser.on('--id ID') { |value| options[:id] = value }
    parser.on('--map-url URL') { |value| options[:map_url] = value }
    parser.on('--artifact NAME') { |value| options[:artifact] = value }
    parser.on('--run-url URL') { |value| options[:run_url] = value }
  end.parse!
  missing = %i[markdown report id map_url].reject { |key| options[key] }
  abort "missing #{missing.map { |key| "--#{key.to_s.tr('_', '-')}" }.join(', ')}" unless missing.empty?

  report = JSON.parse(File.read(options[:report], encoding: 'UTF-8'))
  markdown = File.read(options[:markdown], encoding: 'UTF-8')
  $stdout.write(ImpactComment.body(markdown: markdown, report: report, id: options[:id], map_url: options[:map_url],
                                   artifact: options[:artifact], run_url: options[:run_url]))
end
