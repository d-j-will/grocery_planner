defmodule GroceryPlannerWeb.SettingsLiveTest do
  use GroceryPlannerWeb.ConnCase, async: true
  import Phoenix.LiveViewTest
  import GroceryPlanner.InventoryTestHelpers

  alias GroceryPlanner.Accounts

  setup do
    account = create_account()
    user = create_user(account)

    conn =
      build_conn()
      |> init_test_session(%{
        user_id: user.id,
        account_id: account.id
      })

    %{conn: conn, account: account, user: user}
  end

  describe "Notification Preferences" do
    test "renders notification settings form", %{conn: conn} do
      {:ok, view, html} = live(conn, "/settings")

      assert html =~ "Notification Preferences"
      assert has_element?(view, "form#notification-form")
      assert has_element?(view, "input[name='notification[expiration_alerts_enabled]']")
    end

    test "creates default preferences if none exist", %{conn: conn, user: user, account: account} do
      {:ok, _view, _html} = live(conn, "/settings")

      # Should not have created a record yet, only on save
      assert {:ok, []} =
               GroceryPlanner.Notifications.list_notification_preferences(
                 actor: user,
                 tenant: account.id
               )
    end

    test "saves new notification preferences", %{conn: conn, user: user, account: account} do
      {:ok, view, _html} = live(conn, "/settings")

      view
      |> form("#notification-form",
        notification: %{
          expiration_alerts_enabled: "false",
          recipe_suggestions_enabled: "false",
          email_notifications_enabled: "true"
        }
      )
      |> render_submit()

      assert render(view) =~ "Notification preferences updated successfully"

      # Verify persistence
      {:ok, [pref]} =
        GroceryPlanner.Notifications.list_notification_preferences(
          actor: user,
          tenant: account.id
        )

      assert pref.expiration_alerts_enabled == false
      assert pref.recipe_suggestions_enabled == false
      assert pref.email_notifications_enabled == true
    end

    test "updates existing notification preferences", %{conn: conn, user: user, account: account} do
      # Create existing preference
      GroceryPlanner.Notifications.create_notification_preference!(
        user.id,
        account.id,
        %{expiration_alert_days: 5},
        authorize?: false,
        tenant: account.id
      )

      {:ok, view, _html} = live(conn, "/settings")

      view
      |> form("#notification-form",
        notification: %{
          expiration_alert_days: "3"
        }
      )
      |> render_submit()

      assert render(view) =~ "Notification preferences updated successfully"

      # Verify update
      {:ok, [pref]} =
        GroceryPlanner.Notifications.list_notification_preferences(
          actor: user,
          tenant: account.id
        )

      assert pref.expiration_alert_days == 3
    end
  end

  describe "User Profile" do
    test "updates meal planner layout preference", %{conn: conn, user: user} do
      {:ok, view, _html} = live(conn, "/settings")

      view
      |> form("#user-form",
        user: %{
          name: user.name,
          email: to_string(user.email),
          theme: user.theme,
          meal_planner_layout: "explorer"
        }
      )
      |> render_submit()

      assert render(view) =~ "Profile updated successfully"

      {:ok, updated_user} = GroceryPlanner.Accounts.User.by_id(user.id, actor: user)
      assert updated_user.meal_planner_layout == "explorer"
    end
  end

  describe "Member role authorization" do
    setup %{account: account} do
      {:ok, member} =
        Accounts.User.create("member@example.com", "Member User", "password123456",
          authorize?: false
        )

      {:ok, _membership} =
        Accounts.AccountMembership.create(account.id, member.id, %{role: :member},
          authorize?: false
        )

      member_conn =
        build_conn()
        |> init_test_session(%{user_id: member.id, account_id: account.id})

      %{member_conn: member_conn, member: member}
    end

    test "member cannot add an owner via a forged invitation event", %{
      member_conn: member_conn,
      account: account
    } do
      {:ok, view, _html} = live(member_conn, "/settings")

      render_submit(view, "send_invitation", %{
        "email" => "colluder@example.com",
        "role" => "owner"
      })

      assert render(view) =~ "You do not have permission to add members"

      {:ok, memberships} = Accounts.AccountMembership.read(authorize?: false)
      account_memberships = Enum.filter(memberships, &(&1.account_id == account.id))

      # only the pre-existing owner + member, no colluder was added
      assert length(account_memberships) == 2
    end

    test "member cannot remove the owner via a forged remove event", %{
      member_conn: member_conn,
      account: account,
      user: owner
    } do
      {:ok, view, _html} = live(member_conn, "/settings")

      {:ok, memberships} = Accounts.AccountMembership.read(authorize?: false)

      owner_membership =
        Enum.find(memberships, &(&1.account_id == account.id and &1.user_id == owner.id))

      render_click(view, "remove_member", %{"id" => owner_membership.id})

      assert render(view) =~ "You do not have permission to remove members"

      {:ok, memberships_after} = Accounts.AccountMembership.read(authorize?: false)
      assert Enum.any?(memberships_after, &(&1.id == owner_membership.id))
    end
  end
end
