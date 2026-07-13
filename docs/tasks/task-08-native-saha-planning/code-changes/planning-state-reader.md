# Code Change: `PlanningStateReader`

**Type:** Internal Swift interface
**Module:** GhostlingCore
**Status:** Draft

## Overview

Produces a `PlanningState` for a bound task folder, preferring `saha plan-status --json` when available and falling back to marker-scraping the folder's README/artifact `**Status:**` lines otherwise (US-003 AC3). Re-parses on `FileWatcher` events, debounced so a burst of writes yields one re-parse, not one-per-write.

## Interface

```swift
// wireName is the ONE canonical string identity for a step, shared across every
// boundary in this feature: the CLI's `checks[].name`/`next_step` (plan-status-json-cli.md),
// this enum's Swift identity, and test fixtures. All three MUST use this exact string set.
enum PlanningStep: String, CaseIterable {
    case research, taskDescription, userStories, designDecisions
    case codeChanges, testSpecs, implementationPlan, verify

    // snake_case — matches saha CLI JSON exactly, e.g. "design_decisions"
    var wireName: String {
        switch self {
        case .research: return "research"
        case .taskDescription: return "task_description"
        case .userStories: return "user_stories"
        case .designDecisions: return "design_decisions"
        case .codeChanges: return "code_changes"
        case .testSpecs: return "test_specs"
        case .implementationPlan: return "implementation_plan"
        case .verify: return "verify"
        }
    }

    init?(wireName: String) {
        guard let match = Self.allCases.first(where: { $0.wireName == wireName }) else { return nil }
        self = match
    }

    var command: String {
        switch self {
        case .research: return "/saha:research"
        case .taskDescription: return "/saha:task"
        case .userStories: return "/saha:stories"
        case .designDecisions: return "/saha:decide"
        case .codeChanges: return "/saha:contracts"
        case .testSpecs: return "/saha:test-specs"
        case .implementationPlan: return "/saha:plan"
        case .verify: return "/saha:verify"
        }
    }
}

// ArtifactStatus is what `parseStatus` reads off a raw `**Status:**` line (e.g. "Draft",
// "In Progress", "Done", "Approved") — free-form per saha's templates. It is DISTINCT from
// StepStatus, which is the coarser done/pending/unknown state a whole pipeline STEP resolves
// to (a step can have several artifacts at different ArtifactStatus values; the step itself
// is only ever done/pending/unknown). Mapping: "Done"/"Approved" -> .done; anything else
// present -> .pending; marker absent/unparseable -> .unknown.
enum ArtifactStatus: String { case draft = "Draft", inProgress = "In Progress", done = "Done", approved = "Approved" }
enum StepStatus { case done, pending, unknown }

struct PlanningState {
    let steps: [PlanningStep: StepStatus]
    var nextIncompleteStep: PlanningStep? // nil when all done
}

protocol PlanningStateReading {
    func currentState() -> PlanningState
    // fired after every debounced re-parse (file-watch tick or CLI poll); Planning Mode's
    // stepper and MarkdownDocRenderer's live-refresh (US-003 AC2, US-004, US-005) both
    // subscribe to this same signal rather than polling currentState() independently
    var onStateChanged: ((PlanningState) -> Void)? { get set }
}

final class PlanningStateReader: PlanningStateReading {
    var onStateChanged: ((PlanningState) -> Void)?
    init(taskFolder: URL, fileWatcher: FileWatching)
    func currentState() -> PlanningState
}
```

## Behavior

1. On each (debounced) file-watch tick, attempt `saha plan-status <id> --json` as a subprocess.
2. If it exits 0 with valid JSON: map `checks[]`/`next_step` into `PlanningState` via `PlanningStep(wireName:)` — never string-compare against the enum's Swift case names directly.
3. If it exits non-zero (old saha, or command unsupported): fall back to scanning `README.md`'s progress table + `**Status:**` markers per artifact.
4. A folder with no README/markers at all yields `StepStatus.unknown` for every step (never throws) — mirrors the "unknown" chip behavior from US-001/US-002's picker.
5. Every successful re-parse (from either source) fires `onStateChanged` with the new `PlanningState`; consumers (Planning Mode stepper, `MarkdownDocRenderer`'s live-refresh) subscribe once rather than each re-implementing file-watch polling.

## Related

- **Stories:** US-003
- **Test Specs:** test-specs/unit/planning-marker-parser.md, test-specs/integration/planning-state-file-watch.md
