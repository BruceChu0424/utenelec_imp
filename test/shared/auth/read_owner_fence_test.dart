import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/components/data_display/paged_list_controller.dart';
import 'package:uten_imp/core/network/api_exception.dart';
import 'package:uten_imp/core/network/server_config.dart';
import 'package:uten_imp/core/performance/ui_work_budget.dart';
import 'package:uten_imp/features/basic_data/widgets/master_server_column_filters.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/auth/read_owner_fence.dart';
import 'package:uten_imp/shared/models/paged_result.dart';
import 'package:uten_imp/shared/providers/authenticated_scope_provider.dart';
import 'package:uten_imp/shared/providers/export_context_epoch_provider.dart';

class _Owner extends Notifier<AuthenticatedScope?> {
  @override
  AuthenticatedScope? build() => const AuthenticatedScope(userId: 'A');
  void change(AuthenticatedScope? value) => state = value;
}

class _Permissions extends Notifier<Set<String>> {
  @override
  Set<String> build() => {'read'};
  void change(Set<String> value) => state = value;
}

class _Server extends Notifier<String> {
  @override
  String build() => 'https://a.invalid/api';
  void change(String value) => state = value;
}

final _owner = NotifierProvider<_Owner, AuthenticatedScope?>(_Owner.new);
final _permissions = NotifierProvider<_Permissions, Set<String>>(
  _Permissions.new,
);
final _server = NotifierProvider<_Server, String>(_Server.new);

class _Harness extends ConsumerStatefulWidget {
  const _Harness({required this.controller, required this.ready});
  final PagedListController<String> controller;
  final void Function(WidgetRef) ready;
  @override
  ConsumerState<_Harness> createState() => _HarnessState();
}

class _HarnessState extends ConsumerState<_Harness> {
  @override
  void initState() {
    super.initState();
    listenReadOwner(ref, widget.controller.invalidateReadOwner);
    widget.ready(ref);
  }

  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}

// Pause after the first row, inside the real large facet decoder. This is the
// new post-HTTP await window rather than a synthetic delayed network response.
class _FacetPause extends UiWorkBudget {
  final entered = Completer<void>();
  final release = Completer<void>();
  int calls = 0;

  @override
  Future<void> checkpoint([int items = 1]) async {
    if (++calls == 2) {
      entered.complete();
      await release.future;
    }
    await super.checkpoint(items);
  }
}

Map<String, dynamic> _largeResponse() => {
  'items': [
    {'id': 'old-private-row'},
  ],
  'page': 4,
  'size': 1,
  'total': 12345,
  'totalPages': 12345,
  'facets': {
    'party': List.generate(
      4000,
      (index) => {
        'value': 'private-$index',
        'label': 'old-private-party-$index',
        'count': 1,
      },
    ),
  },
};

PagedResult<String> _currentPage() => const PagedResult(
  items: ['current-owner-row'],
  page: 1,
  size: 1,
  total: 1,
  totalPages: 1,
);

Future<void> _changeOwner(
  ProviderContainer container,
  String transition,
) async {
  switch (transition) {
    case 'account':
      container
          .read(_owner.notifier)
          .change(const AuthenticatedScope(userId: 'B'));
    case 'permissions':
      container.read(_permissions.notifier).change({});
    case 'server':
      container.read(_server.notifier).change('https://b.invalid/api');
    case 'reset':
      container
          .read(_owner.notifier)
          .change(
            const AuthenticatedScope(userId: 'A', businessResetGeneration: 1),
          );
    case 'dataset':
      container
          .read(_owner.notifier)
          .change(
            const AuthenticatedScope(
              userId: 'A',
              businessDatasetId: 'replacement',
            ),
          );
    case 'A-B-A':
      container
          .read(_owner.notifier)
          .change(const AuthenticatedScope(userId: 'B'));
      await container.pump();
      container.read(exportContextEpochProvider);
      container
          .read(_owner.notifier)
          .change(const AuthenticatedScope(userId: 'A'));
  }
  await container.pump();
  container.read(exportContextEpochProvider);
}

