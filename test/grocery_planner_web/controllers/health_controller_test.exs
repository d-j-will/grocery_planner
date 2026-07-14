defmodule GroceryPlannerWeb.HealthControllerTest do
  use GroceryPlannerWeb.ConnCase, async: false

  describe "GET /health_check" do
    test "returns 200 with JSON status when healthy", %{conn: conn} do
      # Stub AI service health check to return healthy
      Req.Test.stub(GroceryPlanner.AiClient, fn conn ->
        Req.Test.json(conn, %{
          "status" => "ok",
          "checks" => %{
            "database" => %{"status" => "ok"},
            "classifier" => %{"status" => "not_loaded"}
          },
          "version" => "1.0.0"
        })
      end)

      conn = get(conn, "/health_check")
      body = json_response(conn, 200)

      assert body["status"] == "ok"
      assert body["checks"]["database"]["status"] == "ok"
      assert body["checks"]["ai_service"]["status"] == "ok"
      assert body["checks"]["oban"] != nil
      assert body["version"] != nil
    end

    test "returns degraded status when AI service is unavailable", %{conn: conn} do
      # Stub AI service to return connection error
      Req.Test.stub(GroceryPlanner.AiClient, fn conn ->
        Plug.Conn.send_resp(conn, 503, "Service Unavailable")
      end)

      conn = get(conn, "/health_check")
      body = json_response(conn, 503)

      assert body["status"] == "degraded"
      assert body["checks"]["database"]["status"] == "ok"
      assert body["checks"]["ai_service"]["status"] == "unavailable"
    end

    test "returns degraded when AI service reports degraded", %{conn: conn} do
      Req.Test.stub(GroceryPlanner.AiClient, fn conn ->
        Req.Test.json(conn, %{
          "status" => "degraded",
          "checks" => %{
            "database" => %{"status" => "error", "error" => "connection refused"}
          },
          "version" => "1.0.0"
        })
      end)

      conn = get(conn, "/health_check")
      body = json_response(conn, 200)

      # AI service responded (not unavailable), and it's degraded but not error
      assert body["status"] == "ok"
      assert body["checks"]["ai_service"]["status"] == "degraded"
    end

    test "always checks database connectivity", %{conn: conn} do
      Req.Test.stub(GroceryPlanner.AiClient, fn conn ->
        Req.Test.json(conn, %{"status" => "ok", "checks" => %{}, "version" => "1.0.0"})
      end)

      conn = get(conn, "/health_check")
      body = json_response(conn, 200)

      assert body["checks"]["database"]["status"] == "ok"
    end

    test "includes oban queue status", %{conn: conn} do
      Req.Test.stub(GroceryPlanner.AiClient, fn conn ->
        Req.Test.json(conn, %{"status" => "ok", "checks" => %{}, "version" => "1.0.0"})
      end)

      conn = get(conn, "/health_check")
      body = json_response(conn, 200)

      assert body["checks"]["oban"] != nil
      assert body["checks"]["oban"]["status"] != nil
    end

    test "returns JSON content type", %{conn: conn} do
      Req.Test.stub(GroceryPlanner.AiClient, fn conn ->
        Req.Test.json(conn, %{"status" => "ok", "checks" => %{}, "version" => "1.0.0"})
      end)

      conn = get(conn, "/health_check")

      assert {"content-type", content_type} =
               List.keyfind(conn.resp_headers, "content-type", 0)

      assert content_type =~ "application/json"
    end
  end

  describe "GET /ready" do
    test "returns 200 ready when the database is reachable", %{conn: conn} do
      # No AI sidecar stub on purpose: readiness must be independent of the
      # optional sidecar, so a degraded/unavailable AI service can't fail /ready.
      conn = get(conn, "/ready")
      body = json_response(conn, 200)

      assert body["status"] == "ready"
    end

    test "does not touch the AI sidecar", %{conn: conn} do
      # If /ready called the AI client, this strict stub would flag an
      # unexpected request; reaching a 200 proves it never calls out.
      Req.Test.stub(GroceryPlanner.AiClient, fn _conn ->
        flunk("/ready must not call the AI sidecar")
      end)

      conn = get(conn, "/ready")
      assert json_response(conn, 200)["status"] == "ready"
    end
  end
end
