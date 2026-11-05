import 'dart:async';
import 'dart:typed_data';

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
import 'package:uten_imp/features/finance/widgets/finance_entry_file_picker.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/providers/authenticated_scope_provider.dart';

import '../../support/audit_screenshot_support.dart';

void main() {
  for (final layout in [(1280.0, 1.0), (390.0, 1.5)]) {
    testWidgets(
      'actual chart launcher fills its panel without another dialog card and keeps keyboard/search/result at ${layout.$1}',
      (tester) async {
        const capture = bool.fromEnvironment('UTEN_CAPTURE_FINANCE_DIALOGS');
        if (capture) await loadAuditScreenshotFonts(tester);
        final state = await _mount(
          tester,
          _Api(),
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
        state.container.dispose();
      },
    );
  }

  testWidgets(
    'chart launcher cannot close through a captured callback while import is pending and returns the original changed result',
    (tester) async {
      final api = _Api()..applyGate = Completer<void>();
      final state = await _mount(tester, api);
      await tester.tap(find.text('报表中的科目管理'));
      await tester.pumpAndSettle();
      if (find.text('导入科目目录').evaluate().isEmpty) {
        await tester.tap(find.byTooltip('表格操作'));
        await tester.pumpAndSettle();
      }
      await tester.tap(find.text('导入科目目录'));
      await tester.pumpAndSettle();
      final close = tester
          .widget<UtenButton>(find.widgetWithText(UtenButton, '关闭'))
          .onPressed!;
      final apply = tester
          .widget<UtenButton>(find.widgetWithText(UtenButton, '确认导入科目目录'))
          .onPressed!;
      apply();
      apply();
      close();
      await tester.pump();
      await tester.pump();
      expect(api.applies, 1);
      expect(find.byType(FinanceChartDialog), findsOneWidget);
      expect(find.byType(UtenBusyOverlayCard), findsOneWidget);
      expect(state.result, isNull);
      api.applyGate!.complete();
      await tester.pumpAndSettle();
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(state.result, isTrue);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      state.container.dispose();
    },
  );
}

class _State {
  _State(this.container);
  final ProviderContainer container;
  final boundary = GlobalKey();
  bool? result;
}

Future<_State> _mount(
  WidgetTester tester,
  _Api api, {
  double width = 1280,
  double scale = 1,
}) async {
  const capture = bool.fromEnvironment('UTEN_CAPTURE_FINANCE_DIALOGS');
  tester.view.physicalSize = Size(width, 900);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final container = ProviderContainer(
    overrides: [
      apiClientProvider.overrideWithValue(api),
      authenticatedScopeProvider.overrideWithValue(
        const AuthenticatedScope(userId: 'chart-launcher-owner'),
      ),
      currentPermissionsProvider.overrideWithValue({
        Perm.paymentStyleEdit,
        Perm.paymentStyleCreate,
      }),
      financeEntryFilePickerProvider.overrideWithValue(
        () async => PlatformFile(
          name: 'chart.xlsx',
          size: 3,
          bytes: Uint8List.fromList([1, 2, 3]),
        ),
      ),
    ],
  );
  final state = _State(container);
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

class _Api extends ApiClient {
  _Api() : super(Dio());
  Completer<void>? applyGate;
  int applies = 0;
  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, dynamic>? query,
  }) async => path == '/finance/chart'
      ? {
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
        }
      : path == '/finance/chart/options'
      ? {'currencies': <Object>[]}
      : {'items': <Object>[]};
  @override
  Future<Map<String, dynamic>> postMultipartFile(
    String path,
    Uint8List bytes,
    String filename,
    String contentType, {
    Duration? receiveTimeout,
    Map<String, Object?> jsonParts = const {},
    Map<String, dynamic>? headers,
  }) async => {
    'importId': 'chart-batch',
    'sourceName': filename,
    'rows': [
      {'code': '1001', 'name': '库存现金'},
    ],
    'issues': <Object>[],
    'applied': false,
  };
  @override
  Future<Map<String, dynamic>> post(
    String path, {
    Object? body,
    Map<String, dynamic>? headers,
    Map<String, dynamic>? query,
  }) async {
    applies++;
    if (applyGate != null) await applyGate!.future;
    return {'status': 'APPLIED', 'imported': 1};
  }
}
