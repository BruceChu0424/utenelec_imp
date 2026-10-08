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
import 'package:uten_imp/features/purchase/models/purchase_doc.dart';
import 'package:uten_imp/features/purchase/pages/purchase_doc_detail_page.dart';
import 'package:uten_imp/features/purchase/repositories/purchase_repository.dart';
import 'package:uten_imp/shared/auth/document_scope_capability.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/auth/session_snapshot_provider.dart';
import 'package:uten_imp/shared/models/user.dart';
import 'package:uten_imp/shared/providers/authenticated_scope_provider.dart';
import 'package:uten_imp/shared/providers/session_provider.dart';
import 'package:uten_imp/shared/providers/shared_providers.dart';

import '../../helpers/badge_summary_fixture.dart';
import '../../support/document_scope_capability_overrides.dart';

final _permissions = StateProvider<Set<String>>(
  (ref) => {Perm.purchaseRequestView, Perm.purchaseOrderDecompose},
);

class _Session extends SessionNotifier {
  @override
  SessionState build() => const SessionState(
    status: AuthStatus.authenticated,
    user: AppUser(id: 'qty-reader', code: 'reader', name: '当前读者'),
  );
}

class _Snapshots extends SessionSnapshotNotifier {
  @override
  Future<SessionSnapshot?> build() async => SessionSnapshot();

  void loading() => state = const AsyncLoading<SessionSnapshot?>();
  void confirm() => state = AsyncData(SessionSnapshot());
}

typedef _Reply =
    Future<Map<String, dynamic>> Function(String id, Map<String, dynamic> body);

class _Api extends ApiClient {
  _Api() : super(Dio());

  int reads = 0;
  final puts = <({String path, Map<String, dynamic> body})>[];
  final replies = Queue<_Reply>();
  final rows = <Map<String, dynamic>>[
    {
      'id': 'line-1',
      'qty': 10,
      'rowVersion': 7,
      'orderedQty': 0,
      'pendingQty': 0,
    },
  ];

  Map<String, dynamic> detail() => {
    'id': 'request-1',
    'billNo': 'CAS-001',
    'makerId': 'maker-1',
    'makerName': '计划员',
    'billDate': '2026-10-01',
    'status': 1,
    'closed': false,
    'productionLinked': true,
    'items': [for (final row in rows) Map<String, dynamic>.of(row)],
  };

  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    if (path == '/purchase/requests/request-1') {
      reads++;
      return detail();
    }
    return {'items': <Object>[], 'total': 0};
  }

  @override
  Future<List<Map<String, dynamic>>> getList(
    String path, {
    Map<String, dynamic>? query,
  }) async => [];

  @override
  Future<Map<String, dynamic>> put(String path, {Object? body}) async {
    final command = Map<String, dynamic>.from(body! as Map);
    puts.add((path: path, body: command));
    final id = path.split('/')[5];
    if (replies.isNotEmpty) return replies.removeFirst()(id, command);
    return apply(id, command);
  }

  Map<String, dynamic> apply(String id, Map<String, dynamic> body) {
    final row = rows.singleWhere((row) => row['id'] == id);
    expect(body['expectedVersion'], row['rowVersion']);
    row['qty'] = body['qty'];
    row['rowVersion'] = (row['rowVersion'] as int) + 1;
    return detail();
  }
}

