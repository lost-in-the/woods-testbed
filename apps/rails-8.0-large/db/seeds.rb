author = Author.find_or_create_by!(email: "ada@example.com") { |a| a.name = "Ada" }
Article.find_or_create_by!(slug: "hello-woods") do |a|
  a.author = author
  a.title = "Hello Woods"
  a.body = "A first article for the large variant."
end
