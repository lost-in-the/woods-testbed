# frozen_string_literal: true

# Opt-in, filesystem-local clone benchmark; generated data is always temporary.
# WOODS_CLONE_BASELINE=/path/to/baseline WOODS_CLONE_CANDIDATE=/path/to/fix \
# WOODS_CLONE_BENCH_DIR=/persistent/filesystem ruby scripts/tools/woods_payload_clone_bench.rb
# Optional: WOODS_CLONE_REPS=7, WOODS_CLONE_SOURCE=/existing/payload (read-only).
# Reports component timings only, not end-to-end extraction or tail latency.
require 'benchmark'
require 'fileutils'
require 'json'
require 'open3'
require 'rbconfig'
require 'tmpdir'
require 'digest'

if ARGV.first == '--sample'
  _, code_root, source, target = ARGV
  require File.join(code_root, 'lib/woods/payload_store')
  require File.join(code_root, 'lib/woods/atomic_file')
  store = Woods::PayloadStore.new(File.dirname(target))
  before = GC.stat(:total_allocated_objects)
  seconds = Benchmark.realtime { store.clone(source, target) }
  allocations = GC.stat(:total_allocated_objects) - before
  files = Dir.glob(File.join(source, '**', '*'), File::FNM_DOTMATCH).select { |path| File.file?(path) }
  relative = files.map { |path| path.delete_prefix("#{source}/") }.sort
  copied = Dir.glob(File.join(target, '**', '*'), File::FNM_DOTMATCH).select { |path| File.file?(path) }
  raise 'file inventory differs' unless copied.map { |path| path.delete_prefix("#{target}/") }.sort == relative

  linked = 0
  relative.each do |name|
    original, cloned = [source, target].map { |root| File.join(root, name) }
    raise "content differs: #{name}" unless Digest::SHA256.file(original).digest == Digest::SHA256.file(cloned).digest
    original_stat, cloned_stat = [original, cloned].map { |path| File.stat(path) }
    linked += 1 if [original_stat.dev, original_stat.ino] == [cloned_stat.dev, cloned_stat.ino]
  end
  unless relative.empty?
    original = File.join(source, relative.first)
    original_bytes = File.binread(original)
    Woods::AtomicFile.write(File.join(target, relative.first), 'replacement', durable: false)
    raise 'replacement changed previous payload' unless File.binread(original) == original_bytes
  end
  puts JSON.generate(seconds: seconds, allocations: allocations, files: files.length,
                     hardlinked: linked, copied: files.length - linked)
  exit
end

roots = {
  baseline: File.expand_path(ENV.fetch('WOODS_CLONE_BASELINE')),
  candidate: File.expand_path(ENV.fetch('WOODS_CLONE_CANDIDATE'))
}
reps = Integer(ENV.fetch('WOODS_CLONE_REPS', '7'))
raise 'WOODS_CLONE_REPS must be positive' unless reps.positive?
parent = File.expand_path(ENV.fetch('WOODS_CLONE_BENCH_DIR'))
results = roots.transform_values { [] }
Dir.mktmpdir('woods-clone-bench-', parent) do |working|
  source = ENV['WOODS_CLONE_SOURCE'] && File.expand_path(ENV['WOODS_CLONE_SOURCE'])
  unless source
    source = File.join(working, 'source')
    35.times do |type|
      directory = File.join(source, "type-#{type}")
      FileUtils.mkdir_p(directory)
      240.times { |i| File.write(File.join(directory, "unit-#{i}.json"), '{"source":"example"}') }
    end
  end
  raise 'source must be a directory' unless File.directory?(source)

  reps.times do |iteration|
    roots.to_a.rotate(iteration % 2).each do |label, code_root|
      target = File.join(working, 'target')
      FileUtils.rm_rf(target)
      out, err, status = Open3.capture3(RbConfig.ruby, __FILE__, '--sample', code_root, source, target)
      raise "#{label} failed: #{err}" unless status.success?

      results.fetch(label) << JSON.parse(out)
    end
  end
end
puts JSON.pretty_generate(ruby: RUBY_VERSION, filesystem_path: parent, code_roots: roots,
                          reps: reps, samples: results,
                          caveat: 'component timings; no claim about whole-app latency or p95')
