import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:uten_imp/core/network/server_config.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/drafts/form_draft_catalog.dart';
import 'package:uten_imp/shared/drafts/form_draft_category.dart';
import 'package:uten_imp/shared/drafts/form_draft_store.dart';
import 'package:uten_imp/shared/drafts/task_form_draft_recovery_notice.dart';
import 'package:uten_imp/shared/providers/authenticated_scope_provider.dart';

import 'memory_form_draft_storage.dart';

Future<({ProviderContainer container, GoRouter router})> _pump(
  WidgetTester tester, {
  bool unknown = false,
}) async {
  final container = ProviderContainer(
    overrides: [
      authenticatedScopeProvider.overrideWithValue(
        const AuthenticatedScope(userId: 'operator'),
      ),
      currentPermissionsProvider.overrideWithValue({
        Perm.warehouseSalesOutboundView,
        Perm.warehouseSalesOutboundExecute,
      }),
      apiBaseUrlProvider.overrideWithValue('https://draft-test.invalid/api'),
      formDraftStorageProvider.overrideWithValue(MemoryFormDraftStorage()),
    ],
  );
  final store = container.read(formDraftsProvider.notifier);
  await store.ready;
  final spec = FormDraftCatalog.warehouseSalesOutbound.spec(
    route: '/warehouse/sales-outbound/original-task',
  );
  await store.save(
    FormDraft(
      id: 'original-input',
      title: spec.title,
      module: spec.module,
      route: spec.route,
      permission: spec.permission,
      updatedAt: DateTime.utc(2026, 10, 11),
      data: {
        'shipmentId': 'original-task',
        'input': {'place': 'A-09'},
        if (unknown) formDraftUnknownSubmissionKey: true,
      },
    ),
  );
  final router = GoRouter(
    initialLocation: '/recovery',
    routes: [
      GoRoute(
        path: '/recovery',
        builder: (_, _) => const Scaffold(
          body: TaskDraftRecoveryNotice(
            scope: FormDraftCategoryScope(module: BadgeModule.warehouse),
          ),
        ),
      ),
      GoRoute(
        path: '/warehouse/sales-outbound/:id',
        builder: (_, state) => Scaffold(
          body: Text(
            'resumed:${state.pathParameters['id']}:${state.uri.queryParameters['draftId']}',
          ),
        ),
      ),
    ],
  );
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp.router(routerConfig: router),
    ),
  );
  await tester.pumpAndSettle();
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
    router.dispose();
    container.dispose();
  });
  return (container: container, router: router);
}

void main() {
  testWidgets(
    'ordinary input remains recoverable after the authoritative task leaves the queue',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(375, 800));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final rig = await _pump(tester);
      await tester.tap(find.text('继续原填写'));
      await tester.pumpAndSettle();
      expect(find.byTooltip('丢弃本机填写'), findsOneWidget);
      await tester.tap(find.text('销售出库核对'));
      await tester.pumpAndSettle();
      expect(find.text('resumed:original-task:original-input'), findsOneWidget);
      expect(
        rig.container.read(formDraftsProvider).single.id,
        'original-input',
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('discard from recovery deletes only the exact local revision', (
    tester,
  ) async {
    final rig = await _pump(tester);
    await tester.tap(find.text('继续原填写'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('丢弃本机填写'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('丢弃本机填写'));
    await tester.pumpAndSettle();
    expect(rig.container.read(formDraftsProvider), isEmpty);
    expect(rig.router.routeInformationProvider.value.uri.path, '/recovery');
    expect(
      find.byKey(const ValueKey('task-draft-recovery-notice')),
      findsNothing,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'an unresolved command resumes directly and cannot be discarded',
    (tester) async {
      final rig = await _pump(tester, unknown: true);
      expect(find.byTooltip('丢弃本机填写'), findsNothing);
      await tester.tap(find.text('核对原提交'));
      await tester.pumpAndSettle();
      expect(find.text('resumed:original-task:original-input'), findsOneWidget);
      expect(
        rig.container.read(formDraftsProvider).single.hasUnknownSubmission,
        isTrue,
      );
      expect(tester.takeException(), isNull);
    },
  );
}
