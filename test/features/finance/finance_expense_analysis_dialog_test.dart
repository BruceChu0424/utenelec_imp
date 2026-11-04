import 'dart:convert';
import 'dart:async';
import 'dart:typed_data';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/components/inputs/uten_input.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/network/api_exception.dart';
import 'package:uten_imp/core/network/server_config.dart';
import 'package:uten_imp/features/finance/widgets/finance_expense_analysis_dialog.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/drafts/form_draft_mixin.dart';
import 'package:uten_imp/shared/drafts/form_draft_store.dart';
import 'package:uten_imp/shared/providers/authenticated_scope_provider.dart';
import 'package:uten_imp/shared/providers/session_provider.dart';
import 'package:uten_imp/shared/providers/shared_providers.dart';
import '../../shared/drafts/memory_form_draft_storage.dart';

void main() {
  testWidgets(
    'rapid repeated save sends one request while original operation is pending',
    (tester) async {
      final api = _ExpenseApi()..saveGate = Completer<void>();
      final container = await _mount(tester, api, MemoryFormDraftStorage());
      tester
              .widgetList<UtenInput>(find.byType(UtenInput))
              .first
              .controller!
              .text =
          '连续保存';
      await tester.pump();
      final target = find.text('保存');
      for (int i = 0; i < 20; i++) {
        await tester.tap(target);
      }
      await tester.pump();
      expect(api.saved, hasLength(1));
      api.saveGate!.complete();
      await tester.pumpAndSettle();
      expect(api.commits, 1);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      container.dispose();
    },
  );
  testWidgets(
    'raw note draft survives hard close and restores stable period/project/version',
    (tester) async {
      final storage = MemoryFormDraftStorage(), api = _ExpenseApi();
      final first = await _mount(tester, api, storage);
      final inputs = tester
          .widgetList<UtenInput>(find.byType(UtenInput))
          .toList();
      inputs.first.controller!.text = '原始备注\n保留换行';
      inputs.last.controller!.text = '差异 12.';
      await tester.pump();
      final editor =
          tester.state(find.byType(FinanceExpenseAnalysisSurface))
              as FormDraftMixin<FinanceExpenseAnalysisSurface>;
      await editor.saveFormDraftNow();
      final draft = first.read(formDraftsProvider).single;
      expect(draft.data['version'], 7);
      expect(api.saved, isEmpty);
      await tester.pumpWidget(const SizedBox());
      first.dispose();
      final second = await _mount(tester, api, storage, resume: draft.id);
      final restored = tester
          .widgetList<UtenInput>(find.byType(UtenInput))
          .toList();
      expect(restored.first.controller!.text, '原始备注\n保留换行');
      expect(restored.last.controller!.text, '差异 12.');
      expect(api.saved, isEmpty);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      second.dispose();
    },
  );
  testWidgets(
    'lost note reply freezes edits and retries identical versioned command without duplication',
    (tester) async {
      final api = _ExpenseApi()..loseFirst = true;
      final container = await _mount(tester, api, MemoryFormDraftStorage());
      tester
              .widgetList<UtenInput>(find.byType(UtenInput))
              .first
              .controller!
              .text =
          '原备注';
      await tester.pump();
      await tester.tap(find.text('保存'));
      await tester.pumpAndSettle();
      expect(api.saved, hasLength(1));
      expect(
        tester
            .widgetList<UtenInput>(find.byType(UtenInput))
            .every((i) => !i.enabled),
        isTrue,
      );
      expect(find.text('重试原请求'), findsOneWidget);
      await tester.tap(find.text('重试原请求'));
      await tester.pumpAndSettle();
      expect(api.saved, hasLength(2));
      expect(jsonEncode(api.saved[0]), jsonEncode(api.saved[1]));
      expect(api.commits, 1);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      container.dispose();
    },
  );
  testWidgets(
    'narrow enlarged note remains scrollable without losing original captions',
    (tester) async {
      final container = await _mount(
        tester,
        _ExpenseApi(),
        MemoryFormDraftStorage(),
        width: 390,
        scale: 1.5,
      );
      expect(find.text('原分类 / 原分项 / 原项目'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      container.dispose();
    },
  );
}

Future<ProviderContainer> _mount(
  WidgetTester tester,
  _ExpenseApi api,
  MemoryFormDraftStorage storage, {
  String? resume,
  double width = 1200,
  double scale = 1,
}) async {
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
        Perm.financeReportView,
        Perm.financeViewAll,
        Perm.paymentStyleEdit,
      }),
      sharedPreferencesProvider.overrideWithValue(prefs),
      formDraftStorageProvider.overrideWithValue(storage),
    ],
  );
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: TextScaler.linear(scale)),
          child: child!,
        ),
        home: Scaffold(
          body: FinanceExpenseAnalysisSurface(
            mode: 'note',
            scope: const {'period': '2026-09', 'lineKey': 'OP_RENT'},
            resumeDraftId: resume,
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

class _ExpenseApi extends ApiClient {
  _ExpenseApi() : super(Dio());
  bool loseFirst = false;
  int commits = 0;
  final saved = <Map<String, dynamic>>[];
  Completer<void>? saveGate;
  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, dynamic>? query,
  }) async => {
    'items': [
      {
        'lineKey': 'OP_RENT',
        'category': '原分类',
        'sub': '原分项',
        'item': '原项目',
        'remark': '',
        'varianceReason': '',
        'version': 7,
      },
    ],
  };
  @override
  Future<Map<String, dynamic>> post(
    String path, {
    Object? body,
    Map<String, dynamic>? headers,
    Map<String, dynamic>? query,
  }) async {
    saved.add(Map<String, dynamic>.from(body as Map));
    if (saveGate != null) await saveGate!.future;
    commits = 1;
    if (loseFirst && saved.length == 1) throw NetworkTimeoutException();
    return {'items': <Object>[]};
  }

  @override
  Future<Map<String, dynamic>> postBytes(
    String path,
    Uint8List bytes, {
    Map<String, dynamic>? query,
    Map<String, String>? headers,
    Duration? sendTimeout,
    Duration? receiveTimeout,
  }) async => {};
}
