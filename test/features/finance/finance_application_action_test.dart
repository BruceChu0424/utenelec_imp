import 'dart:convert';
import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:uten_imp/core/theme/light_theme.dart';
import '../../support/audit_screenshot_support.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/components/inputs/uten_dropdown_field.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/network/api_exception.dart';
import 'package:uten_imp/core/network/server_config.dart';
import 'package:uten_imp/features/finance/widgets/finance_application_detail.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/drafts/form_draft_mixin.dart';
import 'package:uten_imp/shared/drafts/form_draft_store.dart';
import 'package:uten_imp/shared/providers/authenticated_scope_provider.dart';
import 'package:uten_imp/shared/providers/session_provider.dart';
import 'package:uten_imp/shared/providers/shared_providers.dart';
import '../../shared/drafts/memory_form_draft_storage.dart';
import 'finance_requirement_test_ui.dart';

final _app = <String, dynamic>{
  'id': '10000000-0000-0000-0000-000000000001',
  'application_no': 'FQ20260900001',
  'kind': 'PAYMENT_APPLICATION',
  'kindLabel': '付款申请',
  'title': '原制造费用支付申请',
  'source_kind': 'PAYMENT_INTENT',
  'status': 'APPROVED',
  'row_version': 9,
  'source_fingerprint': 'a' * 64,
  'amount_original': '100.1234',
  'currency_id': 'base',
  'requested_payload': {
    'paymentNature': 'GENERAL_EXPENSE',
    'lines': [
      {'label': '原水电费用', 'amountOriginal': '100.1234'},
    ],
  },
};
void main() {
  test(
    'salary receipts distinguish actual bank cash noncash and original claim-only cancellation',
    () {
      expect(
        financeApplicationExecutionLabel({
          'doc_type': 'PAYROLL_PAYMENT',
          'result': {
            'receiptKind': 'NON_CASH_CLEARED',
            'sourceClaimOnly': true,
          },
        }),
        '非现金办理认领（原凭证保留）',
      );
      expect(
        financeApplicationActionLabel('reverse', {
          'executions': [
            {
              'state': 'CONFIRMED',
              'result': {
                'receiptKind': 'NON_CASH_CLEARED',
                'sourceClaimOnly': true,
              },
            },
          ],
        }),
        '撤销本次原凭证认领',
      );
      expect(
        financeApplicationActionLabel('reverse', {
          'executions': [
            {
              'state': 'CONFIRMED',
              'result': {'receiptKind': 'NON_CASH_CLEARED'},
            },
          ],
        }),
        '反审非现金清偿',
      );
      expect(
        financeApplicationExecutionLabel({
          'doc_type': 'PAYROLL_PAYMENT',
          'result': {'receiptKind': 'NO_FINANCIAL_EVENT'},
        }),
        '已核对无资金事件',
      );
      expect(
        financeApplicationActionLabel('reverse', {
          'executions': [
            {
              'state': 'CONFIRMED',
              'result': {'receiptKind': 'NO_FINANCIAL_EVENT'},
            },
          ],
        }),
        '撤销本次无资金核对',
      );
      expect(
        financeApplicationExecutionLabel({
          'doc_type': 'PAYROLL_PAYMENT',
          'result': {'receiptKind': 'BANK_PAYMENT'},
        }),
        '工资实际付款',
      );
    },
  );
  testWidgets(
    'rapid actual-payment clicks latch before asynchronous scope validation',
    (tester) async {
      final api = _Api()..gate = Completer<void>();
      final container = await _mount(tester, api, MemoryFormDraftStorage());
      for (var i = 0; i < 40; i++) {
        await tester.tap(find.text('登记实际付款').last);
      }
      await tester.pump();
      expect(api.requests, hasLength(1));
      api.gate!.complete();
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      container.dispose();
    },
  );
  testWidgets(
    'unknown payment preserves exact command through hard close and later explicit refusal',
    (tester) async {
      final api = _Api();
      final storage = MemoryFormDraftStorage();
      final first = await _mount(tester, api, storage);
      await _select(tester, '实际付款账户', 'TEST 匿名银行');
      await tester.enterText(financeTextField('银行流水号/现金签收依据'), '000001 原回单');
      await tester.enterText(
        financeTextField('实际付款时间（含 +08:00 时区）'),
        '2026-09-30T16:12:13+08:00',
      );
      await tester.tap(find.text('登记实际付款').last);
      await tester.pumpAndSettle();
      expect(api.requests, hasLength(1));
      final state =
          tester.state(find.byType(FinanceApplicationActionSurface))
              as FormDraftMixin<FinanceApplicationActionSurface>;
      await state.saveFormDraftNow();
      final draft = first.read(formDraftsProvider).single;
      await tester.pumpWidget(const SizedBox());
      first.dispose();
      final second = await _mount(tester, api, storage, resume: draft.id);
      expect(
        tester.widget<TextField>(financeTextField('账户实际扣款原币')).enabled,
        isFalse,
      );
      await tester.tap(find.text('重试原请求'));
      await tester.pumpAndSettle();
      expect(api.requests, hasLength(2));
      expect(
        tester.widget<TextField>(financeTextField('账户实际扣款原币')).enabled,
        isFalse,
      );
      expect(jsonEncode(api.requests[0]), jsonEncode(api.requests[1]));
      expect(api.requests.first['bankAmount'], '100.1234');
      expect(api.requests.first['bankReference'], '000001 原回单');
      expect(api.requests.first['accountId'], 'bank');
      await tester.tap(find.text('重试原请求'));
      await tester.pumpAndSettle();
      expect(api.requests, hasLength(3));
      expect(jsonEncode(api.requests.first), jsonEncode(api.requests.last));
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      second.dispose();
    },
  );
  testWidgets(
    'actual payment controls remain reachable in narrow enlarged text',
    (tester) async {
      final container = await _mount(
        tester,
        _Api(),
        MemoryFormDraftStorage(),
        width: 390,
        scale: 1.5,
      );
      expect(find.text('登记实际付款'), findsWidgets);
      expect(tester.takeException(), isNull);
      if (const bool.fromEnvironment('UTEN_CAPTURE_FINANCE')) {
        final boundary = tester.renderObject<RenderRepaintBoundary>(
          find.byKey(const ValueKey('finance-action-capture')),
        );
        await tester.runAsync(() async {
          final image = await boundary.toImage();
          final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
          {
            final file = File(
              'output/finance-applications/screenshots/申请实际付款-窄屏-匿名测试.png',
            );
            await file.parent.create(recursive: true);
            await file.writeAsBytes(bytes!.buffer.asUint8List());
          }
          image.dispose();
        });
      }
      await tester.pumpWidget(const SizedBox());
      container.dispose();
    },
  );
}

