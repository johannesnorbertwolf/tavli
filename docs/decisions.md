Training decisions:
1. Always train with terminal reward only (no shaped rewards).

---

# iPad app / Swift port decisions

Context: we are building a native, offline iPad app for the trained Plakoto AI
(Android intended later). These are the architectural decisions made for that effort.

1. **On-device, fully offline (no server).** The value network is converted to Core ML
   and the game engine + board encoder are re-implemented in Swift, so the app needs no
   network and works fully offline. (Alternative considered: a Python server with a thin
   client — rejected because offline play is a hard requirement and a server adds hosting,
   latency, and App Store fragility.)

2. **Fresh Swift port, not a revival of the old `ui` worktree.** A prior Swift attempt
   exists on disk at `.claude/worktrees/ui/ios/` but is orphaned and stale (built for an
   old 10-point/5-piece prototype with the `legacy_unary_v1` encoder and an old model).
   We re-ported cleanly against the *current* `hopeful`-lineage Python, using the old tree
   only as a structural reference. Its faithful, idiomatic `final class` design (Point /
   HalfMove / GameBoard as reference types so a HalfMove mutates the board on apply) was
   well worth reusing.

3. **Native SwiftUI now; Android later.** Best iPad result and learning path. Because the
   engine + model are shared (Swift package + Core ML), a future Android app only needs a
   new UI layer, not a new brain.

4. **Parity-gated.** The port is validated against the Python source of truth via
   JSON fixtures: identical board encodings, identical legal-move sets, and identical 1-ply
   move scores / best-move choices. The Swift test suite is the gate (see
   `docs/ios_port_plan.md`). This is the guard against silent divergence — the main risk of
   an on-device re-implementation.

5. **Core ML model outputs win probability (sigmoid), CPU compute units in tests.** The
   exported model traces `BoardEvaluator.forward` (sigmoid of logits), matching what the
   Python `Agent` calls. Parity tests pin `computeUnits = .cpuOnly` to match Python CPU
   inference and avoid Apple Neural Engine float drift.

6. **Migrated onto domain v2; Swift kept OO.** The port was originally built against the
   retired v1 OO domain (`possible_moves.py`, `point.py`, `half_move.py`, `Color` enum). `main`
   later rewrote the domain to v2 (array-based `Board`, `move_generation.legal_moves`, int
   colors in `constants.py`, `NamedTuple` moves). We re-pointed the parity fixture generator
   (`ios/scripts/generate_test_fixtures.py`) at v2 and regenerated fixtures + the Core ML model;
   `convert_to_coreml.py` needed no change (it only touches `config` + `checkpoint_io`). The
   Swift engine was **not** rewritten to arrays — it kept its OO / reference-type structure and
   passed the regenerated v2 fixtures unchanged, confirming v2 is behavior-preserving and that
   the parity gate (not structural sameness) is what guarantees correctness.

7. **"AI" stays "AI" in every language, never localized.** In the German (and any other)
   localization the term "AI" is kept verbatim — it is **not** translated to "KI" (or any
   local equivalent). This is a deliberate branding/consistency choice: the label reads the
   same across all locales. When reviewing or adding translations, leave "AI" as-is; do not
   "fix" it to "KI". (Affected strings in `ios/TavliApp/TavliApp/Localizable.xcstrings`
   include "Play vs AI" → "Gegen AI spielen", "Animate AI moves" → "AI-Züge animieren", etc.)
