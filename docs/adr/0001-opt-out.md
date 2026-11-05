# ADR 0001: opt-out switch `setEnabled(false)`

Date: 5 Nov 2026 · Status: accepted · Backlog: td2-27 · Same design as strait-sdk-react-native ADR 0002 (also -web, -android, -flutter)

## Problem
Apps in India (DPDP Act) and the EU (GDPR) often have to ask a person for consent before an attribution SDK
sends anything. Without a switch they must not start Strait at all, which also loses the deferred link, or
they pick a rival SDK that has one (Branch documents `disableTracking`; Adjust documents an enabled switch).

## Who it serves
App teams with a consent screen: one call when the person says no, one when they say yes.

## Options
1. **Do nothing**: apps skip `start()` until consent. Loses direct-link routing and the install's deferred link.
2. **A config flag at create time only**: can't change after a consent answer without recreating the client.
3. **A persisted runtime switch** `setEnabled(_:completion:)` + `isEnabled`, default on. **Chosen.**

## Design
- Stored as `strait.enabled` (`"0"` / `"1"`) in the configured `StraitStorage` (default `UserDefaults`); absent = on.
  `isEnabled` reads storage each time (UserDefaults is thread-safe), so no in-memory copy can drift.
- Off: every engine call is refused in the one HTTP helper (belt), and each entry point returns early (braces):
  no `/v1/open`, `/v1/event`, `/v1/match`, `/v1/handoff/claim`, `/v1/resolve`, `/v1/store-sheet`, `/v1/match-save`,
  debug fingerprint. Nothing is queued and no tap id is remembered. Turning it off deletes the saved queue and
  the remembered tap (data collected for sending is not sent after the person said no).
- Links: a link that carries its own destination (Universal Link to your own domain, custom scheme) still reaches the
  link callback, unreported. A Strait short link needs `/v1/resolve`, which records the tap, so it returns
  `matched: false, reason: "disabled"`; the app can open it in the browser if it wants.
- First launch while off: the once-per-install check is not marked done. `setEnabled(true)` in the same launch
  runs it then (the usual "consent screen on first launch" flow keeps its deferred link); otherwise the next
  start does.
- `doctor()` (a setup check that reads the public AASA / assetlinks file) is not a report and still works.

## Security lens
Spoofing / tampering: none new (local flag in the app's sandbox). Data exposure: the point of the change;
accepted risk = a storage read that fails reads as "on". Abuse / DoS: none (fewer requests).

## Architecture lens
No engine or wire change. Follow-up E3 (engine): a lookup-only `/v1/resolve` (`record:false`) would let short
links route while opted out.
