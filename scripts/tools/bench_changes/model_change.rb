# frozen_string_literal: true

# Benchmark change: add a scope to a kernel model.
#
# Fixed and committed rather than edited ad hoc, so a number measured six months
# ago is comparable to one measured today — that comparability is the whole
# reason #2 asks for these to be scripted.
#
# Semantically meaningful, not whitespace churn: a new scope changes the unit's
# metadata and source, so the downstream fan-out is real.
{
  name: 'model',
  description: 'add a scope to Article (a kernel model with a concern and 3 associations)',
  path: 'app/models/article.rb',
  apply: lambda { |source|
    source.sub(
      "  scope :published, -> { where.not(published_at: nil) }",
      "  scope :published, -> { where.not(published_at: nil) }\n" \
      "  scope :bench_recent, -> { where(\"published_at > ?\", 7.days.ago) }"
    )
  }
}
