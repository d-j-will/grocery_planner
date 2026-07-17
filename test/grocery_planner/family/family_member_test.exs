defmodule GroceryPlanner.Family.FamilyMemberTest do
  use GroceryPlanner.DataCase, async: true

  import GroceryPlanner.FamilyTestHelpers

  alias GroceryPlanner.Family

  describe "create" do
    test "creates a family member with valid attributes" do
      {account, user} = create_account_and_user()

      assert {:ok, member} =
               Family.create_family_member(
                 account.id,
                 %{name: "Sam"},
                 actor: user,
                 tenant: account.id
               )

      assert member.name == "Sam"
      assert member.account_id == account.id
    end

    test "requires name" do
      {account, user} = create_account_and_user()

      assert {:error, _} =
               Family.create_family_member(
                 account.id,
                 %{},
                 actor: user,
                 tenant: account.id
               )
    end
  end

  describe "read" do
    test "lists family members for the account" do
      {account, user} = create_account_and_user()

      member1 = create_family_member(account, user, %{name: "Sam"})
      member2 = create_family_member(account, user, %{name: "Lily"})

      members = Family.list_family_members!(actor: user, tenant: account.id)
      member_ids = Enum.map(members, & &1.id)

      assert member1.id in member_ids
      assert member2.id in member_ids
    end

    test "excludes soft-deleted members" do
      {account, user} = create_account_and_user()

      member = create_family_member(account, user, %{name: "Deleted"})
      Family.destroy_family_member!(member, actor: user, tenant: account.id)

      members = Family.list_family_members!(actor: user, tenant: account.id)
      member_ids = Enum.map(members, & &1.id)

      refute member.id in member_ids
    end
  end

  describe "update" do
    test "updates a family member's name" do
      {account, user} = create_account_and_user()

      member = create_family_member(account, user, %{name: "Sam"})

      assert {:ok, updated} =
               Family.update_family_member(
                 member,
                 %{name: "Samuel"},
                 actor: user,
                 tenant: account.id
               )

      assert updated.name == "Samuel"
    end
  end

  describe "soft delete" do
    test "soft-deletes a family member" do
      {account, user} = create_account_and_user()

      member = create_family_member(account, user, %{name: "Sam"})

      assert :ok = Family.destroy_family_member(member, actor: user, tenant: account.id)

      # Should not appear in normal reads
      members = Family.list_family_members!(actor: user, tenant: account.id)
      refute Enum.any?(members, &(&1.id == member.id))
    end
  end

  describe "authorization" do
    test "denies cross-account access for read" do
      {account1, user1} = create_account_and_user()
      {_account2, user2} = create_account_and_user()

      create_family_member(account1, user1, %{name: "Sam"})

      # user2 cannot see account1's members
      members = Family.list_family_members!(actor: user2, tenant: account1.id)
      assert members == []
    end

    test "denies cross-account create" do
      {account1, _user1} = create_account_and_user()
      {_account2, user2} = create_account_and_user()

      assert {:error, error} =
               Family.create_family_member(
                 account1.id,
                 %{name: "Unauthorized"},
                 actor: user2,
                 tenant: account1.id
               )

      assert error.class == :forbidden
    end

    test "denies create with no actor" do
      {account, _user} = create_account_and_user()

      assert {:error, error} =
               Family.create_family_member(
                 account.id,
                 %{name: "No Actor"},
                 tenant: account.id
               )

      assert error.class == :forbidden
    end

    test "denies cross-account update" do
      {account1, user1} = create_account_and_user()
      {_account2, user2} = create_account_and_user()

      member = create_family_member(account1, user1, %{name: "Sam"})

      assert {:error, error} =
               Family.update_family_member(
                 member,
                 %{name: "Hacked"},
                 actor: user2,
                 tenant: account1.id
               )

      assert error.class == :forbidden
    end

    test "denies cross-account destroy" do
      {account1, user1} = create_account_and_user()
      {_account2, user2} = create_account_and_user()

      member = create_family_member(account1, user1, %{name: "Sam"})

      assert {:error, error} =
               Family.destroy_family_member(member, actor: user2, tenant: account1.id)

      assert error.class == :forbidden
    end
  end
end
