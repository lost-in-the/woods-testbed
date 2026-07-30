module WoodsTestbed
  # Autoloaded from lib/ via config.autoload_lib — which is what makes this a
  # `lib` unit rather than dead code.
  class Slug
    def self.call(value)
      value.to_s.downcase.gsub(/[^a-z0-9]+/, "-").delete_prefix("-").delete_suffix("-")
    end
  end
end
