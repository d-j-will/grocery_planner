defmodule GroceryPlanner.Accounts.AccountMembershipTest do
  use GroceryPlanner.DataCase, async: true

  alias GroceryPlanner.Accounts.Account
  alias GroceryPlanner.Accounts.User
  alias GroceryPlanner.Accounts.AccountMembership

  setup do
    {:ok, account} = Account.create(%{name: "Test Account"}, authorize?: false)
    {:ok, user} = User.create("user@example.com", "Test User", "password123456")
    %{account: account, user: user}
  end

  describe "create" do
    test "creates membership with account and user", %{account: account, user: user} do
      {:ok, membership} =
        AccountMembership.create(account.id, user.id, %{role: :member}, authorize?: false)

      assert membership.account_id == account.id
      assert membership.user_id == user.id
      assert membership.role == :member
    end

    test "defaults role to member when not specified", %{account: account, user: user} do
      {:ok, membership} =
        AccountMembership.create(account.id, user.id, %{}, authorize?: false)

      assert membership.role == :member
    end

    test "creates owner membership", %{account: account, user: user} do
      {:ok, membership} =
        AccountMembership.create(account.id, user.id, %{role: :owner}, authorize?: false)

      assert membership.role == :owner
    end

    test "creates admin membership", %{account: account, user: user} do
      {:ok, membership} =
        AccountMembership.create(account.id, user.id, %{role: :admin}, authorize?: false)

      assert membership.role == :admin
    end

    test "rejects invalid role" do
      {:ok, account} = Account.create(%{name: "Role Test"}, authorize?: false)
      {:ok, user} = User.create("roletest@example.com", "Role Test", "password123456")

      assert {:error, error} =
               AccountMembership.create(account.id, user.id, %{role: :superadmin},
                 authorize?: false
               )

      assert error.errors |> Enum.any?(fn e -> e.field == :role end)
    end

    test "enforces unique user per account", %{account: account, user: user} do
      {:ok, _first} =
        AccountMembership.create(account.id, user.id, %{role: :member}, authorize?: false)

      assert {:error, _error} =
               AccountMembership.create(account.id, user.id, %{role: :admin}, authorize?: false)
    end

    test "allows same user in multiple accounts", %{user: user} do
      {:ok, account1} = Account.create(%{name: "Account 1"}, authorize?: false)
      {:ok, account2} = Account.create(%{name: "Account 2"}, authorize?: false)

      {:ok, membership1} =
        AccountMembership.create(account1.id, user.id, %{role: :member}, authorize?: false)

      {:ok, membership2} =
        AccountMembership.create(account2.id, user.id, %{role: :owner}, authorize?: false)

      assert membership1.account_id == account1.id
      assert membership2.account_id == account2.id
      assert membership1.user_id == membership2.user_id
    end

    test "sets joined_at timestamp", %{account: account, user: user} do
      {:ok, membership} =
        AccountMembership.create(account.id, user.id, %{role: :member}, authorize?: false)

      assert membership.joined_at != nil
      assert %DateTime{} = membership.joined_at
    end
  end

  describe "update" do
    test "updates role", %{account: account, user: user} do
      {:ok, membership} =
        AccountMembership.create(account.id, user.id, %{role: :member}, authorize?: false)

      assert membership.role == :member

      {:ok, updated} =
        AccountMembership.update(membership, %{role: :admin}, authorize?: false)

      assert updated.role == :admin
    end

    test "cannot update to invalid role", %{account: account, user: user} do
      {:ok, membership} =
        AccountMembership.create(account.id, user.id, %{role: :member}, authorize?: false)

      assert {:error, error} =
               AccountMembership.update(membership, %{role: :invalid}, authorize?: false)

      assert error.errors |> Enum.any?(fn e -> e.field == :role end)
    end
  end

  describe "destroy" do
    test "removes membership", %{account: account, user: user} do
      {:ok, membership} =
        AccountMembership.create(account.id, user.id, %{role: :member}, authorize?: false)

      assert :ok = AccountMembership.destroy(membership, authorize?: false)
    end
  end

  describe "authorization" do
    setup %{account: account, user: owner} do
      {:ok, owner_membership} =
        AccountMembership.create(account.id, owner.id, %{role: :owner}, authorize?: false)

      {:ok, member} = User.create("member2@example.com", "Member", "password123456")

      {:ok, member_membership} =
        AccountMembership.create(account.id, member.id, %{role: :member}, authorize?: false)

      %{
        owner: owner,
        owner_membership: owner_membership,
        member: member,
        member_membership: member_membership
      }
    end

    test "owner can add a member", %{account: account, owner: owner} do
      {:ok, invitee} = User.create("invitee@example.com", "Invitee", "password123456")

      assert {:ok, membership} =
               AccountMembership.create(account.id, invitee.id, %{role: :member},
                 actor: owner,
                 authorize?: true
               )

      assert membership.role == :member
    end

    test "member cannot add themselves as owner (role escalation)", %{
      account: account,
      member: member
    } do
      {:ok, colluder} = User.create("colluder@example.com", "Colluder", "password123456")

      result =
        AccountMembership.create(account.id, colluder.id, %{role: :owner},
          actor: member,
          authorize?: true
        )

      assert {:error, %Ash.Error.Forbidden{}} = result
    end

    test "member cannot add anyone at all", %{account: account, member: member} do
      {:ok, invitee} = User.create("invitee2@example.com", "Invitee", "password123456")

      result =
        AccountMembership.create(account.id, invitee.id, %{role: :member},
          actor: member,
          authorize?: true
        )

      assert {:error, %Ash.Error.Forbidden{}} = result
    end

    test "outsider cannot add members to an account they don't belong to", %{account: account} do
      {:ok, outsider} = User.create("outsider@example.com", "Outsider", "password123456")
      {:ok, invitee} = User.create("invitee3@example.com", "Invitee", "password123456")

      result =
        AccountMembership.create(account.id, invitee.id, %{role: :member},
          actor: outsider,
          authorize?: true
        )

      assert {:error, %Ash.Error.Forbidden{}} = result
    end

    test "owner can remove a member", %{owner: owner, member_membership: member_membership} do
      assert :ok = AccountMembership.destroy(member_membership, actor: owner, authorize?: true)
    end

    test "member cannot remove the owner's membership", %{
      owner_membership: owner_membership,
      member: member
    } do
      result = AccountMembership.destroy(owner_membership, actor: member, authorize?: true)

      assert {:error, %Ash.Error.Forbidden{}} = result
    end

    test "member cannot change their own role to owner", %{
      member: member,
      member_membership: member_membership
    } do
      result =
        AccountMembership.update(member_membership, %{role: :owner},
          actor: member,
          authorize?: true
        )

      assert {:error, %Ash.Error.Forbidden{}} = result
    end

    test "admin can change a member's role", %{
      account: account,
      member_membership: member_membership
    } do
      {:ok, admin} = User.create("admin2@example.com", "Admin", "password123456")

      {:ok, _admin_membership} =
        AccountMembership.create(account.id, admin.id, %{role: :admin}, authorize?: false)

      assert {:ok, updated} =
               AccountMembership.update(member_membership, %{role: :admin},
                 actor: admin,
                 authorize?: true
               )

      assert updated.role == :admin
    end
  end

  describe "role constraints" do
    test "all valid roles are accepted", %{account: account} do
      valid_roles = [:owner, :admin, :member]

      for role <- valid_roles do
        {:ok, user} = User.create("#{role}@example.com", "#{role} User", "password123456")

        {:ok, membership} =
          AccountMembership.create(account.id, user.id, %{role: role}, authorize?: false)

        assert membership.role == role
      end
    end
  end
end
