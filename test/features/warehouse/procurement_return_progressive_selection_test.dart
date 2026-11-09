import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/components/buttons/uten_button.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/network/api_exception.dart';
import 'package:uten_imp/core/network/server_config.dart';
import 'package:uten_imp/features/warehouse/pages/procurement_return_task_pages.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/auth/session_snapshot_provider.dart';
import 'package:uten_imp/shared/models/procurement_inbound.dart';
import 'package:uten_imp/shared/providers/authenticated_scope_provider.dart';
import 'package:uten_imp/shared/providers/shared_providers.dart';

import '../../helpers/badge_summary_fixture.dart';
import '../../support/filter_segment_tap.dart';

const _total = 120;
const _failure = '待退任务读取中断，请重试';

class _Snapshots extends SessionSnapshotNotifier {
  @override
  Future<SessionSnapshot?> build() async => SessionSnapshot();
}

Map<String, dynamic> _task(int index) => {
  'id': 'exception-$index',
  'orderType': 'PURCHASE',
  'receiptId': 'receipt-$index',
  'receiptItemId': 'receipt-line-$index',
  'receiptBillNo': 'PR-$index',
  'orderId': 'order-$index',
  'orderItemId': 'order-line-$index',
  'orderBillNo': 'PO-$index',
  'goodsCode': 'G-$index',
  'goodsName': '待退货品$index',
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
    'id': 'return-$index',
    'qty': 5,
    'status': 'PENDING_RETURN',
    'version': 7,
  },
  'allowedActions': ['COMPLETE_RETURN'],
};

/// Offset-exact owner tasks. While [continuation] is set, every batch after
/// the first waits for it (and then fails while [failContinuation]), so the
/// first batch stays a growing prefix.
class _Api extends ApiClient {
  _Api() : super(Dio());

  final queries = <Map<String, dynamic>>[];
  final writes = <String>[];
  Completer<void>? continuation;
  bool failContinuation = false;

  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    if (!path.endsWith('/tasks')) return _task(0);
    queries.add({...?query});
    final page = query!['page'] as int;
    final size = query['size'] as int;
    if ((page - 1) * size > 0 && continuation != null) {
      await continuation!.future;
      if (failContinuation) {
        throw ApiException('SERVICE_UNAVAILABLE', _failure, httpStatus: 503);
      }
    }
    return {
      'items': [
        for (var i = (page - 1) * size; i < page * size && i < _total; i++)
          _task(i),
      ],
      'page': page,
      'size': size,
      'total': _total,
      'totalPages': (_total + size - 1) ~/ size,
    };
  }

  @override
  Future<Map<String, dynamic>> post(
    String path, {
    Object? body,
    Map<String, dynamic>? headers,
    Map<String, dynamic>? query,
  }) async {
    writes.add(path);
    return _task(0);
  }
}

Finder _check(int index) => find.descendant(
  of: find.byKey(Key('procurement-return-task-exception-$index')),
  matching: find.byType(Checkbox),
);

UtenButton _button(WidgetTester tester, String label) => tester.widget(
  find.ancestor(of: find.text(label), matching: find.byType(UtenButton)),
);

Future<void> _untilGrowing(WidgetTester tester, _Api api, int reads) async {
  for (var frame = 0; frame < 60; frame++) {
    await tester.pump(const Duration(milliseconds: 16));
    if (api.queries.length >= reads + 2) break;
  }
  await tester.pump(const Duration(milliseconds: 16));
}

