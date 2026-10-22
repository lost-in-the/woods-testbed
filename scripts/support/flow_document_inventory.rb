# frozen_string_literal: true

require 'json'

# Distinguishes entry-point documents from the indexes published beside them.
# Content snapshots retain auxiliary indexes for full/incremental comparison.
module FlowDocumentInventory
  INDEX_FILES = %w[flow_index.json by_unit.json].freeze

  def self.documents(directory)
    json_files(directory).map { |file| File.basename(file) } - INDEX_FILES
  end

  def self.artifact_map(directory)
    json_files(directory).reject { |file| File.basename(file) == 'flow_index.json' }.to_h do |file|
      content = JSON.parse(File.read(file))
      if File.basename(file) == 'by_unit.json'
        raise 'by_unit.json must be an object' unless content.is_a?(Hash)
      else
        content.delete('generated_at')
        content = yield(content) if block_given?
      end
      ["flows/#{File.basename(file)}", content]
    end
  end

  def self.json_files(directory)
    Dir[File.join(directory.to_s, '*.json')].sort
  end
  private_class_method :json_files
end
