defmodule Mix.Tasks.GroceryPlanner.HexAuditGateTest do
  @moduledoc """
  Boundary tests for the ratcheting hex.audit gate's pure decision core:
  known findings (allowlist + yg5 baseline) pass; anything NEW fails.
  """
  use ExUnit.Case, async: true

  alias Mix.Tasks.GroceryPlanner.HexAuditGate

  # A block using a baseline CVE id (bandit HIGH, in the 2026-07-17 snapshot).
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

  test "a finding already in the yg5 baseline is accepted" do
    assert {:accepted, msg} = HexAuditGate.evaluate(known_block(), 1)
    assert msg =~ "No NEW advisories"
  end

  test "a NEW advisory (not baseline, not allowlisted) fails the gate" do
    assert {:error, msg} = HexAuditGate.evaluate(new_block(), 1)
    assert msg =~ "NEW issues"
    assert msg =~ "CVE-2099-00001"
  end

  test "a NEW advisory fails even when known baseline advisories are also present" do
    assert {:error, msg} = HexAuditGate.evaluate(known_block() <> "\n" <> new_block(), 1)
    assert msg =~ "CVE-2099-00001"
    # the known bandit advisory must NOT be reported as new
    refute msg =~ "CVE-2026-39806"
  end

  test "a NEW retirement fails the gate" do
    retired = """
    Retired:
      somelib 1.2.3 - (deprecated) somelib is no longer maintained.
    """

    assert {:error, msg} = HexAuditGate.evaluate(retired, 1)
    assert msg =~ "new retirements"
    assert msg =~ "somelib"
  end

  test "a block matches on any of its aliases, not just the primary id" do
    # Same advisory, but the block leads with the GHSA alias; the CVE alias is
    # still present and in the baseline, so it is covered.
    ghsa_first = """
      bandit 1.8.0 - GHSA-rf5q-vwxw-gmrf (HIGH)
        aka: CVE-2026-39806
        https://osv.dev/vulnerability/EEF-CVE-2026-39806
    """

    assert {:accepted, _} = HexAuditGate.evaluate(ghsa_first, 1)
  end
end
