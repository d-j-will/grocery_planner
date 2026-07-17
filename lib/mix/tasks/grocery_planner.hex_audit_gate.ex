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
      These were all bump-fixable and their remediation is tracked in
      `grocery_planner-yg5` (the EEF/OSV CVE wave). They were *debt, not
      acceptance*: the baseline let the gate go live before the wave was cleared,
      failing only on advisories **new** relative to that snapshot. As of yg5's
      completion the whole wave is remediated (`mix hex.audit` is clean), so the
      baseline is now **empty** — the target state. It only ever shrinks.

  So: a finding passes iff it is in the allowlist OR the baseline. With both
  empty today, the gate now fails on ANY advisory or retirement — the plain
  `mix hex.audit` semantics, but retaining the allowlist as the reviewed
  safety-valve for a future genuinely-unfixable finding. Delete this task for
  plain `mix hex.audit` once Hex ships real ignore support.
  """

  use Mix.Task

  # {reason, revisit date} — permanent, reviewed acceptances. None yet.
  @allowed_retirements %{}
  @allowed_advisory_ids %{}

  # Retirements known on 2026-07-17. grocery_planner has none.
  @baseline_retirements MapSet.new([])

  # The 2026-07-17 EEF/OSV wave (31 advisories) was fully remediated by
  # grocery_planner-yg5 (ash 3.29 / ecto 3.14 / decimal 3 / ex_money 6 / bandit
  # 1.12 / phoenix 1.8.9 / mint 1.9 / plug 1.20 / postgrex 0.22 / gettext 1.0
  # + patched transitives). `mix hex.audit` is clean, so the baseline is empty:
  # the gate now blocks ANY new advisory. Never re-add fixable advisories here;
  # this set only shrinks.
  @baseline_advisory_ids MapSet.new([])

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
  def evaluate(output, exit_code, opts \\ [])

  def evaluate(_output, 0, _opts), do: :ok

  def evaluate(output, _nonzero_exit_code, opts) do
    covered_advisory_ids =
      Keyword.get(opts, :covered_advisory_ids, default_covered_advisory_ids())

    covered_retirements = Keyword.get(opts, :covered_retirements, default_covered_retirements())

    unknown_retirements = unknown_retirements(output, covered_retirements)
    unknown_advisory_blocks = unknown_advisory_blocks(output, covered_advisory_ids)

    case {unknown_retirements, unknown_advisory_blocks} do
      {[], []} ->
        {:accepted,
         "\nAll hex.audit findings are in the reviewed allowlist. No blocking advisories."}

      {unknown_retirements, unknown_advisory_blocks} ->
        unknown_advisory_ids = Enum.map(unknown_advisory_blocks, &first_advisory_id/1)

        {:error,
         """
         mix hex.audit found advisories not in the reviewed allowlist:
           retirements: #{inspect(unknown_retirements)}
           advisories:  #{inspect(unknown_advisory_ids)}

         Bump/replace the dependency (the yg5 baseline is empty — everything is
         expected to be patched). Only if it is genuinely unfixable and the risk
         is accepted, add a justified, dated entry to the allowlist in
         lib/mix/tasks/grocery_planner.hex_audit_gate.ex.
         """}
    end
  end

  # Default coverage = permanent allowlist ∪ (now-empty) yg5 baseline. Passed
  # explicitly by tests so the alias/coverage logic can be exercised without
  # depending on whatever the live baseline happens to hold.
  defp default_covered_advisory_ids do
    @allowed_advisory_ids |> Map.keys() |> MapSet.new() |> MapSet.union(@baseline_advisory_ids)
  end

  defp default_covered_retirements do
    @allowed_retirements |> Map.keys() |> MapSet.new() |> MapSet.union(@baseline_retirements)
  end

  defp unknown_retirements(output, covered_retirements) do
    ~r/^\s*([a-z0-9_]+)\s+\S+\s+-\s+\(deprecated\)/m
    |> Regex.scan(output)
    |> Enum.map(fn [_, package] -> package end)
    |> Enum.uniq()
    |> Enum.reject(&MapSet.member?(covered_retirements, &1))
  end

  # Each advisory block lists several aliases for the SAME finding (its primary
  # EEF-CVE id plus "aka: CVE-..., GHSA-..."). Split on blank lines so a block is
  # covered if ANY of its aliases is known, rather than requiring every alias.
  defp unknown_advisory_blocks(output, covered_advisory_ids) do
    output
    |> String.split(~r/\n\s*\n/)
    |> Enum.filter(&(&1 =~ ~r/\bCVE-\d{4}-\d+\b/ or &1 =~ ~r/\bGHSA-[a-z0-9-]+\b/))
    |> Enum.reject(fn block ->
      Enum.any?(advisory_ids(block), &MapSet.member?(covered_advisory_ids, &1))
    end)
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
