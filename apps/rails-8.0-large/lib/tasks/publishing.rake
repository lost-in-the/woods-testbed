namespace :publishing do
  # Hash-rocket form. RakeTaskExtractor#parse_task_signature requires a leading
  # colon on the task name, so this is the form it can actually read.
  desc "Report article counts per author"
  task :report => :environment do
    Author.find_each { |a| puts "#{a.display_name}: #{a.articles.count}" }
  end

  # Modern Ruby 1.9 hash form — `task name: :environment`, no leading colon.
  # This is what most Rails apps write, and the extractor does not parse it.
  # Kept deliberately so the gap has a live fixture; see the matching entry in
  # kernel_contract.yml known_gem_issues.
  desc "Archive articles that have been unpublished for a year"
  task archive_stale: :environment do
    Article.not_archived.where(published_at: nil).find_each(&:archive!)
  end
end
