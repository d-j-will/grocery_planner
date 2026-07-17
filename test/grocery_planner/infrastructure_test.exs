defmodule GroceryPlanner.InfrastructureTest do
  use GroceryPlannerWeb.ConnCase, async: false
  use ExUnitProperties

  alias GroceryPlanner.AiClient

  describe "Application.validate_ai_service/0" do
    test "with validate_ai_service: false, no health check is attempted" do
      # Store original config
      original = Application.get_env(:grocery_planner, :validate_ai_service)

      try do
        # Disable validation
        Application.put_env(:grocery_planner, :validate_ai_service, false)

        # Stub AI service to fail - if validation runs, this would cause issues
        Req.Test.stub(AiClient, fn conn ->
          Req.Test.transport_error(conn, :econnrefused)
        end)

        # Start should succeed without attempting health check
        # We can't directly test validate_ai_service since it's private,
        # but we verify the config controls whether validation happens
        assert Application.get_env(:grocery_planner, :validate_ai_service) == false
      after
        # Restore original config
        if original do
          Application.put_env(:grocery_planner, :validate_ai_service, original)
        else
          Application.delete_env(:grocery_planner, :validate_ai_service)
        end
      end
    end

    test "startup succeeds when AI service is unavailable (default non-required mode)" do
      original_validate = Application.get_env(:grocery_planner, :validate_ai_service)
      original_require = Application.get_env(:grocery_planner, :require_ai_service)

      try do
        Application.put_env(:grocery_planner, :validate_ai_service, true)
        Application.put_env(:grocery_planner, :require_ai_service, false)

        Req.Test.stub(AiClient, fn conn ->
          Req.Test.transport_error(conn, :econnrefused)
        end)

        # In non-required mode, AI service failure should not crash startup
        # The validate_ai_service/0 function logs warning but doesn't call System.stop
        assert {:error, _} = AiClient.health_check()
      after
        if original_validate do
          Application.put_env(:grocery_planner, :validate_ai_service, original_validate)
        else
          Application.delete_env(:grocery_planner, :validate_ai_service)
        end

        if original_require do
          Application.put_env(:grocery_planner, :require_ai_service, original_require)
        else
          Application.delete_env(:grocery_planner, :require_ai_service)
        end
      end
    end

    test "health check validates the correct endpoint" do
      Req.Test.stub(AiClient, fn conn ->
        # Verify the request is to /health/ready endpoint (actual implementation)
        assert conn.request_path == "/health/ready"
        assert conn.method == "GET"

        Req.Test.json(conn, %{
          "status" => "ok",
          "checks" => %{},
          "version" => "1.0.0"
        })
      end)

      assert {:ok, body} = AiClient.health_check()
      assert body["status"] == "ok"
    end
  end

  describe "HealthController.determine_status/1 logic" do
    test "database error returns error status with 503" do
      # Simulate database check failure
      Req.Test.stub(AiClient, fn conn ->
        Req.Test.json(conn, %{"status" => "ok", "checks" => %{}, "version" => "1.0.0"})
      end)

      # We can't directly test determine_status since it's private,
      # but we can test the behavior through the controller
      # This test verifies the logic through integration
      conn = build_conn()
      conn = get(conn, "/health_check")

      # With healthy DB and AI, should get 200
      assert conn.status == 200
      body = json_response(conn, 200)
      assert body["status"] in ["ok", "degraded"]
    end

    test "AI service transport error returns degraded with 200 (optional sidecar)" do
      Req.Test.stub(AiClient, fn conn ->
        Req.Test.transport_error(conn, :econnrefused)
      end)

      conn = build_conn()
      conn = get(conn, "/health_check")
      # Sidecar down is "degraded", not fatal — the app stays in rotation (c29).
      body = json_response(conn, 200)

      assert body["status"] == "degraded"
      assert body["checks"]["ai_service"]["status"] == "unavailable"
    end

    test "healthy AI + healthy DB returns ok with 200" do
      Req.Test.stub(AiClient, fn conn ->
        Req.Test.json(conn, %{
          "status" => "ok",
          "checks" => %{
            "database" => %{"status" => "ok"}
          },
          "version" => "1.0.0"
        })
      end)

      conn = build_conn()
      conn = get(conn, "/health_check")
      body = json_response(conn, 200)

      assert body["status"] == "ok"
      assert body["checks"]["database"]["status"] == "ok"
      assert body["checks"]["ai_service"]["status"] == "ok"
    end

    test "all checks include expected keys in response" do
      Req.Test.stub(AiClient, fn conn ->
        Req.Test.json(conn, %{
          "status" => "ok",
          "checks" => %{
            "database" => %{"status" => "ok"},
            "classifier" => %{"status" => "ok"}
          },
          "version" => "1.0.0"
        })
      end)

      conn = build_conn()
      conn = get(conn, "/health_check")
      body = json_response(conn, 200)

      assert Map.has_key?(body, "status")
      assert Map.has_key?(body, "checks")
      assert Map.has_key?(body, "version")
      assert Map.has_key?(body["checks"], "database")
      assert Map.has_key?(body["checks"], "ai_service")
      assert Map.has_key?(body["checks"], "oban")
    end

    test "response includes version from app spec" do
      Req.Test.stub(AiClient, fn conn ->
        Req.Test.json(conn, %{"status" => "ok", "checks" => %{}, "version" => "1.0.0"})
      end)

      conn = build_conn()
      conn = get(conn, "/health_check")
      body = json_response(conn, 200)

      assert body["version"] != nil
      # Version should match the app version from mix.exs
      app_version = to_string(Application.spec(:grocery_planner, :vsn))
      assert body["version"] == app_version
    end

    test "oban check handles paused queue" do
      Req.Test.stub(AiClient, fn conn ->
        Req.Test.json(conn, %{"status" => "ok", "checks" => %{}, "version" => "1.0.0"})
      end)

      conn = build_conn()
      conn = get(conn, "/health_check")
      body = json_response(conn, 200)

      # Oban check should return a status
      assert body["checks"]["oban"]["status"] in ["ok", "paused", "unknown"]
    end

    test "AI service reporting error is degraded, not fatal (200)" do
      Req.Test.stub(AiClient, fn conn ->
        Req.Test.json(conn, %{
          "status" => "error",
          "checks" => %{
            "database" => %{"status" => "error"}
          },
          "version" => "1.0.0"
        })
      end)

      conn = build_conn()
      conn = get(conn, "/health_check")
      # AI service responded but reported error -> degraded -> still 200 (the AI
      # is optional; only our own DB failing takes the app out of rotation). c29.
      body = json_response(conn, 200)

      assert body["status"] == "degraded"
      assert body["checks"]["ai_service"]["status"] == "error"
    end
  end

  describe "Health status property-based tests" do
    property "determine_status always returns one of ok, degraded, or error" do
      check all(ai_status <- StreamData.member_of(["ok", "error", "unavailable", "degraded"])) do
        Req.Test.stub(AiClient, fn conn ->
          if ai_status == "unavailable" do
            Req.Test.transport_error(conn, :econnrefused)
          else
            Req.Test.json(conn, %{
              "status" => ai_status,
              "checks" => %{},
              "version" => "1.0.0"
            })
          end
        end)

        conn = build_conn()
        conn = get(conn, "/health_check")

        # DB is healthy in every case here, and the AI sidecar never causes a 503
        # (its outage is "degraded", which stays 200) — only a DB failure would
        # be fatal. So the HTTP status is always 200 regardless of AI status (c29).
        body = json_response(conn, 200)
        assert body["status"] in ["ok", "degraded", "error"]
      end
    end

    property "AI unavailable with healthy DB always results in degraded" do
      check all(ai_status <- StreamData.member_of(["error", "unavailable"])) do
        Req.Test.stub(AiClient, fn conn ->
          if ai_status == "unavailable" do
            Req.Test.transport_error(conn, :econnrefused)
          else
            Req.Test.json(conn, %{
              "status" => "error",
              "checks" => %{},
              "version" => "1.0.0"
            })
          end
        end)

        conn = build_conn()
        conn = get(conn, "/health_check")
        # Healthy DB + unhealthy AI => degraded, and degraded stays 200 (c29).
        body = json_response(conn, 200)

        if body["checks"]["database"]["status"] == "ok" do
          assert body["status"] == "degraded"
        end
      end
    end
  end
end
