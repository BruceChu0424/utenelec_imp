import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/network/api_exception.dart';
import 'package:uten_imp/core/network/server_config.dart';
import 'package:uten_imp/core/router/route_names.dart';
import 'package:uten_imp/features/warehouse/pages/warehouse_subcontract_outbound_batch_page.dart';
import 'package:uten_imp/features/warehouse/widgets/subcontract_outbound_detail_table.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/auth/session_snapshot_provider.dart';
import 'package:uten_imp/shared/drafts/form_draft_navigation.dart';
import 'package:uten_imp/shared/drafts/form_draft_store.dart';
import 'package:uten_imp/shared/providers/authenticated_scope_provider.dart';
import 'package:uten_imp/shared/providers/master_name_provider.dart';
import 'package:uten_imp/shared/providers/shared_providers.dart';

import '../../helpers/badge_summary_fixture.dart';
import '../../shared/drafts/memory_form_draft_storage.dart';
import 'outbound_weight_fakes.dart';
import 'subcontract_outbound_test_support.dart';

const _batchRoute = '/warehouse/subcontract-outbound/batch';
const _batchLocation = '$_batchRoute?issueIds=issue-1,issue-2,issue-3';

void main() {
  testWidgets('批量拣货保存原来源填写和整单勾选，重新打开不写业务单据', (tester) async {
    final api = SubcontractOutboundFakeApi();
    final harness = await _pump(tester, api);
    final table = _table(tester);
    table.rows.first.draft.qty.text = '500';
    table.rows.first.draft.remarkController.text = '中断前核对';
    table.onRowSelected!(table.rows[1], false);
    table.onChanged();
    await tester.pump(const Duration(seconds: 1));
    await tester.pumpAndSettle();
    final draft = harness.container.read(formDraftsProvider).single;
    expect(draft.route, contains('issueIds=issue-1'));
    expect(api.updates, isEmpty);
    await _leave(tester, harness.router);
    unawaited(harness.router.push(draft.resumeLocation));
    await tester.pumpAndSettle();
    expect(find.text('已恢复本机草稿'), findsOneWidget);
    final restored = _table(tester);
    expect(restored.rows.first.draft.qty.text, '500');
    expect(restored.rows.first.draft.remarkController.text, '中断前核对');
    expect(restored.rows[1].draft.selected, isFalse);
    expect(api.updates, isEmpty);
    expect(api.approvals, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('批量审核丢回执后重新打开只读取核对，已出仓单不重复发送', (tester) async {
    final api = SubcontractOutboundFakeApi()..timeoutAfterSecondApproval = true;
    final harness = await _pump(tester, api);
    await _confirm(tester);
    final draft = harness.container.read(formDraftsProvider).single;
    expect(draft.hasUnknownSubmission, isTrue);
    expect(api.approvals, ['issue-1', 'issue-2']);
    await _leave(tester, harness.router);
    unawaited(harness.router.push(draft.resumeLocation));
    await tester.pumpAndSettle();
    final restored = _table(tester);
    expect(restored.rows.map((row) => row.draft.line.planItemId), [
      'plan-item-3',
    ]);
    expect(api.approvals, ['issue-1', 'issue-2']);
    await _confirm(tester);
    expect(api.approvals, ['issue-1', 'issue-2', 'issue-3']);
    expect(api.updates, ['issue-1', 'issue-2', 'issue-3']);
    expect(harness.container.read(formDraftsProvider), isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('保存回执不明且尚未审核时原操作被冻结，GET不证明可以重新发送', (tester) async {
    final api = _LostSaveApi();
    final harness = await _pump(tester, api);
    await _confirm(tester);
    final draft = harness.container.read(formDraftsProvider).single;
    expect(draft.hasUnknownSubmission, isTrue);
    expect(api.updates, ['issue-1']);
    await _leave(tester, harness.router);
    unawaited(harness.router.push(draft.resumeLocation));
    await tester.pumpAndSettle();
    final restored = _table(tester);
    expect(restored.rows.first.editable, isFalse);
    expect(api.updates, ['issue-1']);
    expect(api.approvals, isEmpty);
    await tester.tap(find.text('核实处理结果'));
    await tester.pumpAndSettle();
    expect(api.updates, ['issue-1']);
    expect(
      harness.container.read(formDraftsProvider).single.hasUnknownSubmission,
      isTrue,
    );
    expect(tester.takeException(), isNull);
  });
}

SubcontractOutboundDetailTable _table(WidgetTester tester) =>
    tester.widget(find.byType(SubcontractOutboundDetailTable));

Future<void> _leave(WidgetTester tester, GoRouter router) async {
  router.go('/list');
  await tester.pumpAndSettle();
  if (tester.any(find.text('保存原提交后离开'))) {
    await tester.tap(find.text('保存原提交后离开'));
  } else if (tester.any(find.text('保存草稿'))) {
    await tester.tap(find.text('保存草稿'));
  }
  await tester.pumpAndSettle();
  expect(router.routeInformationProvider.value.uri.path, '/list');
}

Future<void> _confirm(WidgetTester tester) async {
  await tester.tap(find.byKey(const Key('subcontract-outbound-batch-confirm')));
  await tester.pumpAndSettle();
  await tester.tap(
    find.descendant(
      of: find.byType(AlertDialog),
      matching: find.widgetWithText(FilledButton, '确认批量出库'),
    ),
  );
  await tester.pumpAndSettle();
}

Future<({GoRouter router, ProviderContainer container})> _pump(
  WidgetTester tester,
  SubcontractOutboundFakeApi api,
) async {
  await tester.binding.setSurfaceSize(const Size(1440, 1100));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  SharedPreferences.setMockInitialValues({});
  final prefs = await SharedPreferences.getInstance();
  final container = ProviderContainer(
    overrides: [
      fakeWeightRepositoryOverride(),
      fixedBadgeSummaryOverride(),
      sessionSnapshotProvider.overrideWith(_Snapshot.new),
      apiClientProvider.overrideWithValue(api),
      apiBaseUrlProvider.overrideWithValue(
        'https://warehouse-drafts.example/api',
      ),
      masterNameServiceProvider.overrideWithValue(OutboundNames(api)),
      authenticatedScopeProvider.overrideWithValue(
        const AuthenticatedScope(userId: 'warehouse-user'),
      ),
      currentPermissionsProvider.overrideWithValue(
        subcontractOutboundPermissions,
      ),
      isSuperAdminProvider.overrideWithValue(false),
      sharedPreferencesProvider.overrideWithValue(prefs),
      formDraftStorageProvider.overrideWithValue(MemoryFormDraftStorage()),
    ],
  );
  final router = GoRouter(
    initialLocation: '/list',
    routes: [
      DraftAwareGoRoute(
        path: '/list',
        builder: (_, _) => const Scaffold(body: Text('原任务列表')),
      ),
      DraftAwareGoRoute(
        path: _batchRoute,
        builder: (_, state) => WarehouseSubcontractOutboundBatchPage(
          key: state.pageKey,
          issueIds: state.uri.queryParameters['issueIds']!.split(','),
        ),
      ),
      DraftAwareGoRoute(
        path: RouteName.warehouseOutboundTasks,
        builder: (_, _) => const Scaffold(body: Text('完成任务')),
      ),
    ],
  );
  addTearDown(router.dispose);
  addTearDown(container.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp.router(routerConfig: router),
    ),
  );
  unawaited(router.push(_batchLocation));
  await tester.pumpAndSettle();
  return (router: router, container: container);
}

class _Snapshot extends SessionSnapshotNotifier {
  @override
  Future<SessionSnapshot?> build() async => null;
}

class _LostSaveApi extends SubcontractOutboundFakeApi {
  bool failSave = true;
  @override
  Future<Map<String, dynamic>> put(String path, {Object? body}) async {
    final result = await super.put(path, body: body);
    if (failSave) {
      failSave = false;
      throw NetworkTimeoutException();
    }
    return result;
  }
}
