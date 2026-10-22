# task-11-concurrency-telemetry

Work-interval log: make parallelism measurable.
Status: planning (quick path, `mode: minimal`) — see `progress.yaml`.
Spec: `model/*.c4` (open in sich / `likec4 start` for review only).
Born from the Aug 2026 archive-analytics grilling: the app stores only accumulated
WORKING totals, so peak concurrency — its own core quantity — is unmeasurable.
