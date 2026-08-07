module Staff
  class DepartmentsController < BaseController
    before_action :set_department, only: %i[edit update destroy]

    def index
      authorize Department
      @departments = Current.hotel.departments.ordered
      @department = Department.new
    end

    def create
      @department = Current.hotel.departments.new(department_params)
      authorize @department

      if @department.save
        redirect_to staff_departments_path, notice: "#{@department.name} added."
      else
        @departments = Current.hotel.departments.ordered
        render :index, status: :unprocessable_content
      end
    end

    def edit
    end

    def update
      if @department.update(department_params)
        redirect_to staff_departments_path, notice: "#{@department.name} updated."
      else
        render :edit, status: :unprocessable_content
      end
    end

    # A plain destroy — Department has_many :request_categories, dependent:
    # :restrict_with_error, so this simply fails with a populated
    # @department.errors (not an exception) when categories still reference
    # it. Deactivating is the action the index offers by default; this is
    # the secondary "delete" affordance, only effective once unreferenced.
    def destroy
      if @department.destroy
        redirect_to staff_departments_path, notice: "#{@department.name} deleted."
      else
        redirect_to staff_departments_path, alert: @department.errors.full_messages.to_sentence
      end
    end

    private
      def set_department
        @department = Current.hotel.departments.find(params[:id])
        authorize @department
      end

      def department_params
        params.require(:department).permit(:name, :position, :active)
      end
  end
end
