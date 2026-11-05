import 'dart:async';

import 'package:uten_imp/components/buttons/uten_close_button.dart';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/theme/light_theme.dart';
import 'package:uten_imp/features/finance/widgets/gl_report_line_bindings_dialog.dart';
import '../../support/audit_screenshot_support.dart';
import '../../support/finance_command_test_support.dart';

/// ADR-112 / overhaul-gap-03: 附表取数设置——未配置的行明确标注, 选费用末级科目后整行保存,
/// 「按默认名单补齐」调用服务端同一个库函数。
void main() {
  setUp(prepareFinanceCommandTest);
  for (final layout in [(1280.0, 1.0), (390.0, 1.5)]) {
    testWidgets(
      'actual settings panel keeps aligned actions and usable nested picker at ${layout.$1}',
      (tester) async {
        const capture = bool.fromEnvironment('UTEN_CAPTURE_FINANCE_DIALOGS');
        tester.view.physicalSize = Size(layout.$1, 900);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        if (capture) await loadAuditScreenshotFonts(tester);
        final boundary = GlobalKey();
        final api = _Api();
        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              apiClientProvider.overrideWithValue(api),
              ...financeCommandTestOverrides(),
            ],
            child: MaterialApp(
              theme: capture
                  ? auditScreenshotTheme(buildLightTheme())
                  : buildLightTheme(),
              builder: (context, child) => RepaintBoundary(
                key: boundary,
                child: MediaQuery(
                  data: MediaQuery.of(
                    context,
                  ).copyWith(textScaler: TextScaler.linear(layout.$2)),
                  child: child!,
                ),
              ),
              home: Scaffold(
                body: Builder(
                  builder: (context) => TextButton(
                    onPressed: () =>
                        showGlReportLineBindingsDialog(context, canEdit: true),
                    child: const Text('打开设置'),
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.tap(find.text('打开设置'));
        await tester.pumpAndSettle();
        expect(find.text('厂房及成品仓租赁费'), findsOneWidget);
        expect(find.text('按默认名单补齐').hitTestable(), findsOneWidget);
        expect(tester.getSize(find.text('附表取数设置')).height, lessThan(60));
        if (capture) {
          await saveAuditScreenshot(
            tester,
            boundary,
            'finance-settings-panel-${layout.$1.toInt()}',
          );
        }
        await tester.tap(find.byKey(const ValueKey('gl-line-edit-ADM_OFFICE')));
        await tester.pumpAndSettle();
        expect(
          find.byKey(const ValueKey('gl-line-target-save')).hitTestable(),
          findsOneWidget,
        );
        if (capture) {
          await saveAuditScreenshot(
            tester,
            boundary,
            'finance-settings-picker-${layout.$1.toInt()}',
          );
        }
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      },
    );
  }
  testWidgets(
    'statement categories and explicit zero confirmation are sent to the server',
    (tester) async {
      final api = _Api();
      api.lines = [
        {
          'lineKey': 'BS_2',
          'label': '短期投资',
          'bindingKind': 'STYLE',
          'stateFingerprint': 'original-state-v7',
          'category': 'ACCOUNT',
          'sheet': 'BALANCE',
          'targets': <Object>[],
        },
      ];
      await tester.binding.setSurfaceSize(const Size(1400, 1000));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            apiClientProvider.overrideWithValue(api),
            ...financeCommandTestOverrides(),
          ],
          child: const MaterialApp(
            home: GlReportLineBindingsDialog(canEdit: true),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('gl-line-edit-BS_2')));
      await tester.pumpAndSettle();
      expect(api.lastQuery, {'category': 'ACCOUNT'});
      await tester.tap(
        find.descendant(
          of: find.byKey(const ValueKey('gl-line-confirm-zero')),
          matching: find.byType(Checkbox),
        ),
      );
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('gl-line-target-save')));
      await tester.pumpAndSettle();
      expect(api.putPath, '/finance/reports/gl/line-bindings/BS_2');
      expect(api.putBody, containsPair('targetIds', <String>[]));
      expect(api.putBody, containsPair('confirmedZero', true));
      expect(
        api.putBody,
        containsPair('expectedFingerprint', 'original-state-v7'),
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'lists unconfigured rows, saves the picked leaf and seeds defaults',
    (tester) async {
      final api = _Api();
      tester.view.physicalSize = const Size(1400, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      bool? changed;
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            apiClientProvider.overrideWithValue(api),
            ...financeCommandTestOverrides(),
          ],
          child: MaterialApp(
            home: Builder(
              builder: (context) => Scaffold(
                body: TextButton(
                  onPressed: () async {
                    changed = await showGlReportLineBindingsDialog(
                      context,
                      canEdit: true,
                    );
                  },
                  child: const Text('open'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      expect(find.text('未配置科目'), findsOneWidget);
      expect(find.text('未配置部门'), findsOneWidget);
      expect(find.text('房租 (6601)'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('gl-line-edit-ADM_OFFICE')));
      await tester.pumpAndSettle();
      expect(api.lastQuery, {'category': 'EXPENSE'});
      // 只列末级科目; 目录「管理费用」不出现, 停用的末级标注后可选。
      expect(find.textContaining('管理费用 / 办公费用 (6602)'), findsOneWidget);
      expect(find.textContaining('旧办公费 (6603) (停用)'), findsOneWidget);
      await tester.tap(
        find.byKey(const ValueKey('gl-line-target-style-office')),
      );
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('gl-line-target-save')));
      await tester.pumpAndSettle();
      expect(api.putPath, '/finance/reports/gl/line-bindings/ADM_OFFICE');
      expect(api.putBody, containsPair('targetIds', ['style-office']));
      expect(find.text('办公费用 (6602)'), findsOneWidget);

      final seed = tester
          .widget<OutlinedButton>(
            find.byKey(const ValueKey('gl-line-seed-defaults')),
          )
          .onPressed!;
      seed();
      seed();
      await tester.pumpAndSettle();
      expect(api.postPath, '/finance/reports/gl/line-bindings/defaults');
      expect(api.postCalls, 1);

      await tester.tap(find.byType(UtenCloseButton).last);
      await tester.pumpAndSettle();
      expect(changed, isTrue);
    },
  );

  testWidgets(
    'target search requires parent name and code together while preserving disabled historical leaves',
    (tester) async {
      final api = _Api();
      await tester.binding.setSurfaceSize(const Size(1400, 1000));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            apiClientProvider.overrideWithValue(api),
            ...financeCommandTestOverrides(),
          ],
          child: const MaterialApp(
            home: GlReportLineBindingsDialog(canEdit: true),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('gl-line-edit-ADM_OFFICE')));
      await tester.pumpAndSettle();
      final search = find.descendant(
        of: find.byKey(const ValueKey('gl-line-target-search')),
        matching: find.byType(TextField),
      );
      await tester.enterText(search, '管理费用 6603');
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('gl-line-target-style-old')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('gl-line-target-style-office')),
        findsNothing,
      );
      await tester.tap(find.byKey(const ValueKey('gl-line-target-style-old')));
      await tester.tap(find.byKey(const ValueKey('gl-line-target-save')));
      await tester.pumpAndSettle();
      expect(api.putBody, containsPair('targetIds', ['style-old']));
    },
  );

  testWidgets(
    'one picker owns the edit and pending save cannot be closed by old controls or system back',
    (tester) async {
      tester.view.physicalSize = const Size(1280, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final api = _Api()..putGate = Completer<void>();
      bool? changed;
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            apiClientProvider.overrideWithValue(api),
            ...financeCommandTestOverrides(),
          ],
          child: MaterialApp(
            home: Scaffold(
              body: Builder(
                builder: (context) => TextButton(
                  onPressed: () async {
                    changed = await showGlReportLineBindingsDialog(
                      context,
                      canEdit: true,
                    );
                  },
                  child: const Text('打开设置'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('打开设置'));
      await tester.pumpAndSettle();
      final close = tester
          .widget<UtenCloseButton>(find.byType(UtenCloseButton))
          .onPressed!;
      final edit = tester
          .widget<TextButton>(
            find.byKey(const ValueKey('gl-line-edit-ADM_OFFICE')),
          )
          .onPressed!;
      final seed = tester
          .widget<OutlinedButton>(
            find.byKey(const ValueKey('gl-line-seed-defaults')),
          )
          .onPressed!;
      edit();
      await tester.pumpAndSettle();
      edit();
      seed();
      await tester.pumpAndSettle();
      expect(api.candidateReads, 1);
      expect(api.postCalls, 0);
      expect(find.byKey(const ValueKey('gl-line-target-save')), findsOneWidget);
      await tester.tap(
        find.byKey(const ValueKey('gl-line-target-style-office')),
      );
      await tester.tap(find.byKey(const ValueKey('gl-line-target-save')));
      await tester.pump();
      await tester.pump();
      expect(api.putPath, '/finance/reports/gl/line-bindings/ADM_OFFICE');
      close();
      await tester.binding.handlePopRoute();
      await tester.pump();
      expect(changed, isNull);
      expect(find.byType(GlReportLineBindingsDialog), findsOneWidget);
      expect(
        tester.widget<UtenCloseButton>(find.byType(UtenCloseButton)).onPressed,
        isNull,
      );
      api.putGate!.complete();
      await tester.pumpAndSettle();
      expect(find.text('办公费用 (6602)'), findsOneWidget);
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(changed, isTrue);
      expect(find.byType(GlReportLineBindingsDialog), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  test('department tree flattens every level with indentation depth', () {
    final flat = flattenDepartments([
      {
        'id': 'd1',
        'code': 'D1',
        'name': '生产部',
        'children': [
          {'id': 'd2', 'code': 'D2', 'name': '注塑车间', 'children': <Object>[]},
        ],
      },
    ]);
    expect(flat.map((item) => item.label), ['生产部 (D1)', '注塑车间 (D2)']);
    expect(flat.map((item) => item.depth), [0, 1]);
  });
}

class _Api extends ApiClient {
  _Api() : super(Dio());

  List<Map<String, dynamic>> lines = [
    {
      'lineKey': 'ADM_RENT',
      'label': '厂房及成品仓租赁费',
      'bindingKind': 'STYLE',
      'stateFingerprint': 'original-state-v7',
      'targets': [
        {'id': 'style-rent', 'code': '6601', 'name': '房租'},
      ],
    },
    {
      'lineKey': 'ADM_OFFICE',
      'label': '办公费',
      'bindingKind': 'STYLE',
      'stateFingerprint': 'original-state-v7',
      'targets': <Object>[],
    },
    {
      'lineKey': 'LABOR_DIRECT',
      'label': '直接人工',
      'bindingKind': 'DEPARTMENT',
      'stateFingerprint': 'original-state-v7',
      'targets': <Object>[],
    },
  ];
  Map<String, dynamic>? lastQuery;
  String? putPath;
  Object? putBody;
  String? postPath;
  int postCalls = 0;
  int candidateReads = 0;
  Completer<void>? putGate;

  @override
  Future<List<Map<String, dynamic>>> getList(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    if (path == '/finance/reports/gl/line-bindings') return lines;
    candidateReads++;
    lastQuery = query;
    return [
      {
        'id': 'style-admin',
        'code': '66',
        'name': '管理费用',
        'category': 'EXPENSE',
        'status': '使用',
        'children': [
          {
            'id': 'style-office',
            'code': '6602',
            'name': '办公费用',
            'category': 'EXPENSE',
            'status': '使用',
            'children': <Object>[],
          },
          {
            'id': 'style-old',
            'code': '6603',
            'name': '旧办公费',
            'category': 'EXPENSE',
            'status': '禁用',
            'children': <Object>[],
          },
        ],
      },
    ];
  }

  @override
  Future<Map<String, dynamic>> put(String path, {Object? body}) async {
    putPath = path;
    putBody = body;
    if (putGate != null) await putGate!.future;
    final saved = <String, dynamic>{
      'lineKey': 'ADM_OFFICE',
      'label': '办公费',
      'bindingKind': 'STYLE',
      'stateFingerprint': 'original-state-v7',
      'targets': [
        {'id': 'style-office', 'code': '6602', 'name': '办公费用'},
      ],
    };
    lines = [
      for (final line in lines)
        line['lineKey'] == path.split('/').last ? saved : line,
    ];
    return financeCommandTestReceipt(
      operation: 'GL_REPORT_BINDING_REPLACE',
      method: 'PUT',
      path: path,
      body: body,
      result: saved,
    );
  }

  @override
  Future<Map<String, dynamic>> post(
    String path, {
    Object? body,
    Map<String, dynamic>? headers,
    Map<String, dynamic>? query,
    bool preserveUnauthorizedSession = false,
  }) async {
    postPath = path;
    postCalls++;
    return financeCommandTestReceipt(
      operation: 'GL_REPORT_BINDINGS_SEED',
      method: 'POST',
      path: path,
      body: body,
      result: lines,
    );
  }
}
