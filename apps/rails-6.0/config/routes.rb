Rails.application.routes.draw do
  # Woods Map explorer over the published index (woods-testbed#38). Gated by
  # WOODS_MAP_TOKEN from the compose environment; loopback needs no token.
  mount WoodsMap::Engine => "/woods"

  resources :posts, only: %i[index show create]
  root "posts#index"
end
