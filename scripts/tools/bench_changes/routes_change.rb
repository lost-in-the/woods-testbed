# frozen_string_literal: true

# Benchmark change: add a route.
#
# One of the two fan-out scenarios, and the one behind #2's finding 16. A routes
# change triggers a wholesale re-run of WHOLE_APP_EXTRACTORS[:routes] AND of
# every ROUTE_CONSUMER_EXTRACTORS type — controllers, mailers, components, view
# components, view templates — because those embed the route table and the
# dependency graph cannot express that relationship (a route unit depends *on*
# its controller, so walking dependents from config/routes.rb never reaches it).
#
# This is the scenario whose replaced-unit percentage is the number the gem's
# docs currently extrapolate.
{
  name: 'routes',
  description: 'add a route (fans out to every ROUTE_CONSUMER type)',
  path: 'config/routes.rb',
  apply: lambda { |source|
    source.sub(
      "  root \"articles#index\"",
      "  get \"bench_probe\", to: \"articles#index\"\n  root \"articles#index\""
    )
  }
}
