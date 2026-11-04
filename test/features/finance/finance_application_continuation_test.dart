import 'dart:async';
import 'dart:convert';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/network/server_config.dart';
import 'package:uten_imp/core/theme/light_theme.dart';
import 'package:uten_imp/components/inputs/uten_dropdown_field.dart';
import 'package:uten_imp/features/applications/models/business_application.dart';
import 'package:uten_imp/features/applications/widgets/business_application_print.dart';
import 'package:uten_imp/features/finance/models/finance_doc.dart';
import 'package:uten_imp/features/finance/pages/finance_application_continuation_page.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/auth/session_snapshot_provider.dart';
import 'package:uten_imp/shared/drafts/form_draft_store.dart';
import 'package:uten_imp/shared/models/user.dart';
import 'package:uten_imp/shared/providers/session_provider.dart';
import 'package:uten_imp/shared/providers/shared_providers.dart';
import '../../shared/drafts/memory_form_draft_storage.dart';

const _origin = '10000000-0000-4000-8000-000000000001';
const _native = '20000000-0000-4000-8000-000000000002';
const _full = '100.123456789012345678901234';

class _Session extends SessionNotifier {
  @override
  SessionState build() => const SessionState(
    status: AuthStatus.authenticated,
    user: AppUser(
      id: 'u1',
      employeeId: 'e1',
      code: 'ANON',
      name: '匿名经办',
      department: '财务',
      permissions: [Perm.financeApplicationApply, Perm.applicationApply],
    ),
  );
}

class _Snapshot extends SessionSnapshotNotifier {
  @override
  Future<SessionSnapshot?> build() async => SessionSnapshot();
}

class _Api extends ApiClient {
  _Api() : super(Dio());
  final reviews = <Map<String, dynamic>>[], confirms = <Map<String, dynamic>>[];
  Completer<void>? pending;
  bool travelZero = false;
  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    if (path.endsWith('/receipt')) return {'found': false};
    if (path.endsWith('/references')) {
      return {
        'currencies': [
          {
            'id': '30000000-0000-4000-8000-000000000003',
            'code': 'CNY',
            'name': '人民币',
          },
        ],
      };
    }
    return {
      'id': _origin,
      'kind': travelZero ? 'TRAVEL_APPLICATION' : 'PAYMENT_APPLICATION',
      if (travelZero) 'amount_original': '0',
      'row_version': 7,
      'requested_payload': {'paymentNature': 'GENERAL_EXPENSE'},
    };
  }

  @override
  Future<Map<String, dynamic>> post(
    String path, {
    Object? body,
    Map<String, dynamic>? headers,
    Map<String, dynamic>? query,
  }) async {
    final value = Map<String, dynamic>.from(body as Map);
    if (path.endsWith('/review')) {
      reviews.add(value);
      return {
        'reviewId': 'review-token',
        'reviewedFingerprint': 'a' * 64,
        'original': {
          'title': '匿名原申请',
          'requestedDate': '2026-11-01',
          'amountOriginal': travelZero ? '0' : _full,
          'currencyCode': travelZero ? 'CNY' : 'USD',
          'payload': {
            'lines': [
              {'label': '原义务', 'amountOriginal': _full},
            ],
          },
        },
        'attachments': [
          {'originalName': '原始凭证.pdf'},
        ],
        'proposed': {'businessKind': travelZero ? 'TRAVEL' : 'PAYMENT'},
      };
    }
    confirms.add(value);
    await pending?.future;
    return {'found': true, 'id': _native, 'location': '/applications/$_native'};
  }
}

