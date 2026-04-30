defmodule Bank.Workspaces.MembershipTest do
  @moduledoc """
  Coverage for `Bank.Workspaces.Membership` helpers (#159a).
  """

  use ExUnit.Case, async: true

  alias Bank.Workspaces.Membership

  describe "role_at_least?/2 (#159a)" do
    test "viewer < operator < admin < owner" do
      # An owner satisfies every requirement.
      assert Membership.role_at_least?(:owner, :viewer)
      assert Membership.role_at_least?(:owner, :operator)
      assert Membership.role_at_least?(:owner, :admin)
      assert Membership.role_at_least?(:owner, :owner)

      # An admin meets viewer/operator/admin but not owner.
      assert Membership.role_at_least?(:admin, :viewer)
      assert Membership.role_at_least?(:admin, :operator)
      assert Membership.role_at_least?(:admin, :admin)
      refute Membership.role_at_least?(:admin, :owner)

      # Operator meets viewer + operator only.
      assert Membership.role_at_least?(:operator, :viewer)
      assert Membership.role_at_least?(:operator, :operator)
      refute Membership.role_at_least?(:operator, :admin)
      refute Membership.role_at_least?(:operator, :owner)

      # Viewer meets viewer only.
      assert Membership.role_at_least?(:viewer, :viewer)
      refute Membership.role_at_least?(:viewer, :operator)
      refute Membership.role_at_least?(:viewer, :admin)
      refute Membership.role_at_least?(:viewer, :owner)
    end

    test "nil actual role never satisfies any required role" do
      refute Membership.role_at_least?(nil, :viewer)
      refute Membership.role_at_least?(nil, :operator)
      refute Membership.role_at_least?(nil, :admin)
      refute Membership.role_at_least?(nil, :owner)
    end

    test "raises FunctionClauseError on an unrecognised required role" do
      assert_raise FunctionClauseError, fn ->
        Membership.role_at_least?(:owner, :superuser)
      end
    end
  end
end
