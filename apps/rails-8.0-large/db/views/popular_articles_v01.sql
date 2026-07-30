SELECT articles.id, articles.title, COUNT(comments.id) AS comment_count
FROM articles
LEFT JOIN comments ON comments.article_id = articles.id
GROUP BY articles.id, articles.title
