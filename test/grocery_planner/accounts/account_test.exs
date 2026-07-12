defmodule GroceryPlanner.Accounts.AccountTest do
  use GroceryPlanner.DataCase, async: true

  alias GroceryPlanner.Accounts.Account
  alias GroceryPlanner.Accounts.User
  alias GroceryPlanner.Accounts.AccountMembership

  describe "create" do
    test "creates account with required name" do
      {:ok, account} = Account.create(%{name: "Test Account"}, authorize?: false)

      assert account.name == "Test Account"
      assert account.id != nil
    end

    test "applies default timezone when not provided" do
      {:ok, account} = Account.create(%{name: "Default TZ Account"}, authorize?: false)

      assert account.timezone == "America/New_York"
    end

    test "applies default currency when not provided" do
      {:ok, account} = Account.create(%{name: "Default Currency Account"}, authorize?: false)

      assert account.currency == "USD"
    end

    test "accepts custom timezone and currency" do
      {:ok, account} =
        Account.create(
          %{name: "Custom Account", timezone: "Europe/London", currency: "GBP"},
          authorize?: false
        )

      assert account.name == "Custom Account"
      assert account.timezone == "Europe/London"
      assert account.currency == "GBP"
    end

    test "fails without name" do
      assert {:error, error} = Account.create(%{}, authorize?: false)
      assert error.errors |> Enum.any?(fn e -> e.field == :name end)
    end
  end

  describe "update" do
    setup do
      {:ok, account} = Account.create(%{name: "Original Name"}, authorize?: false)
      {:ok, user} = User.create("owner@example.com", "Owner", "password123456")

      {:ok, _membership} =
        AccountMembership.create(account.id, user.id, %{role: :owner}, authorize?: false)

      %{account: account, owner: user}
    end

    test "updates name with authorized owner", %{account: account, owner: owner} do
      {:ok, updated} =
        Account.update(account, %{name: "Updated Name"}, actor: owner, authorize?: true)

      assert updated.name == "Updated Name"
    end

    test "updates timezone", %{account: account, owner: owner} do
      {:ok, updated} =
        Account.update(account, %{timezone: "America/Los_Angeles"},
          actor: owner,
          authorize?: true
        )

      assert updated.timezone == "America/Los_Angeles"
    end

    test "updates currency", %{account: account, owner: owner} do
      {:ok, updated} =
        Account.update(account, %{currency: "EUR"}, actor: owner, authorize?: true)

      assert updated.currency == "EUR"
    end

    test "denies update for regular member", %{account: account} do
      {:ok, member} = User.create("member@example.com", "Member", "password123456")

      {:ok, _membership} =
        AccountMembership.create(account.id, member.id, %{role: :member}, authorize?: false)

      result = Account.update(account, %{name: "Hacked Name"}, actor: member, authorize?: true)

      case result do
        {:error, %Ash.Error.Forbidden{}} ->
          assert true

        {:error, %Ash.Error.Invalid{errors: errors}} ->
          assert Enum.any?(errors, fn e -> match?(%Ash.Error.Forbidden{}, e) end)

        {:ok, _} ->
          flunk("Expected regular member update to be forbidden")
      end
    end

    test "allows update for admin", %{account: account} do
      {:ok, admin} = User.create("admin@example.com", "Admin", "password123456")

      {:ok, _membership} =
        AccountMembership.create(account.id, admin.id, %{role: :admin}, authorize?: false)

      {:ok, updated} =
        Account.update(account, %{name: "Admin Updated"}, actor: admin, authorize?: true)

      assert updated.name == "Admin Updated"
    end
  end

  describe "read authorization" do
    test "only members can read their accounts" do
      {:ok, account} = Account.create(%{name: "Private Account"}, authorize?: false)
      {:ok, member} = User.create("member@example.com", "Member", "password123456")
      {:ok, outsider} = User.create("outsider@example.com", "Outsider", "password123456")

      {:ok, _membership} =
        AccountMembership.create(account.id, member.id, %{role: :member}, authorize?: false)

      # Member can read
      {:ok, found} = Account.by_id(account.id, actor: member, authorize?: true)
      assert found.id == account.id

      # Outsider cannot read - returns NotFound wrapped in Invalid
      result = Account.by_id(account.id, actor: outsider, authorize?: true)

      case result do
        {:error, %Ash.Error.Query.NotFound{}} ->
          assert true

        {:error, %Ash.Error.Invalid{errors: errors}} ->
          assert Enum.any?(errors, fn e -> match?(%Ash.Error.Query.NotFound{}, e) end)

        other ->
          flunk("Expected not found error, got: #{inspect(other)}")
      end
    end
  end

  describe "destroy" do
    setup do
      {:ok, account} = Account.create(%{name: "To Delete"}, authorize?: false)
      {:ok, owner} = User.create("owner@example.com", "Owner", "password123456")

      {:ok, membership} =
        AccountMembership.create(account.id, owner.id, %{role: :owner}, authorize?: false)

      %{account: account, owner: owner, owner_membership: membership}
    end

    test "account can be destroyed without authorization after removing memberships", %{
      account: account,
      owner_membership: membership
    } do
      # Must delete memberships first due to FK constraint
      :ok = AccountMembership.destroy(membership, authorize?: false)

      # Note: With authorization enabled, deletion would fail because
      # the owner's membership is deleted, so they can't pass the policy check.
      # This tests that the actual deletion works without auth.
      assert :ok = Account.destroy(account, authorize?: false)
    end

    test "owner cannot destroy account with authorization after membership removed", %{
      account: account,
      owner: owner,
      owner_membership: membership
    } do
      # Delete membership first
      :ok = AccountMembership.destroy(membership, authorize?: false)

      # Now owner fails policy check because they have no membership
      result = Account.destroy(account, actor: owner, authorize?: true)

      case result do
        {:error, %Ash.Error.Forbidden{}} ->
          assert true

        {:error, %Ash.Error.Invalid{errors: errors}} ->
          assert Enum.any?(errors, fn e -> match?(%Ash.Error.Forbidden.Policy{}, e) end)

        other ->
          flunk("Expected forbidden error, got: #{inspect(other)}")
      end
    end

    test "cannot destroy account with existing memberships", %{account: account, owner: owner} do
      # FK constraint prevents deletion when memberships exist
      result = Account.destroy(account, actor: owner, authorize?: true)

      case result do
        {:error, %Ash.Error.Invalid{errors: errors}} ->
          assert Enum.any?(errors, fn e ->
                   match?(%Ash.Error.Changes.InvalidAttribute{field: :id}, e)
                 end)

        {:error, _} ->
          assert true

        :ok ->
          flunk("Expected error due to FK constraint")
      end
    end
  end
end
