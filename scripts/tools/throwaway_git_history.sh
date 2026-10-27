#!/usr/bin/env bash
# Gives a blog-scenario variant a small, throwaway git history, so Woods
# publishes a commit table (W-3) and the Woods Map timelines have commits to
# show: design-study scenario 2, step 4 ("click the commit's author to filter
# the timeline to their changes across the neighbourhood", woods-map#92).
#
# Usage, inside the variant's container (scripts/ is mounted at script/shared):
#   docker exec woods-testbed-rails-8.0 bash -lc \
#     'git config --global --add safe.directory /app && script/shared/tools/throwaway_git_history.sh /app'
#
# then run woods:extract as usual. The container runs as root over a bind
# mount the host owns, so git refuses the repository as "dubious ownership"
# until /app is a safe.directory; Woods' own git calls need that too, which is
# why the trust is set in the container's global config and not here.
#
# Three authors, as git records them: the app arrives in one commit, the
# mailer's templates in a second, and the job and the mailer together six
# days ago in a third, which is the "teammate's digest change" the scenario
# investigates. The commits are dated relative to now so they stay inside
# Woods' 365-day window. Nothing in the app changes; only .git is written,
# and the script refuses a directory that already has one.
set -euo pipefail

app=${1:-/app}
cd "$app"

if [ -e .git ]; then
  echo "refusing: $app already has .git; this script only makes a throwaway history" >&2
  exit 1
fi

job=app/jobs/notify_subscribers_job.rb
mailer=app/mailers/mailing_list_mailer.rb
templates=app/views/mailing_list_mailer
for path in "$job" "$mailer" "$templates"; do
  if [ ! -e "$path" ]; then
    echo "refusing: $app has no $path, so it is not a blog-scenario variant" >&2
    exit 1
  fi
done

git init -q
# The app's own .gitignore covers tmp, log, storage and the databases; the
# shared scripts are a mount, and the lockfile is the testbed's, not the app's.
printf '%s\n' '/script/shared/' '/Gemfile.lock' >> .git/info/exclude

now=$(date +%s)

# commit NAME EMAIL DAYS_AGO MESSAGE PATHSPEC...
commit() {
  local name=$1 email=$2 days=$3 message=$4
  shift 4
  git add -A -- "$@"
  GIT_AUTHOR_NAME=$name GIT_AUTHOR_EMAIL=$email GIT_COMMITTER_NAME=$name GIT_COMMITTER_EMAIL=$email \
    GIT_AUTHOR_DATE="@$((now - days * 86400)) +0000" GIT_COMMITTER_DATE="@$((now - days * 86400)) +0000" \
    git -c commit.gpgsign=false commit -q -m "$message"
}

commit 'Leah Armstrong' 'leah@example.test' 40 'Start the blog' \
  . ":(exclude)$job" ":(exclude)$mailer" ":(exclude)$templates"
commit 'Zoë Ramanathan-Castellanos' 'zoe@example.test' 20 'Draft the new-post email' "$templates"
commit 'Sam Okafor-Whitfield' 'sam@example.test' 6 'Send subscriber digests from the job' "$job" "$mailer"

git log --format='%h %an, %ad: %s' --date=short
