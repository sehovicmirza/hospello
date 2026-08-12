module Staff
  # The hotel's record of what it has registered with Meta, and what Meta
  # said about each one.
  #
  # **Nothing here submits anything to Meta or sends anything to a guest.**
  # Templates are created and approved in Meta's own Business Manager; this
  # is a hotel's note of that, so it can answer "is our welcome message usable
  # yet?" without logging in there. That is deliberately the whole feature:
  # this slice ships no bulk-send UI, because an un-opted-in template send
  # risks the hotel's number, which is the hotel's asset and not ours (see
  # docs/plan/slice-6-tasks.md).
  #
  # It follows Staff::DepartmentsController's shape rather than
  # WhatsappChannelsController's: there are many of these per hotel, so they
  # need ids in the path — and, exactly as everywhere else in this namespace,
  # those ids are looked up through `Current.hotel.whatsapp_templates`, so
  # another hotel's id 404s before `authorize` is even reached.
  class WhatsappTemplatesController < BaseController
    before_action :set_template, only: %i[edit update destroy]

    def create
      @template = Current.hotel.whatsapp_templates.new(template_params)
      authorize @template

      if @template.save
        redirect_to edit_staff_whatsapp_channel_path, notice: t(".created", name: @template.name)
      else
        # Rendered by the screen that owns this list, so a hotel sees the
        # error next to the form they typed into rather than on a page of
        # their own that has lost the rest of the context.
        render_channel_screen
      end
    end

    def edit
      render_channel_screen
    end

    def update
      if @template.update(template_params)
        redirect_to edit_staff_whatsapp_channel_path, notice: t(".updated", name: @template.name)
      else
        render_channel_screen
      end
    end

    def destroy
      @template.destroy!
      redirect_to edit_staff_whatsapp_channel_path, notice: t(".deleted", name: @template.name)
    end

    private
      def set_template
        @template = Current.hotel.whatsapp_templates.find(params[:id])
        authorize @template
      end

      # `status` and `rejection_reason` are permitted, unlike the channel
      # screen's verified_at/last_inbound_at — and the difference is worth
      # stating, because it looks inconsistent. Those are written by things
      # that really happen inside this app (an inbound delivery stamps
      # last_inbound_at), so a form could make them lie. These are written by
      # Meta, in Meta's dashboard, where this app has no reach at all: a
      # hotel transcribing them is the only way they can be here. What stops
      # a wrong value from mattering is that Meta refuses the send anyway —
      # WhatsappTemplate#usable? is a pre-check, never a permission.
      def template_params
        params.require(:whatsapp_template).permit(:name, :locale, :category, :status, :body, :rejection_reason)
      end

      def render_channel_screen
        @channel = Current.hotel.whatsapp_channel || Current.hotel.build_whatsapp_channel
        render "staff/whatsapp_channels/edit", status: (@template.errors.any? ? :unprocessable_content : :ok)
      end
  end
end
