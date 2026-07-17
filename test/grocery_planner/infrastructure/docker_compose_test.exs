defmodule GroceryPlanner.Infrastructure.DockerComposeTest do
  use ExUnit.Case, async: true

  @docker_compose_path Path.join([File.cwd!(), "docker-compose.yml"])

  describe "docker-compose.yml validation" do
    test "file exists and is readable" do
      assert File.exists?(@docker_compose_path),
             "docker-compose.yml not found at #{@docker_compose_path}"

      assert File.regular?(@docker_compose_path), "docker-compose.yml is not a regular file"
    end

    test "file contains valid YAML structure" do
      content = File.read!(@docker_compose_path)

      # Basic YAML validation - should have proper structure
      assert content =~ "services:", "Missing 'services:' key"
      assert content =~ "volumes:", "Missing 'volumes:' key"

      # Should not have syntax errors (no tabs, proper indentation)
      refute String.contains?(content, "\t"), "YAML should not contain tabs"
    end

    test "required services are defined" do
      content = File.read!(@docker_compose_path)

      assert content =~ ~r/^\s*postgres:/m, "postgres service not defined"
      assert content =~ ~r/^\s*python-service:/m, "python-service not defined"
      assert content =~ ~r/^\s*elixir-app:/m, "elixir-app service not defined"
    end

    test "postgres service has healthcheck configured" do
      content = File.read!(@docker_compose_path)

      # Find postgres service section
      assert content =~ ~r/postgres:.*healthcheck:/s,
             "postgres service missing healthcheck configuration"

      assert content =~ ~r/healthcheck:.*test:.*pg_isready/s,
             "postgres healthcheck missing pg_isready test"

      assert content =~ ~r/healthcheck:.*interval:/s, "postgres healthcheck missing interval"
      assert content =~ ~r/healthcheck:.*timeout:/s, "postgres healthcheck missing timeout"
      assert content =~ ~r/healthcheck:.*retries:/s, "postgres healthcheck missing retries"
    end

    test "python-service depends on postgres" do
      content = File.read!(@docker_compose_path)

      # Check python-service has depends_on
      assert content =~ ~r/python-service:.*depends_on:/s,
             "python-service missing depends_on"

      # Check it depends on postgres with health condition
      assert content =~ ~r/depends_on:.*postgres:.*condition: service_healthy/s,
             "python-service should depend on postgres with health condition"
    end

    test "python-service has healthcheck configured" do
      content = File.read!(@docker_compose_path)

      assert content =~ ~r/python-service:.*healthcheck:/s,
             "python-service missing healthcheck configuration"

      assert content =~ ~r/healthcheck:.*test:.*curl.*health/s,
             "python-service healthcheck should use curl to /health endpoint"
    end

    test "elixir-app depends on postgres and python-service" do
      content = File.read!(@docker_compose_path)

      assert content =~ ~r/elixir-app:.*depends_on:.*postgres:/s,
             "elixir-app should depend on postgres"

      assert content =~ ~r/elixir-app:.*depends_on:.*python-service:/s,
             "elixir-app should depend on python-service"
    end

    test "elixir-app waits only for the sidecar to START, not be healthy (c29)" do
      content = File.read!(@docker_compose_path)

      # The only `python-service:` entry followed by a `condition:` is elixir-app's
      # depends_on (the service *definition* is followed by `build:`). The AI
      # sidecar is optional: its health reports "degraded" and the app must boot
      # without it, so the condition is service_started, never service_healthy.
      assert content =~ ~r/python-service:\n(\s*#.*\n)*\s*condition: service_started/,
             "elixir-app should depend on python-service with service_started"

      refute content =~ ~r/python-service:\n(\s*#.*\n)*\s*condition: service_healthy/,
             "elixir-app must not hard-depend on python-service health (c29)"
    end

    test "elixir-app has a readiness healthcheck hitting /ready (c29)" do
      content = File.read!(@docker_compose_path)

      assert content =~ ~r/elixir-app:.*healthcheck:/s,
             "elixir-app missing healthcheck configuration"

      assert content =~ ~r/elixir-app:.*healthcheck:.*test:.*curl.*\/ready/s,
             "elixir-app healthcheck should curl the /ready readiness endpoint"
    end

    test "required environment variables are set for postgres" do
      content = File.read!(@docker_compose_path)

      assert content =~ ~r/postgres:.*environment:/s, "postgres missing environment section"
      assert content =~ "POSTGRES_USER:", "postgres missing POSTGRES_USER"
      assert content =~ "POSTGRES_PASSWORD:", "postgres missing POSTGRES_PASSWORD"
      assert content =~ "POSTGRES_DB:", "postgres missing POSTGRES_DB"
    end

    test "required environment variables are set for python-service" do
      content = File.read!(@docker_compose_path)

      assert content =~ ~r/python-service:.*environment:/s,
             "python-service missing environment section"

      # Check for common Python service env vars
      assert content =~ ~r/python-service:.*environment:.*DEBUG/s,
             "python-service should have DEBUG configured"
    end

    test "required environment variables are set for elixir-app" do
      content = File.read!(@docker_compose_path)

      assert content =~ ~r/elixir-app:.*environment:/s, "elixir-app missing environment section"
      assert content =~ "DATABASE_URL:", "elixir-app missing DATABASE_URL"
      assert content =~ "AI_SERVICE_URL:", "elixir-app missing AI_SERVICE_URL"
      assert content =~ "SECRET_KEY_BASE:", "elixir-app missing SECRET_KEY_BASE"
      assert content =~ "MIX_ENV:", "elixir-app missing MIX_ENV"
    end

    test "port mappings are correct" do
      content = File.read!(@docker_compose_path)

      # Postgres port
      assert content =~ ~r/postgres:.*ports:.*5432:5432/s,
             "postgres port mapping incorrect or missing"

      # Python service port
      assert content =~ ~r/python-service:.*ports:.*8000:8000/s,
             "python-service port mapping incorrect or missing"

      # Elixir app port
      assert content =~ ~r/elixir-app:.*ports:.*4000:4000/s,
             "elixir-app port mapping incorrect or missing"
    end

    test "volumes are defined for data persistence" do
      content = File.read!(@docker_compose_path)

      # Check top-level volumes section
      assert content =~ ~r/^volumes:/m, "Missing top-level volumes section"
      assert content =~ "postgres-data:", "Missing postgres-data volume definition"

      # Check postgres service uses the volume
      assert content =~ ~r/postgres:.*volumes:.*postgres-data/s,
             "postgres service not using postgres-data volume"

      # Check volume is mounted to correct path
      assert content =~ "postgres-data:/var/lib/postgresql/data",
             "postgres-data volume not mounted to correct path"
    end

    test "python-service has source code volume mount for development" do
      content = File.read!(@docker_compose_path)

      # Check python-service has volumes section
      assert content =~ ~r/python-service:.*volumes:/s, "python-service missing volumes section"

      # Check it mounts the source code
      assert content =~ ~r/python-service:.*volumes:.*\.\/python_service:/s,
             "python-service should mount ./python_service for development"
    end

    test "services use correct Docker images or build context" do
      content = File.read!(@docker_compose_path)

      # Postgres uses pgvector image (postgres + vector extensions)
      assert content =~ ~r/postgres:.*image: pgvector\/pgvector:pg/s,
             "postgres should use pgvector image"

      # Python service uses build
      assert content =~ ~r/python-service:.*build:/s, "python-service should use build"

      assert content =~ ~r/build:.*context: \.\/python_service/s,
             "python-service build context incorrect"

      # Elixir app uses build
      assert content =~ ~r/elixir-app:.*build:/s, "elixir-app should use build"
      assert content =~ ~r/build:.*context: \./s, "elixir-app build context should be root"
    end

    test "elixir-app has correct startup command" do
      content = File.read!(@docker_compose_path)

      # Check for command that runs migrations and starts server
      assert content =~ ~r/elixir-app:.*command:/s, "elixir-app missing command"

      assert content =~ ~r/command:.*mix ash\.setup/s,
             "elixir-app should run mix ash.setup"

      assert content =~ ~r/command:.*mix phx\.server/s,
             "elixir-app should run mix phx.server"
    end

    test "DATABASE_URL references postgres service name" do
      content = File.read!(@docker_compose_path)

      # DATABASE_URL should use 'postgres' as hostname (Docker service name)
      assert content =~ ~r/DATABASE_URL:.*postgres:\/\/.*@postgres:/s,
             "DATABASE_URL should reference postgres service by name"
    end

    test "AI_SERVICE_URL references python-service by name" do
      content = File.read!(@docker_compose_path)

      # AI_SERVICE_URL should use 'python-service' as hostname
      assert content =~ ~r/AI_SERVICE_URL:.*http:\/\/python-service:/s,
             "AI_SERVICE_URL should reference python-service by name"
    end
  end

  describe "docker-compose.yml service dependency order" do
    test "dependency chain is correct: postgres -> python-service -> elixir-app" do
      content = File.read!(@docker_compose_path)

      # Parse the dependency relationships
      # postgres has no dependencies
      postgres_section = extract_service_section(content, "postgres")
      refute postgres_section =~ "depends_on:", "postgres should not have dependencies"

      # python-service depends only on postgres
      python_section = extract_service_section(content, "python-service")

      assert python_section =~ "depends_on:", "python-service should have dependencies"
      assert python_section =~ "postgres:", "python-service should depend on postgres"

      # elixir-app depends on both
      elixir_section = extract_service_section(content, "elixir-app")
      assert elixir_section =~ "depends_on:", "elixir-app should have dependencies"
      assert elixir_section =~ "postgres:", "elixir-app should depend on postgres"
      assert elixir_section =~ "python-service:", "elixir-app should depend on python-service"
    end
  end

  # Helper function to extract a service section from docker-compose.yml
  defp extract_service_section(content, service_name) do
    # Split by service boundaries and find the matching service
    lines = String.split(content, "\n")
    service_start = Enum.find_index(lines, &(&1 =~ ~r/^\s*#{service_name}:/))

    if service_start do
      # Find the end of this service (next service at same indentation level or end of file)
      service_lines =
        lines
        |> Enum.slice((service_start + 1)..-1//1)
        |> Enum.take_while(fn line ->
          # Continue until we hit another service at same level (2 spaces + word + colon)
          # or a top-level key (word + colon at start of line)
          # Empty lines and indented lines (4+ spaces) are part of the current service
          cond do
            String.trim(line) == "" -> true
            String.match?(line, ~r/^[a-z]/) -> false
            String.match?(line, ~r/^  [a-z][a-z_-]+:/) -> false
            true -> true
          end
        end)

      Enum.join([Enum.at(lines, service_start) | service_lines], "\n")
    else
      ""
    end
  end
end
