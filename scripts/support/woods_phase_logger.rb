# frozen_string_literal: true

require 'logger'

# Consume Woods' explicit WOODS_PROFILE durations, never infer timings from
# progress messages whose order and content can change between releases.
class PhaseLogger < Logger
  attr_reader :profile_total_ms, :profile_lines

  def initialize
    super($stdout)
    self.level = Logger::INFO
    @phases = Hash.new(0.0)
    @profile_lines = []
  end

  def add(_severity, message = nil, progname = nil)
    text = (message || progname).to_s
    if (match = text.match(/\A\[Woods\] \[profile\] (.+) in ([\d.]+)s\z/))
      @phases[match[1]] += Float(match[2]) * 1000
      @profile_lines << text
    elsif (match = text.match(/\A\[Woods\] \[profile total\] (.+) in ([\d.]+)s\z/))
      @profile_total_ms = Float(match[2]) * 1000
      @profile_lines << text
    end
    true
  end

  def phase_durations(started_at, finished_at)
    return {} if @phases.empty?

    phases = @phases.dup
    # Before disjoint profiling, publish included sync and retention. Keep
    # legacy data useful without counting the explicitly logged sync twice.
    if profile_total_ms.nil? && phases.key?('publish') && phases.key?('payload sync')
      phases['publish'] -= phases['payload sync']
    end
    # May be slightly negative because each logged phase rounds to 10ms.
    phases['unaccounted (including rounding)'] = ((finished_at - started_at) * 1000) - phases.values.sum
    phases.transform_values { |value| value.round(1) }
  end
end
