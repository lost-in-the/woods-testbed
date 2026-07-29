# Parsed statically by FactoryExtractor — factory_bot does not need to be
# loaded for the units to be produced.
FactoryBot.define do
  factory :author do
    name { "Ada" }
    sequence(:email) { |n| "author#{n}@example.com" }
  end

  factory :article do
    author
    title { "A generated title" }
    sequence(:slug) { |n| "article-#{n}" }
    body { "Body text." }
    published_at { Time.current }
  end
end
