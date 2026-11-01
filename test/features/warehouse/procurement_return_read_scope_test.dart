import 'dart:async';
import 'dart:collection';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/components/buttons/uten_close_button.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/network/read_scope_revision.dart';
import 'package:uten_imp/core/network/server_config.dart';
import 'package:uten_imp/features/warehouse/pages/procurement_return_task_pages.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/auth/session_snapshot_provider.dart';
import 'package:uten_imp/shared/models/procurement_inbound.dart';
import 'package:uten_imp/shared/providers/authenticated_scope_provider.dart';
import 'package:uten_imp/shared/providers/shared_providers.dart';

import '../../helpers/badge_summary_fixture.dart';
import '../../support/filter_segment_tap.dart';

const _a = AuthenticatedScope(userId: 'a');
final _owner = StateProvider<AuthenticatedScope?>((_) => _a);

class _Snapshots extends SessionSnapshotNotifier {
  @override
  Future<SessionSnapshot?> build() async => SessionSnapshot();
  void confirm() => state = AsyncData(SessionSnapshot());
}

class _Api extends ApiClient {
  _Api() : super(Dio());
  final gates = Queue<Completer<Map<String, dynamic>>>();
  Completer<Map<String, dynamic>>? writeGate;
  final writes = <({String path, Object? body})>[];
  int reads = 0;
  String marker = '原归属货品';
  bool actionable = false;
  Map<String, dynamic> detail(String name) => {
    'id': 'exception-1',
    'orderType': 'PURCHASE',
    'receiptId': 'receipt-1',
    'receiptItemId': 'receipt-line-1',
    'receiptBillNo': 'PR-001',
    'orderId': 'order-1',
    'orderItemId': 'order-line-1',
    'orderBillNo': 'PO-001',
    'goodsCode': 'G-001',
    'goodsName': name,
    'unitName': '件',
    'declaredQty': 15,
    'approvedRemainingQty': 10,
    'requestedExcessQty': 5,
    'acceptedQty': 10,
    'unacceptedQty': 5,
    'status': 'RETURN_REQUIRED',
    'version': 2,
    'priceMasked': true,
    'returnTask': {
      'id': 'return-1',
      'qty': 5,
      'status': 'PENDING_RETURN',
      'version': 7,
    },
    'allowedActions': [if (actionable) 'COMPLETE_RETURN'],
  };
  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    reads++;
    if (gates.isNotEmpty) return gates.removeFirst().future;
    final row = detail(marker);
    return path.endsWith('/tasks')
        ? {
            'items': [row],
            'total': 1,
            'page': 1,
            'size': 20,
            'totalPages': 1,
          }
        : row;
  }

  @override
  Future<Map<String, dynamic>> post(
    String path, {
    Object? body,
    Map<String, dynamic>? headers,
    Map<String, dynamic>? query,
  }) async {
    writes.add((path: path, body: body));
    return writeGate?.future ?? detail('提交完成货品');
  }
}

Future<void> _frames(WidgetTester tester) async {
  for (var i = 0; i < 6; i++) {
    await tester.pump(const Duration(milliseconds: 30));
  }
}

Future<ProviderContainer> _pump(
  WidgetTester tester,
  _Api api, {
  bool list = false,
}) async {
  await tester.binding.setSurfaceSize(const Size(1600, 1000));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  SharedPreferences.setMockInitialValues({'performancePreference': 'lite'});
  final prefs = await SharedPreferences.getInstance();
  final container = ProviderContainer(
    overrides: [
      apiClientProvider.overrideWithValue(api),
      fixedBadgeSummaryOverride(),
      sharedPreferencesProvider.overrideWithValue(prefs),
      authenticatedScopeProvider.overrideWith((ref) => ref.watch(_owner)),
      apiBaseUrlProvider.overrideWithValue('https://a.invalid/api'),
      sessionSnapshotProvider.overrideWith(_Snapshots.new),
      currentPermissionsProvider.overrideWithValue({
        Perm.supplierReturnTaskView,
        Perm.supplierReturnTaskViewAll,
        Perm.supplierReturnTaskComplete,
      }),
      isSuperAdminProvider.overrideWithValue(false),
    ],
  );
  addTearDown(container.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('zh'),
        home: list
            ? const ProcurementReturnTasksPage(
                orderType: ProcurementInboundOrderType.purchase,
              )
            : const ProcurementReturnTaskDetailPage(id: 'exception-1'),
      ),
    ),
  );
  await _frames(tester);
  return container;
}

