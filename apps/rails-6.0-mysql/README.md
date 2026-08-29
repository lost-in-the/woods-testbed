# woods-testbed — rails-6.0-mysql

The **MySQL twin** of rails-6.0: the same minimal Rails 6.0 / Ruby 3.0 app,
identical models and migrations, but with the `mysql2` adapter and a `users`
table. It exists so backend-dialect contracts have a lane that reaches a live
MySQL server through the production Console path — no other variant installs
mysql2, so a validator that only runs in the SQLite-backed runner can pass
while the packaged Console still sends a bad statement to MySQL.

Primary use: the MySQL dialect lock-clause contract
(gem PR lost-in-the/woods#248) via `script/shared/woods_mysql_console_smoke.rb`,
which builds the real EmbeddedExecutor over `ActiveRecord::Base.connection_pool`
and proves a rejected statement never reaches the adapter.

Bring it up (from the testbed root — the app rides the `backends` profile
because it needs the mysql service):

```bash
docker compose --profile backends up -d mysql rails-6.0-mysql
docker exec woods-testbed-rails-6.0-mysql bash -lc 'cd /app && bin/rails db:prepare'
docker exec woods-testbed-rails-6.0-mysql bash -lc \
  'cd /app && bin/rails runner script/shared/woods_mysql_console_smoke.rb'
```

> Contract-first: the smoke reports RED until gem PR lost-in-the/woods#248
> merges. That is the intended state — the lane exists to prove the fix, not
> to pass while the gap is open.

> This variant is validated via Docker/CI rather than the host (Ruby 3.0 /
> Rails 6.0 aren't installed on most dev machines).
