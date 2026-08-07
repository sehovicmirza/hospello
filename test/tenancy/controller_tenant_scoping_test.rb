require "test_helper"

# The base controllers are where every later request gets (or is denied) its
# tenant, so they are exercised here through real requests against throwaway
# controllers rather than waiting for the namespaces to be filled in.
class ControllerTenantScopingTest < ActionDispatch::IntegrationTest
  class StaffProbesController < Staff::BaseController
    def show
      render plain: "hotel=#{Current.hotel&.slug} tenant=#{ActsAsTenant.current_tenant&.slug}"
    end
  end

  class PlatformProbesController < Platform::BaseController
    def show
      audit!("probe.viewed", hotel: Hotel.find_by(slug: params[:hotel_slug]), reason: "test")
      render plain: "hotel=#{Current.hotel.inspect} tenant=#{ActsAsTenant.current_tenant.inspect}"
    end
  end

  test "a staff request runs inside its own hotel's tenant" do
    with_probes do
      sign_in users(:vrelo_staff)
      get "/staff_probe"

      assert_response :success
      assert_equal "hotel=vrelo-bosne tenant=vrelo-bosne", response.body
    end
  end

  test "a platform admin is refused by the staff namespace" do
    with_probes do
      sign_in users(:platform)
      get "/staff_probe"

      assert_response :forbidden
    end
  end

  test "a staff user of a suspended hotel is refused by the staff namespace" do
    with_probes do
      sign_in users(:stari_staff)
      hotels(:stari_grad).suspended!
      get "/staff_probe"

      assert_response :forbidden
    end
  end

  test "a deactivated staff user is refused by the staff namespace" do
    with_probes do
      sign_in users(:stari_staff)
      users(:stari_staff).update!(active: false)
      get "/staff_probe"

      assert_response :forbidden
    end
  end

  test "the platform namespace sets no ambient tenant" do
    with_probes do
      sign_in users(:platform)
      get "/platform_probe", params: { hotel_slug: hotels(:stari_grad).slug }

      assert_response :success
      assert_equal "hotel=nil tenant=nil", response.body
    end
  end

  test "the platform namespace records what an admin did" do
    with_probes do
      sign_in users(:platform)

      assert_difference -> { AuditLog.count }, 1 do
        get "/platform_probe", params: { hotel_slug: hotels(:stari_grad).slug }
      end

      log = AuditLog.last

      assert_equal "probe.viewed", log.action
      assert_equal users(:platform), log.actor_user
      assert_equal hotels(:stari_grad), log.hotel
      assert_equal({ "reason" => "test" }, log.metadata)
    end
  end

  # Sessions are permanent cookies with no expiry, and nothing destroys them when
  # an account is deactivated, so this check is the only revocation there is for
  # the one role that can read every hotel.
  test "a deactivated platform admin is refused by the platform namespace" do
    with_probes do
      sign_in users(:platform)
      users(:platform).update!(active: false)
      get "/platform_probe"

      assert_response :forbidden
    end
  end

  test "a hotel admin is refused by the platform namespace" do
    with_probes do
      sign_in users(:stari_admin)
      get "/platform_probe"

      assert_response :forbidden
    end
  end

  private
    def with_probes(&block)
      with_routing do |routes|
        routes.draw do
          get "staff_probe" => "controller_tenant_scoping_test/staff_probes#show"
          get "platform_probe" => "controller_tenant_scoping_test/platform_probes#show"
        end

        yield
      end
    end
end
