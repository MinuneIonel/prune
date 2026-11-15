# Contributing

Thanks for looking. Major Tom deletes files, so a few rules are not up for debate.

## Safety rules (non-negotiable)

1. **Never run a real clean while developing.** No real clean, Trash, hibernate or offload on your own Mac while
   working on the code. Real-machine checks are scan / list / dry run only: `swift run majortom scan`,
   `majortom projects`, `majortom offload`, `majortom clean` *without* `--execute`, or the app without confirming
   anything.
2. **Exercise flows in fixture mode or tests.** `MajorTom --fixture` (or `MAJORTOM_FIXTURE=1`) runs the app against a
   throwaway fake home in the temp folder with simulated commands, a fixture Trash folder and a fake NAS share.
   Tests build their own fixture trees and never read your real home.
3. **Dry run stays the default.** Every clean / hibernate / offload API and the CLI must keep defaulting to dry run,
   and every path must still go through `PathValidator` right before acting.
4. **User files only ever go to the Trash.** Never delete review-tier user data outright.
5. **No `sudo`.** Admin-only fixes are shown as a command for the user to run, never executed.

## Changes

- `swift build && swift test` must pass with no new warnings.
- **New rules need tests**: add the rule id to `RuleTests.catalogueIsComplete`, a fixture test in `RuleTests`, and
  make sure it resolves to nothing on an empty home (covered by `PortabilityTests`). Fill in `impact`, `recovery`
  and `regenCost` honestly; that text is the point of the app.
- New clean methods need engine tests for dry run, execute (fixture only) and refusal paths.
- See [CLAUDE.md](CLAUDE.md) for the code layout, conventions and step-by-step guides, and [SPEC.md](SPEC.md) for
  the behaviour and safety model.
- Keep screenshots and examples free of personal data: capture them in fixture mode only.

This is a personal project maintained in spare time, so reviews may be slow. Issues describing what a rule got wrong
on your Mac (paths, sizes, tool versions) are especially useful.
