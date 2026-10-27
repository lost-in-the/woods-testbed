author = User.find_or_create_by!(email: "author@example.com") { |u| u.name = "Ada Author" }
# Created before any subscriber exists, so NotifySubscribersJob mails nobody:
# the mailer's template reads @preferences, the blog scenario's seeded bug.
post = Post.find_or_create_by!(title: "Hello, Woods") { |p| p.author = author }
post.comments.find_or_create_by!(body: "First!")
User.find_or_create_by!(email: "reader@example.com") { |u| u.name = "Rex Reader" }
