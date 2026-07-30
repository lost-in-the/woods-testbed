class PublishingPolicy
  MINIMUM_WORDS = 50

  def initialize(article)
    @article = article
  end

  def allowed?
    eligible? && meets_length?
  end

  def eligible?
    @article.author.present? && !@article.archived?
  end

  def meets_length?
    WordCount.new(@article.body.to_s).total >= MINIMUM_WORDS
  end
end
