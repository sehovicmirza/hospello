# Every model whose rows belong to exactly one hotel includes this.
# It declares the association and the acts_as_tenant scope together so the two
# can never drift apart.
module TenantScoped
  extend ActiveSupport::Concern

  included do
    acts_as_tenant :hotel
  end
end