Future<ProviderContainer> _pump(WidgetTester tester, _Api api) async {
  await tester.binding.setSurfaceSize(const Size(2400, 1400));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  SharedPreferences.setMockInitialValues({'performancePreference': 'lite'});
  final prefs = await SharedPreferences.getInstance();
  final container = ProviderContainer(
    overrides: [
      apiClientProvider.overrideWithValue(api),
      sharedPreferencesProvider.overrideWithValue(prefs),
      sessionProvider.overrideWith(_Session.new),
      fixedBadgeSummaryOverride(),
      authenticatedScopeProvider.overrideWithValue(
        const AuthenticatedScope(userId: 'qty-reader'),
      ),
      apiBaseUrlProvider.overrideWithValue('https://cas.invalid/api'),
      sessionSnapshotProvider.overrideWith(_Snapshots.new),
      currentPermissionsProvider.overrideWith((ref) => ref.watch(_permissions)),
      isSuperAdminProvider.overrideWithValue(false),
      writeAllDocumentScope(DocumentDataScope.purchase),
    ],
  );
  addTearDown(container.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: const MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: Locale('zh'),
        home: PurchaseDocDetailPage(
          docType: PurchaseDocType.request,
          id: 'request-1',
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return container;
}

Finder _field([String id = 'line-1']) =>
    find.byKey(ValueKey('purchase-request-qty-$id'));

Finder get _save => find.byKey(const Key('purchase-request-qty-save'));

TextEditingController _controller(
  WidgetTester tester, [
  String id = 'line-1',
]) => tester.widget<TextField>(_field(id)).controller!;

Future<VoidCallback> _enter(WidgetTester tester, String value) async {
  await tester.enterText(_field(), value);
  await tester.pumpAndSettle();
  return tester.widget<UtenButton>(_save).onPressed!;
}

Future<void> _recheck(WidgetTester tester, ProviderContainer container) async {
  final snapshots =
      container.read(sessionSnapshotProvider.notifier) as _Snapshots;
  snapshots.loading();
  await tester.pumpAndSettle();
  snapshots.confirm();
  await tester.pumpAndSettle();
}

Future<void> _adoptVersion(WidgetTester tester) async {
  await tester.tap(find.byKey(const Key('purchase-request-qty-adopt-current')));
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(const Key('purchase-request-qty-adopt-version')));
  await tester.pumpAndSettle();
}

void main() {
  test(
    'row version remains the original integer and missing never becomes zero',
    () {
      for (final version in [0, 7, 2147483648, 9007199254740991]) {
        expect(
          PurchaseDocItem.fromJson({
            'id': 'line',
            'rowVersion': version,
          }).rowVersion,
          version,
        );
      }
      for (final version in [null, -1, 7.5, '7']) {
        expect(
          PurchaseDocItem.fromJson({
            'id': 'line',
            'rowVersion': version,
          }).rowVersion,
          isNull,
        );
      }
      expect(PurchaseDocItem.fromJson({'id': 'line'}).rowVersion, isNull);
    },
  );

  test(
    'repository sends the original CAS token without a qty-only fallback',
    () async {
      final api = _Api();
      final detail = await PurchaseRepository(api, PurchaseDocType.request)
          .adjustRequestItemQty(
            requestId: 'request-1',
            itemId: 'line-1',
            qty: 37,
            expectedVersion: 7,
          );
      expect(
        api.puts.single.path,
        '/purchase/requests/request-1/items/line-1/qty',
      );
      expect(api.puts.single.body, {'qty': 37.0, 'expectedVersion': 7});
      expect(detail.items.single.rowVersion, 8);
    },
  );

  testWidgets(
    'missing DTO version keeps quantity read-only until a fresh version arrives',
    (tester) async {
      final api = _Api()..rows.single.remove('rowVersion');
      final container = await _pump(tester, api);
      expect(_field(), findsNothing);
      expect(
        find.byKey(const Key('purchase-request-qty-missing-version')),
        findsOneWidget,
      );
      expect(_save, findsNothing);
      api.rows.single['rowVersion'] = 0;
      await _recheck(tester, container);
      await _enter(tester, '37');
      await tester.tap(_save);
      await tester.pumpAndSettle();
      expect(api.puts.single.body, {'qty': 37.0, 'expectedVersion': 0});
    },
  );

  for (final status in [401, 403, 409]) {
    testWidgets(
      '$status preserves 37 and original version across GET until explicit review',
      (tester) async {
        final api = _Api();
        final container = await _pump(tester, api);
        final staleSave = await _enter(tester, '37');
        api.replies.add((id, body) async {
          if (status == 409) api.rows.single['rowVersion'] = 9;
          throw ApiException('REJECTED', '拒绝保存', httpStatus: status);
        });
        await tester.tap(_save);
        await tester.pumpAndSettle();
        expect(api.puts.single.body, {'qty': 37.0, 'expectedVersion': 7});
        expect(api.reads, 2);
        expect(_controller(tester).text, '37');
        expect(tester.widget<TextField>(_field()).enabled, isFalse);
        expect(find.textContaining('原数量 10，当前数量'), findsOneWidget);
        staleSave();
        await tester.pumpAndSettle();
        await _recheck(tester, container);
        expect(api.puts, hasLength(1));
        expect(_controller(tester).text, '37');
        expect(find.textContaining('原数量 10，当前数量'), findsOneWidget);
        await _adoptVersion(tester);
        expect(api.puts, hasLength(1));
        expect(_controller(tester).text, '37');
        await tester.tap(_save);
        await tester.pumpAndSettle();
        expect(api.puts.last.body, {
          'qty': 37.0,
          'expectedVersion': status == 409 ? 9 : 7,
        });
        expect(tester.takeException(), isNull);
      },
    );
  }

  for (final committed in [false, true]) {
    testWidgets(
      'unknown result committed=$committed only GETs and never guesses success from equal quantity',
      (tester) async {
        final api = _Api();
        final container = await _pump(tester, api);
        final staleSave = await _enter(tester, '37');
        api.replies.add((id, body) async {
          if (committed) api.apply(id, body);
          throw NetworkTimeoutException();
        });
        await tester.tap(_save);
        await tester.pumpAndSettle();
        expect(api.puts, hasLength(1));
        expect(api.reads, 2);
        expect(_controller(tester).text, '37');
        expect(tester.widget<TextField>(_field()).enabled, isFalse);
        expect(find.textContaining('原数量 10，当前数量'), findsOneWidget);
        expect(find.text('数量已修正'), findsNothing);
        staleSave();
        await _recheck(tester, container);
        expect(api.puts, hasLength(1));
        expect(_controller(tester).text, '37');
        expect(tester.widget<TextField>(_field()).enabled, isFalse);
        await _adoptVersion(tester);
        expect(api.puts, hasLength(1));
        expect(_controller(tester).text, '37');
        if (committed) expect(_save, findsNothing);
        expect(tester.takeException(), isNull);
      },
    );
  }

  for (final invalid in [
    'missing-version',
    'stale-version',
    'wrong-quantity',
  ]) {
    testWidgets('invalid $invalid acknowledgement remains unknown', (
      tester,
    ) async {
      final api = _Api();
      await _pump(tester, api);
      await _enter(tester, '37');
      api.replies.add((id, body) async {
        final response = api.detail();
        final row = (response['items'] as List).single as Map<String, dynamic>;
        row['qty'] = invalid == 'wrong-quantity' ? 20 : 37;
        row['rowVersion'] = invalid == 'stale-version' ? 7 : 8;
        if (invalid == 'missing-version') row.remove('rowVersion');
        return response;
      });
      await tester.tap(_save);
      await tester.pumpAndSettle();
      expect(api.puts, hasLength(1));
      expect(api.reads, 2);
      expect(_controller(tester).text, '37');
      expect(tester.widget<TextField>(_field()).enabled, isFalse);
      expect(find.textContaining('原数量 10，当前数量'), findsOneWidget);
      expect(find.text('数量已修正'), findsNothing);
    });
  }

  testWidgets(
    'same quantity with advanced version freezes dirty input until review',
    (tester) async {
      final api = _Api();
      final container = await _pump(tester, api);
      final staleSave = await _enter(tester, '37');
      api.rows.single['rowVersion'] = 8;
      await _recheck(tester, container);
      expect(_controller(tester).text, '37');
      expect(tester.widget<TextField>(_field()).enabled, isFalse);
      staleSave();
      await tester.pumpAndSettle();
      expect(api.puts, isEmpty);
      await _adoptVersion(tester);
      await tester.tap(_save);
      await tester.pumpAndSettle();
      expect(api.puts.single.body, {'qty': 37.0, 'expectedVersion': 8});
    },
  );

  testWidgets(
    'first successful row is not replayed when a later row has unknown outcome',
    (tester) async {
      final api = _Api();
      api.rows.add({
        'id': 'line-2',
        'qty': 20,
        'rowVersion': 4,
        'orderedQty': 0,
        'pendingQty': 0,
      });
      await _pump(tester, api);
      await _enter(tester, '37');
      await tester.enterText(_field('line-2'), '42');
      await tester.pumpAndSettle();
      api.replies.add((id, body) async => api.apply(id, body));
      api.replies.add((id, body) async => throw NetworkTimeoutException());
      await tester.tap(_save);
      await tester.pumpAndSettle();
      expect(api.puts.map((call) => call.body).toList(), [
        {'qty': 37.0, 'expectedVersion': 7},
        {'qty': 42.0, 'expectedVersion': 4},
      ]);
      expect(_controller(tester).text, '37');
      expect(_controller(tester, 'line-2').text, '42');
      await _adoptVersion(tester);
      await tester.tap(_save);
      await tester.pumpAndSettle();
      expect(api.puts, hasLength(3));
      expect(api.puts.last.path, endsWith('/line-2/qty'));
      expect(api.puts.last.body, {'qty': 42.0, 'expectedVersion': 4});
    },
  );

  testWidgets(
    'late PUT after permission refresh cannot confirm or replace retained input',
    (tester) async {
      final api = _Api();
      final container = await _pump(tester, api);
      await _enter(tester, '37');
      final put = Completer<Map<String, dynamic>>();
      api.replies.add((id, body) => put.future);
      await tester.tap(_save);
      await tester.pump();
      await _recheck(tester, container);
      expect(_controller(tester).text, '37');
      expect(tester.widget<TextField>(_field()).enabled, isFalse);
      put.complete(api.apply('line-1', api.puts.single.body));
      await tester.pumpAndSettle();
      expect(_controller(tester).text, '37');
      expect(find.textContaining('原数量 10，当前数量'), findsOneWidget);
      expect(find.text('数量已修正'), findsNothing);
      expect(api.puts, hasLength(1));
    },
  );
}