Future<ProviderContainer> _mount(
  WidgetTester tester,
  _Api api, {
  String? raw,
}) async {
  SharedPreferences.setMockInitialValues({});
  final preferences = await SharedPreferences.getInstance();
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = const Size(1000, 1200);
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(tester.view.resetPhysicalSize);
  final container = ProviderContainer(
    overrides: [
      sessionProvider.overrideWith(_Session.new),
      sessionSnapshotProvider.overrideWith(_Snapshot.new),
      apiClientProvider.overrideWithValue(api),
      apiBaseUrlProvider.overrideWithValue('https://continuation.invalid/api'),
      sharedPreferencesProvider.overrideWithValue(preferences),
      formDraftStorageProvider.overrideWithValue(MemoryFormDraftStorage()),
    ],
  );
  final router = GoRouter(
    initialLocation: '/source',
    routes: [
      GoRoute(
        path: '/source',
        builder: (_, _) => FinanceApplicationContinuationPage(
          originId: _origin,
          kind: api.travelZero ? 'TRAVEL_APPLICATION' : 'PAYMENT_APPLICATION',
          originalCommand: raw,
        ),
      ),
      GoRoute(
        path: '/applications/:id',
        builder: (_, _) => const Scaffold(body: Text('当前草稿')),
      ),
    ],
  );
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox.shrink());
    container.dispose();
    router.dispose();
  });
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp.router(
        routerConfig: router,
        theme: buildLightTheme(),
        locale: const Locale('zh'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
      ),
    ),
  );
  await tester.pumpAndSettle();
  return container;
}

void main() {
  testWidgets(
    'rapid confirmation creates one request and preserves raw source and every decimal digit',
    (tester) async {
      final api = _Api()..pending = Completer<void>();
      final raw = jsonEncode({
        'id': _origin,
        'requestId': 'old-request',
        'amountOriginal': _full,
        'unknownOriginalField': '保留原文',
      });
      await _mount(tester, api, raw: raw);
      await tester.tap(find.text('审阅原稿').last);
      await tester.pumpAndSettle();
      expect(api.reviews.single['originalCommand'], raw);
      expect(find.text('原申请金额：$_full USD'), findsOneWidget);
      expect(find.textContaining('$_full USD'), findsNWidgets(2));
      final action = find.text('确认按当前流程继续');
      await tester.ensureVisible(action);
      for (var i = 0; i < 30; i++) {
        await tester.tap(action);
      }
      await tester.pump(const Duration(milliseconds: 100));
      expect(api.confirms, hasLength(1));
      expect(api.confirms.single['reviewedFingerprint'], 'a' * 64);
      api.pending!.complete();
      await tester.pumpAndSettle();
      expect(find.text('当前草稿'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'stored travel zero requires an explicit missing currency choice without defaulting',
    (tester) async {
      final api = _Api()..travelZero = true;
      await _mount(tester, api);
      final currency = find.byWidgetPredicate(
        (widget) => widget is UtenDropdownField && widget.label == '原稿金额币别',
      );
      expect(currency, findsOneWidget);
      await tester.tap(currency);
      await tester.pumpAndSettle();
      await tester.tap(find.text('CNY 人民币').last);
      await tester.pumpAndSettle();
      await tester.tap(find.text('审阅原稿').last);
      await tester.pumpAndSettle();
      expect(
        api.reviews.single['reviewedCurrencyId'],
        '30000000-0000-4000-8000-000000000003',
      );
      expect(find.text('原申请金额：0 CNY'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
  test(
    'foreign original print and candidate never adopt a local alias or RMB uppercase',
    () {
      final app = BusinessApplication(
        id: _native,
        applicationNo: 'SQ-ANON',
        kind: 'PREPAYMENT',
        title: '匿名原币',
        amount: _full,
        status: 'DRAFT',
        applicantId: 'e1',
        applicantName: '匿名',
        createdAt: DateTime(2026, 11),
        fields: const {},
        originalContext: const {
          'amountBasis': 'ORIGINAL',
          'currencyCode': 'USD',
          'baseCurrency': false,
        },
      );
      expect(app.amountLabel, '$_full USD');
      final rows = businessApplicationPrintRows(app);
      expect(rows.singleWhere((row) => row.first == '申请金额（USD）'), [
        '申请金额（USD）',
        _full,
      ]);
      expect(rows.singleWhere((row) => row.first == '金额大写'), [
        '金额大写',
        '原币 $_full USD',
      ]);
      final candidate = FinanceDocListItem.fromJson({
        'id': _native,
        'amountOriginalExact': _full,
      });
      expect(candidate.amountOriginalText, _full);
      expect(candidate.amountLocalText, isNull);
    },
  );
}
