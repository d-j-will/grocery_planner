defmodule Mix.Tasks.GroceryPlanner.HexAuditGate do
  @shortdoc "Runs mix hex.audit, failing only on advisories/retirements not already known"

  @moduledoc """
  Ratcheting wrapper around `mix hex.audit`.

  Released Hex (2.5.0, latest as of 2026-07-17) has no built-in way to
  acknowledge a specific advisory or retirement — `ignore_advisories` /
  `ignore_retirements` only exist on Hex's unreleased `main`. Until that ships,
  this task text-parses `mix hex.audit` and diffs it against two layers:

    * `@allowed_*` — **intentional, permanent** acceptances (a risk we have
      reviewed and chosen to carry, e.g. an unfixable retired dep). Empty today.
    * `@baseline_*` — a **snapshot of the advisories already open on 2026-07-17**.
      These are all bump-fixable and their remediation is tracked in
      `grocery_planner-yg5` (the EEF/OSV CVE wave). They are *debt, not
      acceptance*: the baseline exists so the gate can go live NOW — failing on
      any advisory that is **new** relative to that snapshot — without turning CI
      permared on the known backlog. As `yg5` bumps the affected deps, delete the
      corresponding baseline ids; the target is an empty baseline.

  So: a finding passes iff it is in the allowlist OR the baseline. Anything
  else fails the gate. Delete this task for plain `mix hex.audit` once Hex ships
  real ignore support (or once baseline + allowlist are both empty).
  """

  use Mix.Task

  # {reason, revisit date} — permanent, reviewed acceptances. None yet.
  @allowed_retirements %{}
  @allowed_advisory_ids %{}

  # Retirements known on 2026-07-17. grocery_planner has none.
  @baseline_retirements MapSet.new([])

  # Advisories open on 2026-07-17 — the EEF/OSV wave, all bump-fixable, tracked
  # in grocery_planner-yg5. Shrink this to empty as the deps are patched.
  # (Storing one id per advisory is enough: a block passes if ANY of its ids is
  # covered, and every block here carries its CVE-2026-* id.)
  @baseline_advisory_ids MapSet.new([
                           "CVE-2026-8468",
                           "CVE-2026-32686",
                           "CVE-2026-32687",
                           "CVE-2026-32689",
                           "CVE-2026-34593",
                           "CVE-2026-39803",
                           "CVE-2026-39804",
                           "CVE-2026-39805",
                           "CVE-2026-39806",
                           "CVE-2026-39807",
                           "CVE-2026-42786",
                           "CVE-2026-42788",
                           "CVE-2026-48861",
                           "CVE-2026-48862",
                           "CVE-2026-49753",
                           "CVE-2026-49754",
                           "CVE-2026-49755",
                           "CVE-2026-49756",
                           "CVE-2026-54892",
                           "CVE-2026-54893",
                           "CVE-2026-55736",
                           "CVE-2026-56810",
                           "CVE-2026-56811",
                           "CVE-2026-56812",
                           "CVE-2026-56813",
                           "CVE-2026-56814",
                           "CVE-2026-58225",
                           "CVE-2026-58226",
                           "CVE-2026-58229",
                           "CVE-2026-59246",
                           "CVE-2026-59249"
                         ])

  @impl Mix.Task
  def run(_args) do
    {output, exit_code} = System.cmd("mix", ["hex.audit"], stderr_to_stdout: true)
    Mix.shell().info(output)

    case evaluate(output, exit_code) do
      :ok ->
        :ok

      {:accepted, message} ->
        Mix.shell().info(message)

      {:error, message} ->
        Mix.raise(message)
    end
  end

  @doc """
  Pure decision core: given `mix hex.audit`'s raw output and exit code, decides
  whether every finding is either permanently allowlisted or in the known
  baseline. No IO — text in, decision out.
  """
  def evaluate(_output, 0), do: :ok

  def evaluate(output, _nonzero_exit_code) do
    unknown_retirements = unknown_retirements(output)
    unknown_advisory_blocks = unknown_advisory_blocks(output)

    case {unknown_retirements, unknown_advisory_blocks} do
      {[], []} ->
        {:accepted,
         "\nAll hex.audit findings are known (allowlist + grocery_planner-yg5 baseline). " <>
           "No NEW advisories."}

      {unknown_retirements, unknown_advisory_blocks} ->
        unknown_advisory_ids = Enum.map(unknown_advisory_blocks, &first_advisory_id/1)

        {:error,
         """
         mix hex.audit found NEW issues (not allowlisted and not in the yg5 baseline):
           new retirements: #{inspect(unknown_retirements)}
           new advisories:  #{inspect(unknown_advisory_ids)}

         Either bump/replace the dependency, or — if it is genuinely unfixable and
         the risk is accepted — add a justified, dated entry to the allowlist in
         lib/mix/tasks/grocery_planner.hex_audit_gate.ex. Do NOT add fixable
         advisories to the baseline; that set only shrinks.
         """}
    end
  end

  defp unknown_retirements(output) do
    ~r/^\s*([a-z0-9_]+)\s+\S+\s+-\s+\(deprecated\)/m
    |> Regex.scan(output)
    |> Enum.map(fn [_, package] -> package end)
    |> Enum.uniq()
    |> Enum.reject(&covered_retirement?/1)
  end

  # Each advisory block lists several aliases for the SAME finding (its primary
  # EEF-CVE id plus "aka: CVE-..., GHSA-..."). Split on blank lines so a block is
  # covered if ANY of its aliases is known, rather than requiring every alias.
  defp unknown_advisory_blocks(output) do
    output
    |> String.split(~r/\n\s*\n/)
    |> Enum.filter(&(&1 =~ ~r/\bCVE-\d{4}-\d+\b/ or &1 =~ ~r/\bGHSA-[a-z0-9-]+\b/))
    |> Enum.reject(fn block -> Enum.any?(advisory_ids(block), &covered_advisory?/1) end)
  end

  defp covered_retirement?(package) do
    Map.has_key?(@allowed_retirements, package) or MapSet.member?(@baseline_retirements, package)
  end

  defp covered_advisory?(id) do
    Map.has_key?(@allowed_advisory_ids, id) or MapSet.member?(@baseline_advisory_ids, id)
  end

  defp advisory_ids(text) do
    ~r/\b(CVE-\d{4}-\d+|GHSA-[a-z0-9-]+)\b/
    |> Regex.scan(text, capture: :all_but_first)
    |> List.flatten()
  end

  defp first_advisory_id(block) do
    case advisory_ids(block) do
      [id | _] -> id
      [] -> block
    end
  end
end
