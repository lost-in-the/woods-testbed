# Minimal RESTful controller so the controller + route extractors have
# something to resolve, including a route-helper navigation edge.
#
# Blog scenario (woods-testbed#38): a set_post filter, strong parameters and
# templates, so the Woods Map walkthroughs (scenario 1: the routes, filters
# and post_params, then the show template and its card partial) run on the
# Rails 6.0 floor as on rails-8.0.
class PostsController < ApplicationController
  before_action :set_post, only: :show

  def index
    @posts = Post.recent
  end

  def show
    @comments = @post.comments
  end

  def create
    @post = Post.create(post_params)
    redirect_to posts_path
  end

  private

  def set_post
    @post = Post.find(params[:id])
  end

  def post_params
    params.require(:post).permit(:title)
  end
end