void main() {
  for (final transition in [
    'account',
    'permissions',
    'server',
    'A-B-A',
    'reset',
    'dataset',
  ]) {
    for (final lateError in [false, true]) {
      testWidgets(
        'read owner $transition blocks decoded ${lateError ? 'error' : 'page'} and loading',
        (tester) async {
          final container = ProviderContainer(
            overrides: [
              authenticatedScopeProvider.overrideWith(
                (ref) => ref.watch(_owner),
              ),
              currentPermissionsProvider.overrideWith(
                (ref) => ref.watch(_permissions),
              ),
              apiBaseUrlProvider.overrideWith((ref) => ref.watch(_server)),
            ],
          );
          addTearDown(container.dispose);
          final controller = PagedListController<String>();
          addTearDown(controller.dispose);
          late WidgetRef pageRef;
          await tester.pumpWidget(
            UncontrolledProviderScope(
              container: container,
              child: _Harness(
                controller: controller,
                ready: (ref) => pageRef = ref,
              ),
            ),
          );
          controller.keyword = 'typing stays intact';
          controller.onSortChange('billDate', false);
          await tester.runAsync(() async {
            final budget = _FacetPause();
            final ownerCurrent = captureReadOwner(pageRef);
            final old = controller.load(
              4,
              isCurrent: ownerCurrent,
              fetch: () async {
                final result = await PagedResult.fromJsonResponsive<String>(
                  _largeResponse(),
                  (row) => row['id'] as String,
                  budget: budget,
                );
                if (lateError) {
                  throw ApiException('OLD_ERROR', 'private old error');
                }
                return result;
              },
            );
            await budget.entered.future;
            await _changeOwner(container, transition);
            expect(
              ownerCurrent(),
              isFalse,
              reason: 'returning to A cannot revive the ticket',
            );
            expect(controller.page, isNull);
            expect(controller.error, isNull);
            expect(controller.loading, isFalse);
            expect(controller.keyword, 'typing stays intact');
            expect(controller.sortKey, 'billDate');

            final currentGate = Completer<PagedResult<String>>();
            final latest = controller.load(
              1,
              isCurrent: captureReadOwner(pageRef),
              fetch: () => currentGate.future,
            );
            budget.release.complete();
            await old;
            expect(controller.page, isNull);
            expect(controller.error, isNull);
            expect(
              controller.loading,
              isTrue,
              reason:
                  'an obsolete completion cannot end the new owner loading state',
            );
            currentGate.complete(_currentPage());
            await latest;
            expect(controller.page?.items, ['current-owner-row']);
            expect(controller.page?.facets, isEmpty);
            expect(controller.loading, isFalse);
          });
          expect(tester.takeException(), isNull);
        },
      );
    }
  }

  testWidgets(
    'read owner fences large facet publication even without a query change',
    (tester) async {
      final container = ProviderContainer(
        overrides: [
          authenticatedScopeProvider.overrideWith((ref) => ref.watch(_owner)),
          currentPermissionsProvider.overrideWith(
            (ref) => ref.watch(_permissions),
          ),
          apiBaseUrlProvider.overrideWith((ref) => ref.watch(_server)),
        ],
      );
      addTearDown(container.dispose);
      final controller = PagedListController<String>();
      addTearDown(controller.dispose);
      late WidgetRef pageRef;
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: _Harness(
            controller: controller,
            ready: (ref) => pageRef = ref,
          ),
        ),
      );
      await tester.runAsync(() async {
        final filters = MasterServerColumnFilters();
        final budget = _FacetPause();
        var publications = 0;
        final old = filters.loadFacets(
          () async => (await PagedResult.fromJsonResponsive<String>(
            _largeResponse(),
            (row) => row['id'] as String,
            budget: budget,
          )).facets,
          isCurrent: captureReadOwner(pageRef),
          onLoaded: () => publications++,
        );
        await budget.entered.future;
        await _changeOwner(container, 'A-B-A');
        budget.release.complete();
        await old;
        expect(filters.buckets, isEmpty);
        expect(publications, 0);
      });
    },
  );
}