void _confirm(ProviderContainer container) =>
    (container.read(sessionSnapshotProvider.notifier) as _Snapshots).confirm();

void main() {
  testWidgets(
    'mixed complete permission cannot expose an action on a foreign read-only row',
    (tester) async {
      final api = _Api();
      await _pump(tester, api);
      await tester.pumpAndSettle();
      expect(find.textContaining('原归属货品'), findsOneWidget);
      expect(find.byKey(const Key('supplier-return-confirm')), findsNothing);
      expect(api.writes, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'same-account scope revalidation hides the cached detail and rejects its late response after A-B-A',
    (tester) async {
      final api = _Api();
      final container = await _pump(tester, api);
      await tester.pumpAndSettle();
      expect(find.textContaining('原归属货品'), findsOneWidget);
      final late = Completer<Map<String, dynamic>>();
      api.gates.add(late);
      container.read(readScopeRevisionProvider.notifier).state++;
      await _frames(tester);
      expect(find.textContaining('原归属货品'), findsNothing);
      container.read(_owner.notifier).state = const AuthenticatedScope(
        userId: 'b',
      );
      await tester.pump();
      container.read(_owner.notifier).state = _a;
      api.marker = '新归属货品';
      _confirm(container);
      await tester.pumpAndSettle();
      expect(find.textContaining('新归属货品'), findsOneWidget);
      late.complete(api.detail('迟到旧归属货品'));
      await tester.pumpAndSettle();
      expect(find.textContaining('迟到旧归属货品'), findsNothing);
      expect(find.textContaining('新归属货品'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'scope changes retire the pending confirmation before any return command is dispatched',
    (tester) async {
      final api = _Api()..actionable = true;
      final container = await _pump(tester, api);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('supplier-return-confirm')));
      await tester.pumpAndSettle();
      expect(find.text('确认已退回'), findsOneWidget);
      final gate = Completer<Map<String, dynamic>>();
      api.gates.add(gate);
      container.read(readScopeRevisionProvider.notifier).state++;
      await _frames(tester);
      expect(find.text('确认已退回'), findsNothing);
      expect(api.writes, isEmpty);
      // A cancelled String-result dialog must close with null, not a bool cast.
      await tester.tap(find.byType(UtenCloseButton).last);
      await _frames(tester);
      gate.complete(api.detail('重新核对货品'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'an in-flight completion keeps its lock through owner changes and cannot republish the old result',
    (tester) async {
      final api = _Api()..actionable = true;
      final write = Completer<Map<String, dynamic>>();
      api.writeGate = write;
      final container = await _pump(tester, api);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('supplier-return-confirm')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('确认已退回'));
      await _frames(tester);
      expect(api.writes, hasLength(1));
      expect(api.writes.single.path, endsWith('/return-1/complete'));
      expect(api.writes.single.body, {'expectedVersion': 7});
      container.read(_owner.notifier).state = const AuthenticatedScope(
        userId: 'b',
      );
      await tester.pump();
      container.read(_owner.notifier).state = _a;
      api.marker = '重新核对货品';
      _confirm(container);
      await _frames(tester);
      expect(find.text('正在记录退回供应商'), findsOneWidget);
      write.complete(api.detail('旧命令迟到货品'));
      await tester.pumpAndSettle();
      expect(find.textContaining('旧命令迟到货品'), findsNothing);
      expect(find.text('已记录退回供应商'), findsNothing);
      expect(api.writes, hasLength(1));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'supplier task list retires cached rows and cannot republish a pre-revocation page',
    (tester) async {
      final api = _Api();
      final container = await _pump(tester, api, list: true);
      await selectFilterSegment(tester, '待退回');
      await tester.pumpAndSettle();
      expect(find.textContaining('原归属货品'), findsOneWidget);
      final late = Completer<Map<String, dynamic>>();
      api.gates.add(late);
      await tester.tap(find.text('刷新'));
      await _frames(tester);
      container.read(readScopeRevisionProvider.notifier).state++;
      await tester.pump();
      expect(find.textContaining('原归属货品'), findsNothing);
      late.complete({
        'items': [api.detail('撤权前迟到货品')],
        'total': 1,
        'page': 1,
        'size': 20,
        'totalPages': 1,
      });
      await tester.pumpAndSettle();
      expect(find.textContaining('撤权前迟到货品'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );
}
