# frozen_string_literal: true

# Benchmark change: add a column to db/schema.rb.
#
# The second fan-out scenario, and a different *kind* of fan-out from routes:
# ReloadPolicy classifies db/schema.rb as :restart, not :reload, because the
# schema cache is boot-captured and Rails' reloader does not rebuild it. So for
# the daemon this is the escalation path, and for a plain incremental run it
# touches every model whose table changed.
#
# Measured here for its incremental cost; the daemon's restart behaviour is
# rung 13's business.
{
  name: 'schema',
  description: 'edit schema.rb without migrating the live database (invalidation probe)',
  path: 'db/schema.rb',
  apply: lambda { |source|
    source.sub(/(create_table "articles"[^\n]*\n)/, '\\1    t.string "bench_probe"' + "\n")
  }
}
