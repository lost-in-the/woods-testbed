# Syndication pages and the partner API. Drawn from config/routes.rb.
namespace :api, defaults: { format: :json } do
  namespace :v1 do
    resources :licenses, only: %i[index show]
  end
  namespace :v2 do
    resources :licenses, only: %i[index show]
    resources :usage_reports, only: :create
  end
end

namespace :syndication do
  resources :partners, only: %i[index show create]
  resources :licenses, only: :create do
    member { post :revoke }
  end
end
