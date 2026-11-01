module Syndication
  class LicenseSerializer < ApplicationSerializer
    attributes :id, :territory, :starts_on, :ends_on, :exclusive, :article

    def id = record.id
    def territory = record.territory
    def starts_on = record.starts_on
    def ends_on = record.ends_on
    def exclusive = record.exclusive

    def article
      { title: record.article.title, slug: record.article.slug, body: record.article.body }
    end
  end
end
