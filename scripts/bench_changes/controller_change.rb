# frozen_string_literal: true

# Benchmark change: add an action to a kernel controller.
#
# Controllers are a ROUTE_CONSUMER type — they embed the route table in their
# unit metadata — so this is the natural counterpart to the routes scenario:
# same unit type, but touched directly rather than reached by fan-out.
{
  name: 'controller',
  description: 'add an action to ArticlesController (includes a concern, uses Rails.cache)',
  path: 'app/controllers/articles_controller.rb',
  apply: lambda { |source|
    source.sub(
      "  private\n",
      "  def bench_probe\n    head :no_content\n  end\n\n  private\n"
    )
  }
}
