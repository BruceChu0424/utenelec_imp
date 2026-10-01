import 'dart:async';
import 'dart:collection';

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
import 'package:uten_imp/features/finance/models/finance_doc.dart';
import 'package:uten_imp/features/finance/pages/finance_doc_detail_page.dart';
import 'package:uten_imp/features/purchase/models/purchase_doc.dart';
import 'package:uten_imp/features/purchase/pages/purchase_doc_detail_page.dart';
import 'package:uten_imp/features/sales/models/sales_doc.dart';
import 'package:uten_imp/features/sales/pages/sales_doc_detail_page.dart';
import 'package:uten_imp/features/subcontract/models/subcontract_doc.dart';
import 'package:uten_imp/features/subcontract/pages/subcontract_doc_detail_page.dart';
import 'package:uten_imp/shared/auth/document_scope_capability.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/auth/session_snapshot_provider.dart';
import 'package:uten_imp/shared/providers/authenticated_scope_provider.dart';
import 'package:uten_imp/shared/providers/shared_providers.dart';
import 'package:uten_imp/shared/providers/session_provider.dart';
import 'package:uten_imp/shared/models/user.dart';

import '../../support/document_scope_capability_overrides.dart';
import '../../helpers/badge_summary_fixture.dart';

const _id = 'record-1';
const _a = AuthenticatedScope(userId: 'a');
final _scope = StateProvider<AuthenticatedScope?>((_) => _a);
final _server = StateProvider<String>((_) => 'https://a.invalid/api');
final _firstSnapshot = Provider<Future<SessionSnapshot?>?>((_) => null);
final _session = StateProvider<SessionState>(
  (_) => const SessionState(
    status: AuthStatus.authenticated,
    user: AppUser(id: 'a', code: 'a', name: '当前读者'),
  ),
);

class _Session extends SessionNotifier {
  @override
  SessionState build() => ref.watch(_session);
}

class _Snapshots extends SessionSnapshotNotifier {
  @override
  Future<SessionSnapshot?> build() async {
    final first = ref.read(_firstSnapshot);
    return first == null ? SessionSnapshot() : await first;
  }

  void emit(AsyncValue<SessionSnapshot?> next) => state = next;
}

enum _Family { sales, purchase, subcontract, finance }

extension on _Family {
  String path(bool request) => switch (this) {
    _Family.sales => '/sales/quotes/$_id',
    _Family.purchase => '/purchase/${request ? 'requests' : 'orders'}/$_id',
    _Family.subcontract => '/subcontract/orders/$_id',
    _Family.finance => '/finance/receipts/$_id',
  };
  DocumentDataScope get dataScope => switch (this) {
    _Family.sales => DocumentDataScope.sales,
    _Family.purchase => DocumentDataScope.purchase,
    _Family.subcontract => DocumentDataScope.subcontract,
    _Family.finance => DocumentDataScope.finance,
  };
  Widget page(bool request) => switch (this) {
    _Family.sales => const SalesDocDetailPage(
      docType: SalesDocType.quote,
      id: _id,
    ),
    _Family.purchase => PurchaseDocDetailPage(
      docType: request ? PurchaseDocType.request : PurchaseDocType.order,
      id: _id,
    ),
    _Family.subcontract => const SubcontractDocDetailPage(
      docType: SubcontractDocType.order,
      id: _id,
    ),
    _Family.finance => const FinanceDocDetailPage(
      docType: FinanceDocType.receipt,
      id: _id,
    ),
  };
}

class _Api extends ApiClient {
  _Api(this.family, {this.request = false}) : super(Dio());
  final _Family family;
  final bool request;
  final gates = Queue<Completer<Map<String, dynamic>>>();
  int reads = 0;
  int writes = 0;
  final puts = <({String path, Object? body})>[];
  String marker = 'A-private';
  Object? readError;
  Map<String, dynamic> extra = {};

