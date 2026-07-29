-- v02 supersedes v01. DatabaseViewExtractor keeps only the highest _vNN of
-- each view, which is why the type is dispatched wholesale rather than per
-- file — shipping one version would not exercise that rule.
SELECT articles.id,
       articles.title,
       articles.author_id,
       COUNT(comments.id) AS comment_count
FROM articles
LEFT JOIN comments ON comments.article_id = articles.id
WHERE articles.published_at IS NOT NULL
GROUP BY articles.id, articles.title, articles.author_id
