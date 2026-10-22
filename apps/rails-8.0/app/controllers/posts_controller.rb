# Blog scenario (woods-testbed#38): a resourceful controller whose filters
# assign @post for some actions, so the passage's filter matrix and the
# per-action assigns have something to show.
class PostsController < ApplicationController
  before_action :logged_in_user, except: %i[index show]
  before_action :set_post, only: %i[show edit update destroy]
  before_action :authorize_author!, only: %i[edit update destroy]

  def index
    @posts = Post.published.includes(:author, :tags).order(published_at: :desc)
  end

  def show
    @comments = @post.comments.includes(:user)
  end

  def new
    @post = current_user.posts.build
  end

  def create
    @post = current_user.posts.build(post_params)
    if @post.save
      redirect_to @post, status: :see_other
    else
      render :new, status: :unprocessable_entity
    end
  end

  def edit; end

  def update
    if @post.update(post_params)
      redirect_to @post, status: :see_other
    else
      render :edit, status: :unprocessable_entity
    end
  end

  def destroy
    @post.destroy
    redirect_to posts_url, status: :see_other
  end

  private

  def set_post
    @post = Post.find_by!(slug: params[:id])
  end

  def authorize_author!
    redirect_to root_url, status: :see_other unless @post.author == current_user
  end

  def post_params
    params.require(:post).permit(:title, :body)
  end
end