  Map<String, dynamic> detail(String value) => {
    'id': _id,
    'billNo': value,
    'makerName': value,
    'makerId': 'maker-1',
    'billDate': '2026-10-01',
    'status': request ? 1 : 0,
    'writable': true,
    'closed': false,
    'canEdit': true,
    'canDelete': true,
    'reviewRevision': 4,
    'receiptKind': 'RECEIVABLE',
    'allowedActions': ['view', 'edit', 'delete', 'submit'],
    'items': [
      if (request)
        {
          'id': 'line-1',
          'qty': 10,
          'orderedQty': 0,
          'pendingQty': 0,
          'goodsNameSnapshot': '采购材料',
        },
    ],
    ...extra,
  };
  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    if (path == family.path(request)) {
      reads++;
      if (readError case final error?) throw error;
      return gates.isEmpty ? detail(marker) : gates.removeFirst().future;
    }
    return {'items': <Object>[], 'total': 0};
  }

  @override
  Future<List<Map<String, dynamic>>> getList(
    String path, {
    Map<String, dynamic>? query,
  }) async => [];
  @override
  Future<Map<String, dynamic>> post(
    String path, {
    Object? body,
    Map<String, dynamic>? headers,
    Map<String, dynamic>? query,
  }) async {
    writes++;
    return {};
  }

  @override
  Future<Map<String, dynamic>> put(String path, {Object? body}) async {
    writes++;
    puts.add((path: path, body: body));
    if (request && body is Map) {
      extra = {
        ...extra,
        'items': [
          {
            'id': 'line-1',
            'qty': body['qty'],
            'orderedQty': 0,
            'pendingQty': 0,
          },
        ],
      };
    }
    return detail(marker);
  }
}

