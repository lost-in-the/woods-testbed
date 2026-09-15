# Parsed statically by FactoryExtractor — factory_bot does not need to be
# loaded for the units to be produced.
FactoryBot.define do
  factory :organization do
    name { 'Factory Press' }
    sequence(:slug) { |n| "factory-press-#{n}" }
  end
  factory :publication do
    organization
    name { 'Factory Notes' }
    sequence(:slug) { |n| "factory-notes-#{n}" }
  end
  factory :author do
    name { "Ada" }
    sequence(:email) { |n| "author#{n}@example.com" }
  end

  factory :article do
    author
    publication
    after(:build) { |article| article.author.memberships.find_or_create_by!(organization: article.publication.organization) }
    title { "A generated title" }
    sequence(:slug) { |n| "article-#{n}" }
    body { "Body text." }
    published_at { Time.current }
  end
end
