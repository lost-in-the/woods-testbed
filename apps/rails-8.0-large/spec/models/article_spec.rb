require "rails_helper"

RSpec.describe Article do
  it "derives a slug from the title" do
    article = described_class.new(title: "Hello Woods")
    article.valid?
    expect(article.slug).to eq("hello-woods")
  end

  it "counts words through the WordCount PORO" do
    expect(described_class.new(body: "one two three").word_count).to eq(3)
  end
end
