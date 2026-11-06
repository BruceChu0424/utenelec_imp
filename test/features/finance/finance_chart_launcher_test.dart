import 'dart:async';

import 'package:dio/dio.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/components/buttons/uten_button.dart';
import 'package:uten_imp/components/feedback/uten_busy_overlay.dart';
import 'package:uten_imp/components/feedback/uten_dialog.dart';
import 'package:uten_imp/components/inputs/uten_search_bar.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/theme/light_theme.dart';
import 'package:uten_imp/features/finance/widgets/finance_chart_dialog.dart';
import 'package:uten_imp/features/finance/widgets/finance_chart_import_workbench.dart';
import 'package:uten_imp/features/finance/widgets/finance_entry_file_picker.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/providers/authenticated_scope_provider.dart';
import 'package:uten_imp/shared/providers/session_provider.dart';
import 'package:uten_imp/shared/providers/shared_providers.dart';
import 'package:uten_imp/shared/drafts/form_draft_store.dart';
import 'package:uten_imp/core/network/server_config.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../support/audit_screenshot_support.dart';
import '../../support/finance_chart_import_test_support.dart';
import '../../support/finance_command_test_support.dart';
import '../../support/pump_until.dart';
import '../../shared/drafts/memory_form_draft_storage.dart';

void main() {
  setUp(prepareFinanceCommandTest);
  for (final layout in [(1280.0, 1.0), (390.0, 1.5)]) {
    testWidgets(
      'actual chart launcher fills its panel without another dialog card and keeps keyboard/search/result at ${layout.$1}',
      (tester) async {
        const capture = bool.fromEnvironment('UTEN_CAPTURE_FINANCE_DIALOGS');
        if (capture) await loadAuditScreenshotFonts(tester);
        final state = await _mount(
          tester,
          _transport(),
          width: layout.$1,
          scale: layout.$2,
        );
        await tester.tap(find.text('报表中的科目管理'));
        await tester.pumpAndSettle();
        expect(find.byType(AlertDialog), findsNothing);
        expect(find.byType(Dialog), findsNothing);
        final panel = tester.getRect(find.byType(FinanceChartDialog));
        expect(panel.right, layout.$1);
        expect(panel.height, greaterThan(800));
        expect(panel.left, layout.$1 == 1280 ? 320 : 0);
        if (capture) {
          await saveAuditScreenshot(
            tester,
            state.boundary,
            'finance-chart-panel-${layout.$1.toInt()}',
          );
        }
        tester.view.viewInsets = const FakeViewPadding(bottom: 300);
        await tester.pumpAndSettle();
        final search = find.descendant(
          of: find.byType(UtenSearchBar),
          matching: find.byType(TextField),
        );
        await tester.ensureVisible(search);
        expect(search.hitTestable(), findsOneWidget);
        await tester.enterText(search, '库存');
        await tester.pump(const Duration(milliseconds: 350));
        await tester.pumpAndSettle();
        expect(find.text('库存现金'), findsOneWidget);
        expect(
          tester.getRect(find.byType(UtenDialogActions).first).bottom,
          lessThanOrEqualTo(600),
        );
        expect(find.text('关闭').hitTestable(), findsOneWidget);
        if (capture && layout.$1 == 390) {
          await saveAuditScreenshot(
            tester,
            state.boundary,
            'finance-chart-panel-390-keyboard',
          );
        }
        await tester.tap(find.text('关闭'));
        await tester.pumpAndSettle();
        expect(state.result, isFalse);
        expect(find.byType(FinanceChartDialog), findsNothing);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
        state.dispose();
      },
    );
  }

  testWidgets(
    'chart launcher cannot close through a captured callback while import is pending and returns the original changed result',
    (tester) async {
      final api = _transport()..holdApply = Completer<void>();
      final state = await _mount(tester, api);
      await tester.tap(find.text('报表中的科目管理'));
      await tester.pumpAndSettle();
      final close = tester
          .widget<UtenButton>(
            find.descendant(
              of: find.byType(FinanceChartDialog),
              matching: find.widgetWithText(UtenButton, '关闭'),
            ),
          )
          .onPressed!;
      if (find.text('导入科目目录').evaluate().isEmpty) {
        await tester.tap(find.byTooltip('表格操作'));
        await tester.pumpAndSettle();
      }
      await tester.tap(find.text('导入科目目录'));
      await tester.pumpAndSettle();
      final closeImport = tester
          .widget<UtenButton>(
            find.descendant(
              of: find.byType(FinanceChartImportWorkbench),
              matching: find.widgetWithText(UtenButton, '关闭'),
            ),
          )
          .onPressed!;
      final apply = tester
          .widget<UtenButton>(find.widgetWithText(UtenButton, '确认导入科目目录'))
          .onPressed!;
      apply();
      apply();
      close();
      closeImport();
      await pumpUntil(
        tester,
        () =>
            api.applyCalls.length == 1 &&
            find.byType(UtenBusyOverlayCard).evaluate().isNotEmpty,
        reason:
            'The original apply must dispatch once after its durable draft and actual waiting card are ready',
      );
      expect(api.applyCalls, hasLength(1));
      expect(api.applyCalls.single.body, {
        'importId': financeChartImportTestRoot,
      });
      expect(api.applied, 0);
      expect(find.byType(FinanceChartDialog), findsOneWidget);
      expect(find.byType(UtenBusyOverlayCard), findsOneWidget);
      expect(state.result, isNull);
      api.holdApply!.complete();
      await tester.pumpAndSettle();
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(state.result, isTrue);
      expect(api.applied, 1);
      expect(api.applyCalls, hasLength(1));
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      state.dispose();
    },
  );
}

