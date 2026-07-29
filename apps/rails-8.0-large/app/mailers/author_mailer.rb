class AuthorMailer < ApplicationMailer
  def article_published(article)
    @article = article
    @author = article.author
    mail(to: @author.email, subject: "Your article is live")
  end
end
