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
  description: 'add a column to db/schema.rb (boot-captured; ReloadPolicy says :restart)',
  path: 'db/schema.rb',
  apply: lambda { |source|
    source.sub(
      '    t.datetime "archived_at"' + "\n" + '    t.datetime "created_at", null: false' + "\n" +
      '    t.datetime "updated_at", null: false' + "\n" +
      '    t.index ["author_id"], name: "index_articles_on_author_id"',
      '    t.datetime "archived_at"' + "\n" + '    t.string "bench_probe"' + "\n" +
      '    t.datetime "created_at", null: false' + "\n" +
      '    t.datetime "updated_at", null: false' + "\n" +
      '    t.index ["author_id"], name: "index_articles_on_author_id"'
    )
  }
}
