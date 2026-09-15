# frozen_string_literal: true

require_relative '../support/woods_phase_logger'

logger = PhaseLogger.new
logger.info('[Woods] [profile] payload sync in 2.0s')
logger.info('[Woods] [profile] publish in 3.0s')
logger.info('[Woods] [profile] payload prune in 5.0s')
logger.info('[Woods] [profile total] full in 11.0s')
phases = logger.phase_durations(0, 11)
raise phases.inspect unless phases == {
  'payload sync' => 2000.0, 'publish' => 3000.0, 'payload prune' => 5000.0,
  'unaccounted (including rounding)' => 1000.0
}
raise 'total lost' unless logger.profile_total_ms == 11000.0
raise 'raw evidence lost' unless logger.profile_lines.length == 4

legacy = PhaseLogger.new
legacy.info('[Woods] [profile] payload sync in 2.0s')
legacy.info('[Woods] [profile] publish in 5.0s')
raise 'legacy double count' unless legacy.phase_durations(0, 6)['publish'] == 3000.0

missing = PhaseLogger.new
missing.info('[Woods] Writing output...')
raise 'invented timing from marker' unless missing.phase_durations(0, 1).empty?
puts 'PASS explicit, legacy, total, raw evidence and missing phase accounting'
