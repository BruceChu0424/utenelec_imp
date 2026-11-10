# Server status backend verification — 2026-11-10

- Scope: read-only monitoring contracts, connection-pool sampling, filesystem allocation reconciliation. No company deployment or remote mutation.
- Reproduced source defects: Java's typed volume projection discarded `mount`; missing active pool gauges could sum to a false zero; failed category scans discarded already-known volume identity; UI logical file sizes and partial directories were not a disk-allocation reconciliation.
- Reconciliation uses actual allocated blocks, deduplicates shared `(device, inode)` entries across categories, separates filesystem reserved capacity and unclassified remainder, and preserves partial/unknown results. The remainder does not identify individual files or authorize deletion.

## Regression results

- WSL Ubuntu, ordinary user: initial full storage run had 13 errors and 1 failure because `/proc/1/fd` was unreadable (`PermissionError`, existing safe-cleanup path returned `UNAVAILABLE` instead of inspecting all open files). No protection was relaxed.
- WSL Ubuntu, root, final full run: `python3 -m unittest test_operations_storage -q` — 41 tests, OK (11.862 seconds).
- Added real Linux hardlink/nested-directory fixtures verify physical block deduplication and visible-category overlap. Additional cases verify reserved capacity, retained volume identity after scan failure, PARTIAL results, and inconsistent/overflow allocation remaining UNKNOWN.
- Java targeted Maven run: `mvn -Duten.build.directory=target-status-reconcile-20261110 -Dtest=ServerStatusProbeTest,ServerStatusTest,ServerStorageServiceTest test -q` — exit 0, isolated from running backend output. Surefire: ServerStatusProbeTest 22, ServerStatusTest 6, ServerStorageServiceTest 13; all 41 passed with zero failures/errors/skips. Reports remain in `server/target-status-reconcile-20261110/surefire-reports/`.

## Independent review

- First review checked deduplication, negative remainder, retained failed-category volume identity, and pool-tag completeness without finding a remaining substantive issue.
- A second review found that `overlapBytes` initially included same-category resource hardlinks already deduplicated by the category. The implementation now computes overlap from visible category totals; the real two-release shared-JAR regression passes in the 41-test run above.