class _State {
  _State(this.container, this.dio);
  final ProviderContainer container;
  final Dio dio;
  final boundary = GlobalKey();
  bool? result;
  bool _disposed = false;
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    container.dispose();
    dio.close(force: true);
  }
}

Future<_State> _mount(
  WidgetTester tester,
  FinanceChartImportTestTransport api, {
  double width = 1280,
  double scale = 1,
}) async {
  const capture = bool.fromEnvironment('UTEN_CAPTURE_FINANCE_DIALOGS');
  tester.view.physicalSize = Size(width, 900);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final dio = Dio(BaseOptions(baseUrl: 'https://finance-command.test/api'))
    ..httpClientAdapter = api;
  final container = ProviderContainer(
    overrides: [
      apiClientProvider.overrideWithValue(ApiClient(dio)),
      apiBaseUrlProvider.overrideWithValue('https://finance-command.test/api'),
      sessionProvider.overrideWith(FinanceChartImportTestSession.new),
      formDraftStorageProvider.overrideWithValue(MemoryFormDraftStorage()),
      sharedPreferencesProvider.overrideWithValue(
        await SharedPreferences.getInstance(),
      ),
      authenticatedScopeProvider.overrideWithValue(
        const AuthenticatedScope(userId: financeCommandTestActor),
      ),
      currentPermissionsProvider.overrideWithValue({
        Perm.paymentStyleEdit,
        Perm.paymentStyleCreate,
        Perm.financeReportView,
        Perm.financeViewAll,
      }),
      financeEntryFilePickerProvider.overrideWithValue(
        () async => PlatformFile(
          name: 'chart.xlsx',
          size: financeChartImportTestBytes.length,
          bytes: financeChartImportTestBytes,
        ),
      ),
    ],
  );
  final state = _State(container, dio);
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox.shrink());
    if (api.holdApply != null && !api.holdApply!.isCompleted) {
      api.holdApply!.complete();
    }
    state.dispose();
  });
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: capture
            ? auditScreenshotTheme(buildLightTheme())
            : buildLightTheme(),
        builder: (context, child) => RepaintBoundary(
          key: state.boundary,
          child: MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: TextScaler.linear(scale)),
            child: child!,
          ),
        ),
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () async {
                state.result = await showFinanceChartDialog(
                  context,
                  canEdit: true,
                );
              },
              child: const Text('报表中的科目管理'),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return state;
}

FinanceChartImportTestTransport _transport() =>
    FinanceChartImportTestTransport()
      ..loseApply = false
      ..rootVersion = 0
      ..readExtra = (path) => switch (path) {
        '/finance/chart' => {
          'items': [
            {
              'code': '1001',
              'name': '库存现金',
              'classification': 'ASSET',
              'version': 0,
              'targets': <Object>[],
              'lineKeys': <Object>[],
            },
          ],
        },
        '/finance/chart/options' => {'currencies': <Object>[]},
        _ => null,
      };
