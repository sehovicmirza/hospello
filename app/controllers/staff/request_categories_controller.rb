module Staff
  # Request categories are what Slice 4's AI service-request tool builds its
  # category enum from, and detail_fields tells the assistant which details
  # to gather before it may propose a request — so this data is read by the
  # AI, not just displayed to staff. A hotel is free to rename any of it
  # (including into Bosnian); the AI uses whatever ends up stored here.
  class RequestCategoriesController < BaseController
    # Service requests are what the Service plan buys. On Essentials the whole
    # queue does not exist, so this screen is refused with an explanation
    # rather than shown empty (see PlanGated).
    requires_plan_feature :requests

    before_action :set_category, only: %i[edit update destroy]
    before_action :set_department_options, only: %i[index create edit update]

    def index
      authorize RequestCategory
      @categories = Current.hotel.request_categories.ordered.includes(:department)
      @category = RequestCategory.new
    end

    def create
      @category = Current.hotel.request_categories.new(request_category_params)
      authorize @category

      if @category.save
        redirect_to staff_request_categories_path, notice: t(".added", name: @category.name)
      else
        @categories = Current.hotel.request_categories.ordered.includes(:department)
        render :index, status: :unprocessable_content
      end
    end

    def edit
    end

    def update
      if @category.update(request_category_params)
        redirect_to staff_request_categories_path, notice: t(".updated", name: @category.name)
      else
        render :edit, status: :unprocessable_content
      end
    end

    # Plain destroy: nothing references a request category yet in this
    # slice (Slice 4's guest requests will). No dependent: :restrict_with_error
    # exists to guard this because there is nothing yet to guard against —
    # add one alongside whatever future association points here, rather
    # than leaving this a silent delete once one exists.
    def destroy
      if @category.destroy
        redirect_to staff_request_categories_path, notice: t(".deleted", name: @category.name)
      else
        redirect_to staff_request_categories_path, alert: @category.errors.full_messages.to_sentence
      end
    end

    private
      def set_category
        @category = Current.hotel.request_categories.find(params[:id])
        authorize @category
      end

      def set_department_options
        @department_options = Current.hotel.departments.ordered
      end

      def request_category_params
        params.require(:request_category).permit(:key, :name, :icon, :department_id, :position, :active, detail_fields: [])
      end
  end
end
