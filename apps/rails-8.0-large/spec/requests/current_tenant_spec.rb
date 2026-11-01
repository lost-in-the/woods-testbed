require 'rails_helper'

RSpec.describe 'Current tenant', type: :request do
  before { setup_canopy }

  it 'is included by every controller' do
    Rails.application.eager_load!
    controllers = ActionController::Base.descendants.select { |c| c.name && Rails.root.join('app/controllers', "#{c.name.underscore}.rb").file? } - [ApplicationController]
    expect(controllers.size).to be >= 10
    expect(controllers.reject { |c| c.include?(CurrentTenant) }).to be_empty
  end

  it 'exposes the signed-in organization and author during a request' do
    seen = {}
    allow_any_instance_of(ArticlesController).to receive(:index).and_wrap_original do |original, *args|
      seen = { organization: Current.organization, author: Current.author }
      original.call(*args)
    end
    login
    get articles_path
    expect(seen).to eq(organization: @organization, author: @editor)
  end
end
