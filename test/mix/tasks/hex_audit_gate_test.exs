defmodule Mix.Tasks.GroceryPlanner.HexAuditGateTest do
  @moduledoc """
  Boundary tests for the ratcheting hex.audit gate's pure decision core:
  covered findings (allowlist ∪ baseline) pass; anything else fails. The yg5
  baseline is empty now, so coverage is injected explicitly via `evaluate/3`'s
  `:covered_advisory_ids` to exercise the alias/coverage logic on its own terms.
  """
  use ExUnit.Case, async: true

  alias Mix.Tasks.GroceryPlanner.HexAuditGate

  # An advisory block whose primary id we treat as covered in the tests below.
  @covered_id "CVE-2026-39806"
  @covered_set MapSet.new([@covered_id])

  defp known_block do
    """
    Advisories:
      bandit 1.8.0 - EEF-CVE-2026-39806 (HIGH)
        aka: CVE-2026-39806, GHSA-rf5q-vwxw-gmrf
        HTTP/1 chunked decoder infinite loop on requests with trailer fields in bandit
        https://osv.dev/vulnerability/EEF-CVE-2026-39806
    """
  end

  # A block for an advisory that is NOT in the baseline (a future/new one).
  defp new_block do
    """
      somelib 9.9.9 - EEF-CVE-2099-00001 (HIGH)
        aka: CVE-2099-00001, GHSA-aaaa-bbbb-cccc
        A brand new advisory that appeared after the baseline snapshot
        https://osv.dev/vulnerability/EEF-CVE-2099-00001
    """
  end

  test "exit code 0 means hex.audit found nothing — pass" do
    assert HexAuditGate.evaluate("", 0) == :ok
  end

  test "a finding in the covered set is accepted" do
    assert {:accepted, msg} =
             HexAuditGate.evaluate(known_block(), 1, covered_advisory_ids: @covered_set)

    assert msg =~ "No blocking advisories"
  end

  test "with the empty default baseline, any advisory fails the gate" do
    assert {:error, msg} = HexAuditGate.evaluate(known_block(), 1)
    assert msg =~ "not in the reviewed allowlist"
    assert msg =~ "CVE-2026-39806"
  end

  test "an advisory outside the covered set fails the gate" do
    assert {:error, msg} =
             HexAuditGate.evaluate(new_block(), 1, covered_advisory_ids: @covered_set)

    assert msg =~ "not in the reviewed allowlist"
    assert msg =~ "CVE-2099-00001"
  end

  test "an uncovered advisory fails even when a covered advisory is also present" do
    assert {:error, msg} =
             HexAuditGate.evaluate(known_block() <> "\n" <> new_block(), 1,
               covered_advisory_ids: @covered_set
             )

    assert msg =~ "CVE-2099-00001"
    # the covered bandit advisory must NOT be reported
    refute msg =~ "CVE-2026-39806"
  end

  test "a NEW retirement fails the gate" do
    retired = """
    Retired:
      somelib 1.2.3 - (deprecated) somelib is no longer maintained.
    """

    assert {:error, msg} = HexAuditGate.evaluate(retired, 1)
    assert msg =~ "retirements"
    assert msg =~ "somelib"
  end

  test "a block matches on any of its aliases, not just the primary id" do
    # Same advisory, but the block leads with the GHSA alias; the CVE alias is
    # still present and in the covered set, so the block is covered.
    ghsa_first = """
      bandit 1.8.0 - GHSA-rf5q-vwxw-gmrf (HIGH)
        aka: CVE-2026-39806
        https://osv.dev/vulnerability/EEF-CVE-2026-39806
    """

    assert {:accepted, _} =
             HexAuditGate.evaluate(ghsa_first, 1, covered_advisory_ids: @covered_set)
  end
end