void main() {
  testWidgets(
    'while the task list is still growing, checking, 全选本页 and the batch '
    'return wait for the complete result; a failed read leaves no count or '
    'conclusion derived from withdrawn rows; the kept selection survives',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1600, 1000));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      SharedPreferences.setMockInitialValues({'performancePreference': 'lite'});
      final prefs = await SharedPreferences.getInstance();
      final api = _Api()..continuation = Completer<void>();
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            apiClientProvider.overrideWithValue(api),
            fixedBadgeSummaryOverride(),
            sharedPreferencesProvider.overrideWithValue(prefs),
            authenticatedScopeProvider.overrideWithValue(
              const AuthenticatedScope(userId: 'a'),
            ),
            apiBaseUrlProvider.overrideWithValue('https://a.invalid/api'),
            sessionSnapshotProvider.overrideWith(_Snapshots.new),
            currentPermissionsProvider.overrideWithValue({
              Perm.supplierReturnTaskView,
              Perm.supplierReturnTaskViewAll,
              Perm.supplierReturnTaskComplete,
            }),
            isSuperAdminProvider.overrideWithValue(false),
          ],
          child: const MaterialApp(
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            locale: Locale('zh'),
            home: ProcurementReturnTasksPage(
              orderType: ProcurementInboundOrderType.purchase,
            ),
          ),
        ),
      );
      await tester.pump();
      await selectFilterSegment(tester, '待退回');
      await _untilGrowing(tester, api, 0);

      // The first batch shows while the read continues; its cards cannot be
      // checked yet, so no batch entry appears.
      expect(api.queries.map((query) => (query['page'], query['size'])), [
        (1, 50),
        (2, 50),
      ]);
      expect(_check(0), findsOneWidget);
      expect(tester.widget<Checkbox>(_check(0)).onChanged, isNull);
      expect(find.text('全选本页'), findsNothing);
      expect(find.textContaining('批量确认退回'), findsNothing);

      api.continuation!.complete();
      await tester.pumpAndSettle();
      expect(tester.widget<Checkbox>(_check(0)).onChanged, isNotNull);
      await tester.tap(_check(0));
      await tester.pump();
      expect(_button(tester, '全选本页').onPressed, isNotNull);
      expect(_button(tester, '批量确认退回 1').onPressed, isNotNull);

      // A new query keeps the selection. While its rows grow, 全选本页 would
      // select only the shown prefix and the batch return would write: both
      // wait for the complete result, and the batch shows no count taken from
      // the prefix.
      api.continuation = Completer<void>();
      var reads = api.queries.length;
      await tester.enterText(find.byType(TextField).first, '待退货品');
      await _untilGrowing(tester, api, reads);
      expect(api.queries.skip(reads).map((query) => query['keyword']), [
        '待退货品',
        '待退货品',
      ]);
      expect(tester.widget<Checkbox>(_check(0)).value, isTrue);
      expect(tester.widget<Checkbox>(_check(1)).onChanged, isNull);
      expect(_button(tester, '全选本页').onPressed, isNull);
      expect(_button(tester, '批量确认退回').onPressed, isNull);
      expect(_button(tester, '批量确认退回').onDisabledTap, isNull);

      api.continuation!.complete();
      await tester.pumpAndSettle();
      expect(tester.widget<Checkbox>(_check(0)).value, isTrue);
      expect(tester.widget<Checkbox>(_check(1)).onChanged, isNotNull);
      expect(_button(tester, '全选本页').onPressed, isNotNull);
      expect(_button(tester, '批量确认退回 1').onPressed, isNotNull);

      // Another query fails after its first batch: the cards are withdrawn
      // beside the error and its reload entry. The kept selection stays, but
      // the batch return claims no count and no "all returned" conclusion
      // from rows that are no longer there.
      api
        ..continuation = Completer<void>()
        ..failContinuation = true;
      reads = api.queries.length;
      await tester.enterText(find.byType(TextField).first, '待退');
      await _untilGrowing(tester, api, reads);
      api.continuation!.complete();
      await tester.pumpAndSettle();
      expect(_check(0), findsNothing);
      expect(find.textContaining(_failure), findsWidgets);
      expect(find.text('重新加载'), findsOneWidget);
      expect(find.text('批量确认退回 0'), findsNothing);
      expect(_button(tester, '批量确认退回').onPressed, isNull);
      expect(_button(tester, '批量确认退回').onDisabledTap, isNull);

      api
        ..continuation = null
        ..failContinuation = false;
      await tester.tap(find.text('重新加载'));
      await tester.pumpAndSettle();
      expect(tester.widget<Checkbox>(_check(0)).value, isTrue);
      expect(_button(tester, '批量确认退回 1').onPressed, isNotNull);
      expect(api.writes, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );
}