Future<ProviderContainer> _pump(
  WidgetTester tester,
  _Api api, {
  bool pending = false,
  SessionState? realSession,
  Future<SessionSnapshot?>? firstSnapshot,
}) async {
  await tester.binding.setSurfaceSize(const Size(2400, 1200));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  SharedPreferences.setMockInitialValues({'performancePreference': 'lite'});
  final prefs = await SharedPreferences.getInstance();
  final container = ProviderContainer(
    overrides: [
      apiClientProvider.overrideWithValue(api),
      fixedBadgeSummaryOverride(),
      if (firstSnapshot != null)
        _firstSnapshot.overrideWithValue(firstSnapshot),
      sharedPreferencesProvider.overrideWithValue(prefs),
      if (realSession == null)
        authenticatedScopeProvider.overrideWith((ref) => ref.watch(_scope)),
      sessionProvider.overrideWith(_Session.new),
      if (realSession != null) _session.overrideWith((ref) => realSession),
      apiBaseUrlProvider.overrideWith((ref) => ref.watch(_server)),
      sessionSnapshotProvider.overrideWith(_Snapshots.new),
      writeAllDocumentScope(api.family.dataScope),
      currentPermissionsProvider.overrideWithValue({
        Perm.salesQuoteView,
        Perm.purchaseOrderView,
        Perm.purchaseOrderEdit,
        Perm.purchaseOrderDelete,
        Perm.purchaseRequestView,
        Perm.purchaseOrderDecompose,
        Perm.subcontractOrderView,
        Perm.subcontractOrderEdit,
        Perm.subcontractOrderDelete,
        Perm.financeReceiptView,
        Perm.financeReceiptEdit,
        Perm.financeReceiptDelete,
        Perm.financeReceiptApprove,
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
        home: api.family.page(api.request),
      ),
    ),
  );
  if (pending) {
    await _frames(tester);
  } else {
    await tester.pumpAndSettle();
  }
  return container;
}

Future<void> _frames(WidgetTester tester) async {
  for (var i = 0; i < 6; i++) {
    await tester.pump(const Duration(milliseconds: 25));
  }
}

void _snapshot(
  ProviderContainer container,
  AsyncValue<SessionSnapshot?> value,
) => (container.read(sessionSnapshotProvider.notifier) as _Snapshots).emit(
  value,
);
void _loading(ProviderContainer container) => _snapshot(
  container,
  const AsyncLoading<SessionSnapshot?>().copyWithPrevious(
    container.read(sessionSnapshotProvider),
  ),
);
void _confirmed(ProviderContainer container) =>
    _snapshot(container, AsyncData(SessionSnapshot()));
bool _hasEditing(WidgetTester tester) => tester
    .widgetList<UtenButton>(find.byType(UtenButton))
    .any(
      (button) =>
          button.onPressed != null &&
          button.child is Text &&
          ['编辑', '审核', '删除', '提交财务核价'].contains((button.child as Text).data),
    );

void main() {
  for (final family in _Family.values) {
    for (final transition in ['account', 'server', 'actor']) {
      testWidgets(
        '${family.name} hides displayed fields immediately on $transition and rejects ABA late detail',
        (tester) async {
          final api = _Api(family);
          final container = await _pump(tester, api);
          expect(find.textContaining('A-private'), findsWidgets);
          final late = Completer<Map<String, dynamic>>();
          api.gates.add(late);
          _loading(container);
          if (transition == 'server') {
            container.read(_server.notifier).state = 'https://b.invalid/api';
          } else {
            container.read(_scope.notifier).state = transition == 'actor'
                ? const AuthenticatedScope(userId: 'a', actorId: 'operator')
                : const AuthenticatedScope(userId: 'b');
          }
          await tester.pump();
          expect(find.textContaining('A-private'), findsNothing);
          _confirmed(container);
          await _frames(tester);
          expect(api.reads, 2);
          _loading(container);
          if (transition == 'server') {
            container.read(_server.notifier).state = 'https://a.invalid/api';
          } else {
            container.read(_scope.notifier).state = _a;
          }
          api.marker = 'A-current';
          await tester.pump();
          expect(find.textContaining('A-private'), findsNothing);
          _confirmed(container);
          await tester.pumpAndSettle();
          expect(find.textContaining('A-current'), findsWidgets);
          late.complete(api.detail('B-late-private'));
          await tester.pumpAndSettle();
          expect(find.textContaining('B-late-private'), findsNothing);
          expect(find.textContaining('A-current'), findsWidgets);
          expect(api.writes, 0);
          expect(tester.takeException(), isNull);
        },
      );
    }
    for (final failure in [false, true]) {
      testWidgets(
        '${family.name} rejects initial A read late ${failure ? 'failure' : 'success'} after A-B-A',
        (tester) async {
          final old = Completer<Map<String, dynamic>>();
          final api = _Api(family)..gates.add(old);
          final container = await _pump(tester, api, pending: true);
          expect(api.reads, 1);
          _loading(container);
          container.read(_scope.notifier).state = const AuthenticatedScope(
            userId: 'b',
          );
          await tester.pump();
          container.read(_scope.notifier).state = _a;
          api.marker = 'A-current';
          await tester.pump();
          _confirmed(container);
          await tester.pumpAndSettle();
          expect(find.textContaining('A-current'), findsWidgets);
          if (failure) {
            old.completeError(ApiException('NETWORK', 'A-old-failure'));
          } else {
            old.complete(api.detail('A-old-private'));
          }
          await tester.pumpAndSettle();
          expect(find.textContaining('A-old-'), findsNothing);
          expect(find.textContaining('A-current'), findsWidgets);
          expect(api.reads, 2);
          expect(api.writes, 0);
          expect(tester.takeException(), isNull);
        },
      );
    }
    testWidgets(
      '${family.name} same-reader refresh hides unverified details and rechecks native capabilities',
      (tester) async {
        final api = _Api(family);
        final container = await _pump(tester, api);
        expect(_hasEditing(tester), isTrue);
        _loading(container);
        await tester.pumpAndSettle();
        expect(find.textContaining('A-private'), findsNothing);
        expect(_hasEditing(tester), isFalse);
        _snapshot(
          container,
          AsyncError<SessionSnapshot?>(
            StateError('offline'),
            StackTrace.current,
          ).copyWithPrevious(container.read(sessionSnapshotProvider)),
        );
        await tester.pumpAndSettle();
        expect(find.textContaining('A-private'), findsNothing);
        expect(_hasEditing(tester), isFalse);
        _confirmed(container);
        await tester.pumpAndSettle();
        expect(_hasEditing(tester), isTrue);
        expect(
          api.reads,
          2,
          reason:
              'confirmed permissions require a fresh native DTO, not old allowedActions',
        );
        expect(api.writes, 0);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'purchase inline input survives same-reader refresh but is cleared for another reader',
    (tester) async {
      final api = _Api(_Family.purchase, request: true);
      final container = await _pump(tester, api);
      final field = find.byKey(const ValueKey('purchase-request-qty-line-1'));
      expect(field, findsOneWidget);
      await tester.enterText(field, '37');
      final originalInput = tester.widget<TextField>(field).controller!;
      _loading(container);
      await tester.pumpAndSettle();
      expect(field, findsNothing);
      expect(
        originalInput.text,
        '37',
        reason: 'retain private local input while access is unverified',
      );
      _confirmed(container);
      await tester.pumpAndSettle();
      expect(tester.widget<TextField>(field).controller!.text, '37');
      expect(tester.widget<TextField>(field).controller, same(originalInput));
      expect(tester.widget<TextField>(field).enabled, isTrue);
      _loading(container);
      container.read(_scope.notifier).state = const AuthenticatedScope(
        userId: 'b',
      );
      await tester.pump();
      expect(field, findsNothing);
      api.marker = 'B-current';
      _confirmed(container);
      await tester.pumpAndSettle();
      expect(tester.widget<TextField>(field).controller!.text, '10');
      expect(api.writes, 0);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'quote confirmation cannot submit across permission refresh or expose old reader overlay',
    (tester) async {
      final api = _Api(_Family.sales);
      final container = await _pump(tester, api);
      await tester.tap(find.byKey(const ValueKey('sales-quote-submit')));
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsOneWidget);
      final originalConfirm = tester.widget<UtenButton>(
        find.descendant(
          of: find.byType(AlertDialog),
          matching: find.widgetWithText(UtenButton, '提交财务核价'),
        ),
      );
      _loading(container);
      await tester.pumpAndSettle();
      expect(find.text('操作权限已更新'), findsOneWidget);
      _confirmed(container);
      await tester.pumpAndSettle();
      expect(
        find.text('操作权限已更新'),
        findsOneWidget,
        reason: 'an old confirmation does not become current again',
      );
      originalConfirm.onPressed!();
      await tester.pumpAndSettle();
      expect(api.writes, 0);
      await tester.tap(find.byKey(const ValueKey('sales-quote-submit')));
      await tester.pumpAndSettle();
      _loading(container);
      container.read(_scope.notifier).state = const AuthenticatedScope(
        userId: 'b',
      );
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsNothing);
      expect(find.textContaining('A-private'), findsNothing);
      expect(api.writes, 0);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'purchase preserves same-base 37 and saves the exact current command once',
    (tester) async {
      final api = _Api(_Family.purchase, request: true);
      final container = await _pump(tester, api);
      final field = find.byKey(const ValueKey('purchase-request-qty-line-1'));
      await tester.enterText(field, '37');
      _loading(container);
      await tester.pumpAndSettle();
      _confirmed(container);
      await tester.pumpAndSettle();
      expect(tester.widget<TextField>(field).controller!.text, '37');
      await tester.tap(find.byKey(const Key('purchase-request-qty-save')));
      await tester.pumpAndSettle();
      expect(api.puts.map((entry) => entry.path).toList(), [
        '/purchase/requests/record-1/items/line-1/qty',
      ]);
      expect(api.puts.single.body, <String, dynamic>{'qty': 37.0});
      expect(api.writes, 1);
      expect(tester.widget<TextField>(field).controller!.text, '37');
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'purchase 10 to 20 refresh freezes original 37 instead of adopting the new base',
    (tester) async {
      final api = _Api(_Family.purchase, request: true);
      final container = await _pump(tester, api);
      final field = find.byKey(const ValueKey('purchase-request-qty-line-1'));
      await tester.enterText(field, '37');
      await tester.pump();
      expect(
        find.byKey(const Key('purchase-request-qty-save')),
        findsOneWidget,
      );
      final priorSave = tester
          .widget<UtenButton>(
            find.byKey(const Key('purchase-request-qty-save')),
          )
          .onPressed!;
      _loading(container);
      await tester.pumpAndSettle();
      api.extra = {
        'items': [
          {'id': 'line-1', 'qty': 20, 'orderedQty': 0, 'pendingQty': 0},
        ],
      };
      _confirmed(container);
      await tester.pumpAndSettle();
      expect(tester.widget<TextField>(field).controller!.text, '37');
      expect(tester.widget<TextField>(field).enabled, isFalse);
      expect(
        find.byKey(const Key('purchase-request-qty-input-conflict')),
        findsOneWidget,
      );
      priorSave();
      await tester.pumpAndSettle();
      expect(api.puts, isEmpty);
      expect(api.writes, 0);
      await tester.tap(
        find.byKey(const Key('purchase-request-qty-adopt-current')),
      );
      await tester.pumpAndSettle();
      expect(
        tester.widget<TextField>(field).controller!.text,
        '37',
        reason: 'opening review cannot silently discard the retained input',
      );
      await tester.tap(find.widgetWithText(FilledButton, '采用当前数量'));
      await tester.pumpAndSettle();
      expect(tester.widget<TextField>(field).controller!.text, '20');
      expect(
        find.byKey(const Key('purchase-request-qty-input-conflict')),
        findsNothing,
      );
      expect(api.puts, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );

  for (final family in _Family.values) {
    for (final invalid in [
      const SessionState(),
      const SessionState(
        status: AuthStatus.mustChangePassword,
        user: AppUser(id: 'a', code: 'a', name: '待改密'),
      ),
      const SessionState(status: AuthStatus.authenticated),
    ]) {
      testWidgets(
        '${family.name} rejects real null scope ${invalid.status.name}/${invalid.user != null}',
        (tester) async {
          final api = _Api(family);
          final container = await _pump(tester, api, realSession: invalid);
          expect(container.read(authenticatedScopeProvider), isNull);
          expect(find.textContaining('A-private'), findsNothing);
          expect(_hasEditing(tester), isFalse);
          expect(find.text('当前登录身份无效，原页面信息已隐藏'), findsOneWidget);
          expect(api.reads, 0);
          expect(api.writes, 0);
          expect(tester.takeException(), isNull);
        },
      );
    }
    testWidgets(
      '${family.name} confirmed loss of view hides old fields and closes exports/actions',
      (tester) async {
        final api = _Api(family);
        final container = await _pump(tester, api);
        expect(find.textContaining('A-private'), findsWidgets);
        _loading(container);
        await tester.pumpAndSettle();
        api.readError = ApiException('FORBIDDEN', '当前已无查看权限', httpStatus: 403);
        _confirmed(container);
        await tester.pumpAndSettle();
        expect(api.reads, 2);
        expect(find.text('当前已无查看权限'), findsOneWidget);
        expect(find.textContaining('A-private'), findsNothing);
        expect(_hasEditing(tester), isFalse);
        expect(api.writes, 0);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'confirmed quote refresh removes convert and all old price text using fresh native authority',
    (tester) async {
      final api = _Api(_Family.sales)
        ..extra = {
          'status': 1,
          'allowedActions': ['convert'],
          'totalLocal': 987654.32,
        };
      final container = await _pump(tester, api);
      final convert = find.byKey(const ValueKey('sales-quote-convert'));
      expect(convert, findsOneWidget);
      expect(find.textContaining('987654.32'), findsWidgets);
      final previousConvert = tester.widget<UtenButton>(convert).onPressed!;
      _loading(container);
      await tester.pumpAndSettle();
      expect(find.textContaining('987654.32'), findsNothing);
      api.extra = {
        'status': 1,
        'allowedActions': <String>[],
        'priceMasked': true,
        'totalLocal': 987654.32,
      };
      _confirmed(container);
      await tester.pumpAndSettle();
      expect(api.reads, 2);
      expect(convert, findsNothing);
      expect(find.textContaining('987654.32'), findsNothing);
      previousConvert();
      await tester.pumpAndSettle();
      expect(
        find.byType(AlertDialog),
        findsNothing,
        reason: 'a queued old button must recheck the fresh allowedActions',
      );
      expect(api.writes, 0);
      expect(tester.takeException(), isNull);
    },
  );

  for (final family in _Family.values) {
    testWidgets(
      '${family.name} delays its only first detail until Me confirms current view',
      (tester) async {
        final me = Completer<SessionSnapshot?>();
        final api = _Api(family);
        await _pump(tester, api, pending: true, firstSnapshot: me.future);
        expect(
          api.reads,
          0,
          reason:
              'an immediately available old detail must not be fetched before Me',
        );
        expect(find.textContaining('A-private'), findsNothing);
        expect(_hasEditing(tester), isFalse);
        api.readError = ApiException(
          'FORBIDDEN',
          '首次核对后已无查看权限',
          httpStatus: 403,
        );
        me.complete(SessionSnapshot());
        await tester.pumpAndSettle();
        expect(api.reads, 1);
        expect(find.text('首次核对后已无查看权限'), findsOneWidget);
        expect(find.textContaining('A-private'), findsNothing);
        expect(_hasEditing(tester), isFalse);
        expect(api.writes, 0);
        expect(tester.takeException(), isNull);
      },
    );
  }
  testWidgets(
    'quote waits for late first Me before fetching current masked price and actions',
    (tester) async {
      final me = Completer<SessionSnapshot?>();
      final api = _Api(_Family.sales)
        ..extra = {
          'status': 1,
          'allowedActions': ['convert'],
          'totalLocal': 987654.32,
        };
      await _pump(tester, api, pending: true, firstSnapshot: me.future);
      expect(api.reads, 0);
      expect(find.textContaining('987654.32'), findsNothing);
      expect(find.byKey(const ValueKey('sales-quote-convert')), findsNothing);
      api.extra = {
        'status': 1,
        'allowedActions': <String>[],
        'priceMasked': true,
        'totalLocal': 987654.32,
      };
      me.complete(SessionSnapshot());
      await tester.pumpAndSettle();
      expect(
        api.reads,
        1,
        reason: 'one native read, started only after first Me confirmation',
      );
      expect(find.textContaining('A-private'), findsWidgets);
      expect(find.textContaining('987654.32'), findsNothing);
      expect(find.byKey(const ValueKey('sales-quote-convert')), findsNothing);
      expect(api.writes, 0);
      expect(tester.takeException(), isNull);
    },
  );
}
