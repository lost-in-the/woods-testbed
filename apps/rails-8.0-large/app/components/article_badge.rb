# Phlex component — discovered from Phlex::HTML.descendants, a different
# extractor (PhlexExtractor) than the ViewComponent one above.
class ArticleBadge < Phlex::HTML
  def initialize(article:)
    @article = article
  end

  def view_template
    span(class: "badge") { @article.published_at ? "live" : "draft" }
  end
end