Future<void> _select(WidgetTester tester, String label, String value) async {
  final field = find.byWidgetPredicate(
    (w) => w is UtenDropdownField && w.label == label,
  );
  await tester.ensureVisible(field);
  await tester.tap(field);
  await tester.pumpAndSettle();
  await tester.tap(find.text(value).last);
  await tester.pumpAndSettle();
}

Future<ProviderContainer> _mount(
  WidgetTester tester,
  _Api api,
  MemoryFormDraftStorage storage, {
  String? resume,
  double width = 1200,
  double scale = 1,
}) async {
  if (const bool.fromEnvironment('UTEN_CAPTURE_FINANCE')) {
    await loadAuditScreenshotFonts(tester);
  }
  await tester.binding.setSurfaceSize(Size(width, 900));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  SharedPreferences.setMockInitialValues({});
  final prefs = await SharedPreferences.getInstance();
  final container = ProviderContainer(
    overrides: [
      apiClientProvider.overrideWithValue(api),
      apiBaseUrlProvider.overrideWithValue('https://finance-draft.test/api'),
      sessionProvider.overrideWith(_Session.new),
      authenticatedScopeProvider.overrideWithValue(
        const AuthenticatedScope(userId: 'finance-operator'),
      ),
      currentPermissionsProvider.overrideWithValue({
        Perm.financeApplicationView,
        Perm.financeApplicationExecute,
      }),
      sharedPreferencesProvider.overrideWithValue(prefs),
      formDraftStorageProvider.overrideWithValue(storage),
    ],
  );
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: auditScreenshotTheme(buildLightTheme()),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: TextScaler.linear(scale)),
          child: child!,
        ),
        home: Scaffold(
          body: RepaintBoundary(
            key: const ValueKey('finance-action-capture'),
            child: Material(
              color: buildLightTheme().scaffoldBackgroundColor,
              child: FinanceApplicationActionSurface(
                application: _app,
                mode: 'execute',
                resumeDraftId: resume,
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return container;
}

class _Session extends SessionNotifier {
  @override
  SessionState build() => const SessionState();
}

class _Api extends ApiClient {
  _Api() : super(Dio());
  final requests = <Map<String, dynamic>>[];
  Completer<void>? gate;
  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    if (path.endsWith('/references')) {
      return {
        'accounts': [
          {'id': 'bank', 'code': 'TEST', 'name': '匿名银行'},
        ],
        'currencies': [
          {'id': 'base', 'baseCurrency': true},
        ],
      };
    }
    if (path.endsWith('/accounting-expense-styles')) {
      return {
        'items': [
          {'id': 'expense', 'code': 'TEST-E', 'name': '原费用科目'},
        ],
      };
    }
    return _app;
  }

  @override
  Future<Map<String, dynamic>> post(
    String path, {
    Object? body,
    Map<String, dynamic>? headers,
    Map<String, dynamic>? query,
  }) async {
    requests.add(jsonDecode(jsonEncode(body)) as Map<String, dynamic>);
    if (gate != null) {
      await gate!.future;
    }
    if (requests.length == 1) {
      throw NetworkTimeoutException();
    }
    if (requests.length == 2) {
      throw ApiException(
        'FORBIDDEN',
        '当前办理资格已变化',
        httpStatus: 403,
        hasResponseCode: true,
      );
    }
    return {'status': 'EXECUTED'};
  }
}
