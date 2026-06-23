# woods-testbed — rails-6.0

Minimal **Rails 6.0** app on **Ruby 3.0**, the supported floor for the Woods gem
(`railties >= 6.0`, woods #135). Deliberately backend-only — no asset pipeline or
JS bundler — so the Rails 6.0 boot stays small while still exercising the
version-sensitive extraction path (models, controllers, jobs, mailers, routes).

Bring it up (from the testbed root):

```bash
docker compose up -d rails-6.0           # http://localhost:3012
docker exec woods-testbed-rails-6.0 bash -lc 'cd /app && bin/rails db:prepare'
docker exec woods-testbed-rails-6.0 bash -lc 'cd /app && bin/rails woods:extract'
docker exec woods-testbed-rails-6.0 bash -lc 'cd /app && bin/rails runner script/shared/woods_smoke.rb'
```

> This variant is validated via Docker/CI rather than the host (Ruby 3.0 / Rails
> 6.0 aren't installed on most dev machines). The gem's own CI also gates Rails
> 6.0 through `gemfiles/rails_6.0.gemfile` + the booted-app extraction test.
