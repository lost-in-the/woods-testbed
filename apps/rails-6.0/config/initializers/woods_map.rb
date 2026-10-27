# frozen_string_literal: true

# Woods Map configuration for the testbed Rails app (woods-testbed#38).
#
# The engine reads the published index that `bin/rails woods:extract` writes
# under tmp/woods and nothing else. The token comes from WOODS_MAP_TOKEN,
# which docker-compose.yml sets to a fixed test-only value: a browser on the
# host reaches the container over the bridge network, so loopback-only
# access would refuse it. Never copy that token, or this initializer, into a
# real app.
WoodsMap.configure do |config|
  config.index_dir = Rails.root.join("tmp/woods")
  config.token = ENV["WOODS_MAP_TOKEN"]
end
