# Riverpod 3.4.3 subscription resume backport

This directory contains the MIT-licensed runtime sources from the published
`riverpod` 3.4.3 package. The upstream archive SHA-256 recorded in the original
application lockfile is
`484dfc873ea4c4f4240e5635444fa066f87b07862b7279ebd004a2b71fba4b7a`.
The original license is retained in `LICENSE`.

There is one runtime change: `ProviderSubscriptionImpl.resume()` flushes the
listened element while its graph is still paused, then resumes/reactivates the
subscription. This prevents a dirty shared dependency from scheduling an active
sibling branch during Flutter's build phase. It preserves the real subscription
pause/resume behavior; no page timers, disabled assertions or permanently active
badge subscriptions are used.

The change follows the current minimal implementation of upstream
[PR 4884](https://github.com/rrousselGit/riverpod/pull/4884), reviewed at commit
`541a9b599fee9c47915a5ae47f78ee679a4b9a93`, for
[issue 4882](https://github.com/rrousselGit/riverpod/issues/4882).
The PR is open and is not a released upstream fix. The 3.4.3 adaptation uses its
existing non-null `_listenedElement`; no other upstream development changes are
included.

The local package version is `3.4.3+uten.1`, with publication disabled. Runtime
dependencies are unchanged. Workspace-only development metadata and the optional
prebuilt DevTools extension are omitted; application runtime sources are retained
in full. The root application owns the regression tests.

Coverage includes `test/shared/providers/riverpod_resume_test.dart` (both diamond
watch orders, missed update delivery and subsequent live updates) and the real
warehouse sales task-list -> batch -> successful return regression. The latter
also checks business commands and the absence of Flutter framework exceptions.

Return to the hosted dependency once an upstream release contains the fix and
both the minimal regression and the warehouse navigation test pass against it.
Remove the override and this directory together. Do not modify the global pub
cache or replace the dependency with an unpinned development branch.
