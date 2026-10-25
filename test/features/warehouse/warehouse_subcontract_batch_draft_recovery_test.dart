import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/network/api_endpoints.dart';
import 'package:uten_imp/core/network/api_exception.dart';
import 'package:uten_imp/core/network/server_config.dart';
import 'package:uten_imp/core/router/route_names.dart';
import 'package:uten_imp/components/buttons/uten_button.dart';
import 'package:uten_imp/features/warehouse/pages/warehouse_subcontract_outbound_batch_page.dart';
import 'package:uten_imp/features/warehouse/widgets/subcontract_outbound_detail_table.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/auth/session_snapshot_provider.dart';
import 'package:uten_imp/shared/drafts/form_draft_navigation.dart';
import 'package:uten_imp/shared/drafts/form_draft.dart';
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
  for (final status in [409, 403, 404]) {
    testWidgets('相邻未提交来源$status不阻断未知原操作，脱敏恢复原键并保存再次打开', (tester) async {
      final api = _RecoveryReadApi(afterCommit: false);
      final harness = await _pump(
        tester,
        api,
        selectedItemIds: ['issue-item-1', 'issue-item-2', 'issue-item-3'],
      );
      _table(tester).rows[1].draft.remarkController.text = '仅保留在本机的B填写';
      await _confirm(tester);
      final saved = harness.container.read(formDraftsProvider).single;
      final originalCommand = jsonEncode(
        (saved.data['atomicCommands'] as Map)['issue-1'],
      );
      final originalB = jsonEncode(
        (saved.data['documents'] as List)
            .cast<Map<String, dynamic>>()
            .singleWhere((document) => document['issueId'] == 'issue-2'),
      );
      expect(saved.hasUnknownSubmission, isTrue);
      expect(saved.resumeLocation, contains('draftId='));
      await _leave(tester, harness.router);
      api.blockedNeighbourStatus = status;
      api.atomicReads.clear();
      unawaited(harness.router.push(saved.resumeLocation));
      await tester.pumpAndSettle();

      _expectOpaqueRecovery(tester);
      expect(api.atomicReads.first, 'receipt:issue-1');
      expect(api.atomicRequests, hasLength(1));
      final restored = harness.container.read(formDraftsProvider).single;
      expect(restored.hasUnknownSubmission, isTrue);
      expect(restored.data['issueIds'], ['issue-1', 'issue-2', 'issue-3']);
      expect(restored.data['selectedItemIds'], [
        'issue-item-1',
        'issue-item-2',
        'issue-item-3',
      ]);
      expect(
        jsonEncode((restored.data['atomicCommands'] as Map)['issue-1']),
        originalCommand,
      );
      expect(
        jsonEncode(
          (restored.data['documents'] as List)
              .cast<Map<String, dynamic>>()
              .singleWhere((document) => document['issueId'] == 'issue-2'),
        ),
        originalB,
      );
      await tester.tap(find.text('核实处理结果').first);
      await tester.pumpAndSettle();
      expect(api.atomicRequests, hasLength(1), reason: '核对只读，不向相邻来源派发');
      await tester.tap(find.text('按原内容重试').first);
      await tester.pumpAndSettle();
      expect(api.atomicRequests.map((request) => request.$1), [
        'issue-1',
        'issue-1',
      ]);
      expect(jsonEncode(api.atomicRequests.last.$2), originalCommand);
      expect(api.updates, isEmpty);
      expect(api.approvals, isEmpty);
      _expectOpaqueRecovery(tester);
      final confirmed = harness.container.read(formDraftsProvider).single;
      expect(confirmed.data['completed'], ['issue-1']);
      expect(confirmed.data['atomicUnknownIds'], isEmpty);
      expect(confirmed.hasUnknownSubmission, isFalse);
      expect(confirmed.data['issueIds'], ['issue-1', 'issue-2', 'issue-3']);
      expect(
        jsonEncode(
          (confirmed.data['documents'] as List)
              .cast<Map<String, dynamic>>()
              .singleWhere((document) => document['issueId'] == 'issue-2'),
        ),
        originalB,
      );
      await _leave(tester, harness.router);
      unawaited(harness.router.push(confirmed.resumeLocation));
      await tester.pumpAndSettle();
      _expectOpaqueRecovery(tester);
      expect(find.text('来源 issue-1：原提交已确认'), findsOneWidget);
      expect(
        harness.container.read(formDraftsProvider).single.hasUnknownSubmission,
        isFalse,
      );
      expect(api.atomicRequests, hasLength(2));
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('成功回执在初始化后落checkpoint，相邻取消不遗留unknown也不把整批当完成', (tester) async {
    final api = _RecoveryReadApi(afterCommit: true);
    final harness = await _pump(
      tester,
      api,
      selectedItemIds: ['issue-item-1', 'issue-item-2', 'issue-item-3'],
    );
    await _confirm(tester);
    final saved = harness.container.read(formDraftsProvider).single;
    expect(saved.hasUnknownSubmission, isTrue);
    await _leave(tester, harness.router);
    api.blockedNeighbourStatus = 409;
    unawaited(harness.router.push(saved.resumeLocation));
    await tester.pumpAndSettle();
    _expectOpaqueRecovery(tester);
    final checkpoint = harness.container.read(formDraftsProvider).single;
    expect(checkpoint.data['completed'], ['issue-1']);
    expect(checkpoint.data['atomicUnknownIds'], isEmpty);
    expect(checkpoint.hasUnknownSubmission, isFalse);
    expect(checkpoint.revision, isNot(saved.revision));
    expect(find.text('按原内容重试'), findsNothing);
    expect(api.atomicRequests.map((request) => request.$1), ['issue-1']);
    await _leave(tester, harness.router);
    unawaited(harness.router.push(checkpoint.resumeLocation));
    await tester.pumpAndSettle();
    _expectOpaqueRecovery(tester);
    expect(
      harness.container.read(formDraftsProvider).single.hasUnknownSubmission,
      isFalse,
    );
    expect(api.atomicRequests, hasLength(1));
    expect(tester.takeException(), isNull);
  });

  testWidgets('未知原来源不可读时不放行重试，冻结body和完整范围继续保存', (tester) async {
    final api = _RecoveryReadApi(afterCommit: false);
    final harness = await _pump(
      tester,
      api,
      selectedItemIds: ['issue-item-1', 'issue-item-2', 'issue-item-3'],
    );
    await _confirm(tester);
    final saved = harness.container.read(formDraftsProvider).single;
    final original = jsonEncode(saved.data['atomicCommands']);
    await _leave(tester, harness.router);
    api.blockedSource = true;
    unawaited(harness.router.push(saved.resumeLocation));
    await tester.pumpAndSettle();
    _expectOpaqueRecovery(tester);
    expect(find.text('按原内容重试'), findsNothing);
    await tester.tap(find.text('核实处理结果').first);
    await tester.pumpAndSettle();
    expect(api.atomicRequests, hasLength(1));
    final stillUnknown = harness.container.read(formDraftsProvider).single;
    expect(stillUnknown.hasUnknownSubmission, isTrue);
    expect(jsonEncode(stillUnknown.data['atomicCommands']), original);
    expect(stillUnknown.data['issueIds'], ['issue-1', 'issue-2', 'issue-3']);
    await _leave(tester, harness.router);
    unawaited(harness.router.push(stillUnknown.resumeLocation));
    await tester.pumpAndSettle();
    _expectOpaqueRecovery(tester);
    expect(api.atomicRequests, hasLength(1));
    expect(tester.takeException(), isNull);
  });

  testWidgets('重试前再次核验原来源可读性，期间失权不会发送冻结请求', (tester) async {
    final api = _RecoveryReadApi(afterCommit: false);
    final harness = await _pump(
      tester,
      api,
      selectedItemIds: ['issue-item-1', 'issue-item-2', 'issue-item-3'],
    );
    await _confirm(tester);
    final saved = harness.container.read(formDraftsProvider).single;
    await _leave(tester, harness.router);
    api.blockedNeighbourStatus = 409;
    unawaited(harness.router.push(saved.resumeLocation));
    await tester.pumpAndSettle();
    expect(find.text('按原内容重试'), findsOneWidget);
    api.blockedSource = true;
    await tester.tap(find.text('按原内容重试'));
    await tester.pumpAndSettle();
    expect(find.text('按原内容重试'), findsNothing);
    expect(api.atomicRequests, hasLength(1));
    expect(
      harness.container.read(formDraftsProvider).single.hasUnknownSubmission,
      isTrue,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('没有冻结命令的新入口仍严格拒绝失效相邻来源', (tester) async {
    final api = _RecoveryReadApi(afterCommit: false)
      ..blockedNeighbourStatus = 409;
    final harness = await _pump(
      tester,
      api,
      selectedItemIds: ['issue-item-1', 'issue-item-2', 'issue-item-3'],
    );
    expect(
      find.byKey(const Key('subcontract-outbound-atomic-recovery')),
      findsNothing,
    );
    expect(
      find.byKey(const Key('subcontract-outbound-batch-confirm')),
      findsNothing,
    );
    expect(find.text('按原内容重试'), findsNothing);
    expect(harness.container.read(formDraftsProvider), isEmpty);
    expect(api.atomicRequests, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('显式草稿恢复拒绝冻结明细与原请求体不一致，不因相邻失败获得重试入口', (tester) async {
    final api = _RecoveryReadApi(afterCommit: false);
    final harness = await _pump(
      tester,
      api,
      selectedItemIds: ['issue-item-1', 'issue-item-2', 'issue-item-3'],
    );
    await _confirm(tester);
    final saved = harness.container.read(formDraftsProvider).single;
    await _leave(tester, harness.router);
    final corrupted =
        jsonDecode(jsonEncode(saved.toJson())) as Map<String, dynamic>;
    final data = corrupted['data'] as Map;
    final command = (data['atomicCommands'] as Map)['issue-1'] as Map;
    final brokenItem =
        ((command['document'] as Map)['items'] as List).single as Map;
    brokenItem['id'] = 'issue-item-2';
    final broken = await harness.container
        .read(formDraftsProvider.notifier)
        .save(FormDraft.fromJson(corrupted), expectedRevision: saved.revision);
    api.blockedNeighbourStatus = 409;
    unawaited(harness.router.push(broken.resumeLocation));
    await tester.pumpAndSettle();
    expect(find.text('按原内容重试'), findsNothing);
    expect(
      find.byKey(const Key('subcontract-outbound-atomic-recovery')),
      findsNothing,
    );
    expect(api.atomicRequests, hasLength(1));
    expect(
      harness.container.read(formDraftsProvider).single.hasUnknownSubmission,
      isTrue,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('所选明细已移至执行子单后恢复先查原回执，源单未选行继续保留', (tester) async {
    final api = _LostAtomicApi(afterCommit: true);
    api.addLine(
      'issue-1',
      pick: outboundPickLine(
        issueItemId: 'left-behind',
        planItemId: 'left-plan',
        goodsId: 'left-goods',
      ),
      item: {
        ...outboundDocItem(
          id: 'left-behind',
          planItemId: 'left-plan',
          goodsId: 'left-goods',
        ),
        'reservation': 'untouched',
      },
    );
    final harness = await _pump(
      tester,
      api,
      selectedItemIds: [
        'issue-item-1',
        'left-behind',
        'issue-item-2',
        'issue-item-3',
      ],
    );
    _table(tester).rows
            .singleWhere((row) => row.draft.draftItemId == 'left-behind')
            .draft
            .qty
            .text =
        '0';
    await _confirm(tester);
    expect(api.atomicRequests, hasLength(1));
    expect(api.atomicRequests.single.$2['itemIds'], ['issue-item-1']);
    expect(
      _table(tester).rows
          .singleWhere((row) => row.draft.draftItemId == 'left-behind')
          .status,
      '继续待发',
    );
    expect(api.updates, isEmpty);
    final saved = harness.container.read(formDraftsProvider).single;
    expect(saved.hasUnknownSubmission, isTrue);
    expect((saved.data['atomicSourceScopes'] as Map)['issue-1'], [
      'issue-item-1',
      'left-behind',
    ]);
    expect(
      ((api.documents['issue-1']!['items'] as List).single as Map)['id'],
      'left-behind',
    );
    await _leave(tester, harness.router);
    api.atomicReads.clear();
    unawaited(harness.router.push(saved.resumeLocation));
    await tester.pumpAndSettle();
    expect(api.atomicReads.first, 'receipt:issue-1');
    expect(api.atomicReads, isNot(contains('review:issue-1')));
    expect(_table(tester).rows.map((row) => row.draft.draftItemId), [
      'issue-item-2',
      'issue-item-3',
    ]);
    await _confirm(tester);
    expect(api.atomicRequests.map((entry) => entry.$1), [
      'issue-1',
      'issue-2',
      'issue-3',
    ]);
    expect(harness.container.read(formDraftsProvider), isEmpty);
    expect(
      ((api.documents['issue-1']!['items'] as List).single
          as Map)['reservation'],
      'untouched',
    );
    expect(api.documents['issue-1']!['status'], 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets('空回执继续冻结，恢复和只读核对不重发，明确重试仍用原body和key', (tester) async {
    final api = _LostAtomicApi(afterCommit: false);
    final harness = await _pump(
      tester,
      api,
      selectedItemIds: ['issue-item-1', 'issue-item-2', 'issue-item-3'],
    );
    await _confirm(tester);
    final saved = harness.container.read(formDraftsProvider).single;
    final original = jsonEncode(
      (saved.data['atomicCommands'] as Map)['issue-1'],
    );
    expect(api.atomicRequests, hasLength(1));
    await _leave(tester, harness.router);
    unawaited(harness.router.push(saved.resumeLocation));
    await tester.pumpAndSettle();
    expect(
      harness.container.read(formDraftsProvider).single.hasUnknownSubmission,
      isTrue,
    );
    expect(_table(tester).rows.map((row) => row.draft.draftItemId), [
      'issue-item-2',
      'issue-item-3',
    ]);
    await tester.tap(find.text('核实处理结果').first);
    await tester.pumpAndSettle();
    expect(api.atomicRequests, hasLength(1));
    expect(
      harness.container.read(formDraftsProvider).single.hasUnknownSubmission,
      isTrue,
    );
    await tester.tap(find.text('按原内容重试').first);
    await tester.pumpAndSettle();
    expect(api.atomicRequests, hasLength(2));
    expect(jsonEncode(api.atomicRequests.last.$2), original);
    expect(api.atomicRequests.last.$2['itemIds'], ['issue-item-1']);
    await _confirm(tester);
    expect(harness.container.read(formDraftsProvider), isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('服务器核对版本改变则不冻结不发送原子命令', (tester) async {
    final api = _NativeSubcontractOutboundFakeApi();
    final harness = await _pump(
      tester,
      api,
      selectedItemIds: ['issue-item-1', 'issue-item-2', 'issue-item-3'],
    );
    api.atomicFingerprint = 'b' * 64;
    await _confirm(tester);
    expect(api.atomicRequests, isEmpty);
    expect(api.updates, isEmpty);
    expect(
      harness.container
          .read(formDraftsProvider)
          .where((draft) => draft.hasUnknownSubmission),
      isEmpty,
    );
    expect(tester.takeException(), isNull);
  });
  testWidgets('批量拣货保存原来源填写和整单勾选，重新打开不写业务单据', (tester) async {
    final api = _NativeSubcontractOutboundFakeApi();
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
    expect(find.text('已恢复本机草稿'), findsNothing);
    final restored = _table(tester);
    expect(restored.rows.first.draft.qty.text, '500');
    expect(restored.rows.first.draft.remarkController.text, '中断前核对');
    expect(restored.rows[1].draft.selected, isFalse);
    expect(api.updates, isEmpty);
    expect(api.approvals, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('批量审核丢回执后重新打开只读取核对，已出仓单不重复发送', (tester) async {
    final api = _NativeSubcontractOutboundFakeApi()
      ..timeoutAfterSecondApproval = true;
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

void _expectOpaqueRecovery(WidgetTester tester) {
  expect(
    find.byKey(const Key('subcontract-outbound-atomic-recovery')),
    findsOneWidget,
  );
  expect(find.byType(SubcontractOutboundDetailTable), findsNothing);
  expect(find.textContaining('直属物料'), findsNothing);
  expect(find.textContaining('Supplier'), findsNothing);
  expect(find.text('仅保留在本机的B填写'), findsNothing);
  for (final id in ['issue-1', 'issue-2', 'issue-3']) {
    expect(
      find.byKey(ValueKey('subcontract-outbound-recovery-source-$id')),
      findsOneWidget,
    );
  }
  expect(
    tester
        .widget<UtenButton>(
          find.byKey(const Key('subcontract-outbound-batch-confirm')),
        )
        .onPressed,
    isNull,
  );
}

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
  SubcontractOutboundFakeApi api, {
  List<String>? selectedItemIds,
}) async {
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
          selectedItemIds: state.uri.queryParameters['itemIds']?.split(','),
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
  unawaited(
    router.push(
      selectedItemIds == null
          ? _batchLocation
          : '$_batchLocation&itemIds=${selectedItemIds.join(',')}',
    ),
  );
  await tester.pumpAndSettle();
  return (router: router, container: container);
}

class _Snapshot extends SessionSnapshotNotifier {
  @override
  Future<SessionSnapshot?> build() async => null;
}

/// These fixtures are current warehouse tasks, with explicit native provenance.
class _NativeSubcontractOutboundFakeApi extends SubcontractOutboundFakeApi {
  @override
  void addIssue(int index) {
    super.addIssue(index);
    documents['issue-$index']!.addAll({
      'historyReadOnly': false,
      'legacyImported': false,
    });
  }
}

class _LostSaveApi extends _NativeSubcontractOutboundFakeApi {
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

class _LostAtomicApi extends _NativeSubcontractOutboundFakeApi {
  _LostAtomicApi({required this.afterCommit});
  final bool afterCommit;
  bool fail = true;
  @override
  Future<Map<String, dynamic>> post(
    String path, {
    Object? body,
    Map<String, dynamic>? headers,
    Map<String, dynamic>? query,
  }) async {
    if (path.endsWith('/selected-outbound') && fail) {
      fail = false;
      if (afterCommit) {
        await super.post(path, body: body, headers: headers, query: query);
      } else {
        atomicRequests.add((
          path.split('/')[3],
          jsonDecode(jsonEncode(body)) as Map<String, dynamic>,
        ));
      }
      throw NetworkTimeoutException();
    }
    return super.post(path, body: body, headers: headers, query: query);
  }
}

class _RecoveryReadApi extends _LostAtomicApi {
  _RecoveryReadApi({required super.afterCommit});
  int? blockedNeighbourStatus;
  bool blockedSource = false;

  @override
  Future<Map<String, dynamic>> get(String path, {Map<String, dynamic>? query}) {
    final neighbour =
        path == '/subcontract/material-issues/issue-2' ||
        path ==
            '/subcontract/material-issues/issue-2/selected-outbound/review' ||
        path == ApiEndpoints.warehouseSubcontractOutboundTask('issue-2');
    if (neighbour && blockedNeighbourStatus != null) {
      throw ApiException(
        'SOURCE_CHANGED',
        '此来源已取消或不可读',
        httpStatus: blockedNeighbourStatus,
      );
    }
    if (blockedSource && path == '/subcontract/material-issues/issue-1') {
      throw ApiException('FORBIDDEN', '原来源当前不可读', httpStatus: 403);
    }
    return super.get(path, query: query);
  }
}
