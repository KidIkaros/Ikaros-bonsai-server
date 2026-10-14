# Error-Handling Systems Audit — Kiln

Audited Kiln's error handling as a *system* through Meadows' leverage-point
lens (via the `systems-thinking-audit` skill). Method: mapped the error surface
empirically (probed real exit codes, read the dispatcher, traced recovery), then
ranked gaps by leverage. The dominant finding: **Kiln has good error messages
and consistent failure exit codes, but was missing a validation loop on
subcommand flags.**

## The error system as mapped

| Layer | Mechanism | State (pre-fix) |
|---|---|---|
| Message emission | `err`/`warn`/`info` → stderr, colored | Good |
| Failure exit | `die`→1, `usage_die`→2 | Consistent |
| Command validation | unknown command → rc 2 + did-you-mean | Good |
| **Flag validation** | **none — subcommands ignored unknown flags** | **Missing (F1)** |
| Recovery | failed start leaves clean, retryable state | Good |
| Next-action hints | most `die` messages name the fix | Good |

## Findings

| # | Leverage | Gap | Severity | Disposition |
|---|---|---|---|---|
| F1 | #5 info flow (missing) | Subcommands silently accepted unknown flags, exit 0 | HIGH | **Fixed** |
| F2 | #7 balancing loop (weak) | typo-suggestion existed for commands, not flags | MED | **Fixed** (shares F1's loop) |
| F3 | #5 info flow (partial) | failed start leaves `detect.env`; error doesn't say "safe to retry" | LOW | Accepted (state is clean; retry works) |
| F4 | #11 parameters | `set -u` vs `set -euo pipefail` inconsistency | LOW | **Discharged — false positive** |

### F4 discharged, not fixed

Two scripts use `set -u` where others use `set -euo pipefail`. This looks like
an inconsistency but is **correct by design**, verified before changing:

- `install-hermes-skill.sh` — its contract is "never fail the parent install."
  Every path `exit 0`s explicitly with `|| true` guards. Adding `set -e` would
  let a benign failure abort mid-install, breaking the guarantee it exists for.
- `kiln-dash.sh` — its interactive `read` loop relies on `read` returning
  non-zero at EOF (that is how the loop continues). `set -e` would abort the
  dashboard the instant the user hits Ctrl-D or a read times out.

The audit discipline: **verify design intent before counting a gap.** A pattern
that looks like drift can be the correct strictness for that contract.

## The fix (LP #5 — a missing information flow)

A shared guard in `scripts/lib/common.sh`:

- `reject_any_flags CTX` — for no-flag subcommands (status, show, models, stop,
  restart, dash): any `-...` argument is a usage error, exit 2.
- `reject_unknown_flags CTX ALLOWED -- ARGS` — for subcommands with real flags
  (logs `-f`, fastest `--json`): an unknown flag exits 2, with a did-you-mean
  when within edit distance 1 of an allowed flag.
- `edit_distance` / `suggest_near` — extracted so command and flag suggestions
  share one distance function. The dispatcher's inline `suggest_cmd` now calls
  `suggest_near`; command behavior is unchanged (proven by test).

Three bugs were caught by *testing* the fix, not reading it:

1. The first form had no allowed-list separation, so a no-flag command's own
   bad flag became its allowed set and passed itself → split into
   `reject_any_flags`.
2. The guards were called without forwarding `"$@"`, so they never saw the
   user's args → fixed to pass `"$@"`.
3. A single-stream `reject_unknown_flags` let a user's bad flag land in the
   allowed list → added the `--` separator.

## Verification

13 regression tests pin the contract: no-flag rejection (rc 2), real-flag
rejection (rc 2), valid flags still pass (rc 0), near-miss flag suggests the
real one, far-miss flag declines to guess (honest plain pointer, same rule as
commands), and the command did-you-mean is unchanged after the refactor.
