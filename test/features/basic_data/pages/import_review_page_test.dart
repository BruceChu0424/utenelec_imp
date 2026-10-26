import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/components/buttons/uten_button.dart';
import 'package:uten_imp/components/layout/uten_floating_action_group.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/core/theme/dark_theme.dart';
import 'package:uten_imp/core/theme/light_theme.dart';
import 'package:uten_imp/features/basic_data/pages/import_review_page.dart';
import 'package:uten_imp/features/basic_data/widgets/master_data_table_view.dart';

import '../../../support/audit_screenshot_support.dart';

const _capture = bool.fromEnvironment('UTEN_IMPORT_REVIEW_SCREENSHOT');
final _captureKey = GlobalKey();

const _rows = [
  ImportReviewRow(
    rowKey: 'changed',
    sourceRow: 2,
    identityLabel: 'A001 / 机壳',
    matchReason: '编号匹配',
    cells: [
      ImportReviewCell(
        key: 'clientModel',
        label: '客户型号',
        before: '111',
        after: '222',
      ),
      ImportReviewCell(key: 'spec', label: '规格', before: 'M8', after: 'M8'),
    ],
  ),
  ImportReviewRow(
    rowKey: 'fill',
    sourceRow: 3,
    identityLabel: 'A002 / 螺丝',
    matchReason: '编号匹配',
    selectable: false,
    cells: [ImportReviewCell(key: 'clientModel', label: '客户型号', after: '333')],
  ),
  ImportReviewRow(
    rowKey: 'other',
    sourceRow: 4,
    identityLabel: 'A003 / 底座',
    matchReason: '同分类同名称',
    cells: [
      ImportReviewCell(
        key: 'clientModel',
        label: '客户型号',
        before: '444',
        after: '555',
      ),
    ],
  ),
];

class _Result {
  bool completed = false;
  Set<String>? value;
}

Future<void> _open(
  WidgetTester tester,
  _Result result, {
  List<ImportReviewRow> rows = _rows,
  Size size = const Size(1440, 900),
  double textScale = 1,
  bool dark = false,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  if (_capture) await loadAuditScreenshotFonts(tester);
  final theme = dark ? buildDarkTheme() : buildLightTheme();
  await tester.pumpWidget(
    MaterialApp(
      theme: _capture ? auditScreenshotTheme(theme) : theme,
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      locale: const Locale('zh'),
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(
          context,
        ).copyWith(textScaler: TextScaler.linear(textScale)),
        child: RepaintBoundary(key: _captureKey, child: child!),
      ),
      home: Scaffold(
        body: Builder(
          builder: (context) => TextButton(
            onPressed: () async {
              result.value = await showImportReviewPage(
                context,
                title: '核对货品导入差异',
                rows: rows,
                description: '新增 1，补齐 1，冲突 2，相同 1。空白不覆盖已有值。',
              );
              result.completed = true;
            },
            child: const Text('打开'),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('打开'));
  await tester.pumpAndSettle();
}

MasterDataTableView<ImportReviewRow> _table(WidgetTester tester) =>
    tester.widget<MasterDataTableView<ImportReviewRow>>(
      find.byKey(const ValueKey('import-review-table')),
    );

void main() {
  testWidgets('shows inline old/new values and starts with zero replacements', (
    tester,
  ) async {
    await _open(tester, _Result());

    expect(find.byType(UtenFloatingActionGroup), findsOneWidget);
    expect(_table(tester).selectedIds, isEmpty);
    expect(_table(tester).idOf!(_rows[1]), isNull);
    final confirm = tester.widget<UtenButton>(
      find.byKey(const ValueKey('import-review-confirm')),
    );
    expect(confirm.onPressed, isNull);

    final before = tester.widget<Text>(
      find.byWidgetPredicate(
        (widget) => widget is Text && widget.semanticsLabel == '原值: 111',
      ),
    );
    expect(before.data, '111');
    expect(before.style!.decoration, TextDecoration.lineThrough);
    final after = tester.widget<Text>(
      find.byWidgetPredicate(
        (widget) => widget is Text && widget.semanticsLabel == '导入值: 222',
      ),
    );
    expect(after.data, '222');
    expect(find.text('M8'), findsOneWidget);
    expect(
      find.byWidgetPredicate(
        (widget) => widget is Text && widget.semanticsLabel == '无变化',
      ),
      findsNWidgets(2),
    );
    expect(
      find.byWidgetPredicate(
        (widget) => widget is Text && widget.semanticsLabel == '原值: 未填写',
      ),
      findsOneWidget,
    );
    if (_capture) {
      await saveAuditScreenshot(tester, _captureKey, 'import-review-desktop');
      final row = find.byKey(const ValueKey('import-review-row-changed'));
      await tester.tap(
        find.descendant(of: row, matching: find.byType(Checkbox)).hitTestable(),
      );
      await tester.pumpAndSettle();
      await saveAuditScreenshot(
        tester,
        _captureKey,
        'import-review-desktop-selected',
      );
    }
  });

  testWidgets('select all excludes automatic fills and returns explicit keys', (
    tester,
  ) async {
    final result = _Result();
    await _open(tester, result);
    await tester.tap(find.byKey(const ValueKey('import-review-select-all')));
    await tester.pumpAndSettle();
    expect(_table(tester).selectedIds, {'changed', 'other'});
    await tester.tap(find.byKey(const ValueKey('import-review-confirm')));
    await tester.pumpAndSettle();
    expect(result.completed, isTrue);
    expect(result.value, {'changed', 'other'});
  });

  testWidgets(
    'ignoring one row deselects it and select-all respects the choice',
    (tester) async {
      await _open(tester, _Result());
      await tester.tap(find.byKey(const ValueKey('import-review-select-all')));
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const ValueKey('import-review-ignore-changed')),
      );
      await tester.pumpAndSettle();
      expect(_table(tester).selectedIds, {'other'});
      expect(_table(tester).idOf!(_rows.first), isNull);
      await tester.tap(find.byKey(const ValueKey('import-review-select-all')));
      await tester.pumpAndSettle();
      expect(_table(tester).selectedIds, {'other'});
      await tester.tap(
        find.byKey(const ValueKey('import-review-ignore-changed')),
      );
      await tester.pumpAndSettle();
      expect(_table(tester).idOf!(_rows.first), 'changed');
      expect(_table(tester).selectedIds, {'other'});
    },
  );

  testWidgets(
    'ignore all returns an empty decision even after selecting rows',
    (tester) async {
      final result = _Result();
      await _open(tester, result);
      await tester.tap(find.byKey(const ValueKey('import-review-select-all')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('import-review-ignore-all')));
      await tester.pumpAndSettle();
      expect(result.completed, isTrue);
      expect(result.value, isEmpty);
    },
  );

  testWidgets(
    'back and keyboard escape cancel without a replacement decision',
    (tester) async {
      final result = _Result();
      await _open(tester, result);
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      expect(FocusManager.instance.primaryFocus, isNotNull);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(result.completed, isTrue);
      expect(result.value, isNull);
    },
  );

  testWidgets('automatic-fill-only review has an enabled import confirmation', (
    tester,
  ) async {
    final result = _Result();
    await _open(tester, result, rows: [_rows[1]]);
    expect(find.text('确认补齐并导入'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('import-review-ignore-all')),
      findsNothing,
    );
    await tester.tap(find.byKey(const ValueKey('import-review-confirm')));
    await tester.pumpAndSettle();
    expect(result.completed, isTrue);
    expect(result.value, isEmpty);
  });

  testWidgets('keyboard traversal can activate the ignore action', (
    tester,
  ) async {
    final result = _Result();
    await _open(tester, result);
    final target = find.byKey(const ValueKey('import-review-ignore-all'));
    var reached = false;
    for (var attempt = 0; attempt < 40; attempt++) {
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
      final focused = FocusManager.instance.primaryFocus?.context;
      if (focused != null &&
          find
              .ancestor(of: find.byWidget(focused.widget), matching: target)
              .evaluate()
              .isNotEmpty) {
        reached = true;
        break;
      }
    }
    expect(
      reached,
      isTrue,
      reason: 'Ignore action must be in keyboard traversal',
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(result.completed, isTrue);
    expect(result.value, isEmpty);
  });

  testWidgets(
    'narrow large-text keyboard focus reveals the final replace action',
    (tester) async {
      final result = _Result();
      await _open(
        tester,
        result,
        size: const Size(390, 900),
        textScale: 2,
        dark: true,
      );
      final row = find.byKey(const ValueKey('import-review-row-changed'));
      final checkbox = find.descendant(
        of: row,
        matching: find.byType(Checkbox),
      );
      await tester.tap(checkbox.hitTestable());
      await tester.pumpAndSettle();
      expect(_table(tester).selectedIds, {'changed'});
      final target = find.byKey(const ValueKey('import-review-confirm'));
      var reached = false;
      for (var attempt = 0; attempt < 50; attempt++) {
        await tester.sendKeyEvent(LogicalKeyboardKey.tab);
        await tester.pumpAndSettle();
        final focused = FocusManager.instance.primaryFocus?.context;
        if (focused != null &&
            find
                .ancestor(of: find.byWidget(focused.widget), matching: target)
                .evaluate()
                .isNotEmpty) {
          reached = true;
          break;
        }
      }
      expect(reached, isTrue);
      expect(target.hitTestable(), findsOneWidget);
      final rect = tester.getRect(target);
      expect(rect.bottom, lessThanOrEqualTo(900));
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(result.completed, isTrue);
      expect(result.value, {'changed'});
    },
  );

  for (final width in [390.0, 768.0, 1440.0]) {
    for (final dark in [false, true]) {
      testWidgets('width $width, 200% text, dark $dark remains usable', (
        tester,
      ) async {
        final result = _Result();
        final longRow = ImportReviewRow(
          rowKey: 'long',
          sourceRow: 8,
          identityLabel: List.filled(8, '长名称零部件').join(),
          matchReason: '同分类同名称',
          cells: [
            ImportReviewCell(
              key: 'clientModel',
              label: '客户型号',
              before: List.filled(12, 'LONG-OLD-MODEL-111/').join(),
              after: List.filled(12, 'LONG-NEW-MODEL-222/').join(),
            ),
          ],
        );
        await _open(
          tester,
          result,
          rows: [longRow, _rows[1]],
          size: Size(width, 900),
          textScale: 2,
          dark: dark,
        );
        expect(tester.takeException(), isNull);
        expect(_table(tester).selectedIds, isEmpty);
        final row = find.byKey(const ValueKey('import-review-row-long'));
        expect(tester.getSize(row).height, lessThan(400));
        final valueBars = find.descendant(
          of: row,
          matching: find.byType(Scrollbar),
        );
        expect(valueBars, findsNWidgets(2));
        for (final bar in valueBars.evaluate()) {
          final barFinder = find.byWidget(bar.widget);
          final viewport = find.descendant(
            of: barFinder,
            matching: find.byType(SingleChildScrollView),
          );
          expect(
            tester.getRect(barFinder).right - tester.getRect(viewport).right,
            greaterThanOrEqualTo(16),
            reason: 'A long imported value must not sit under its scroll thumb',
          );
        }
        if (_capture) {
          await saveAuditScreenshot(
            tester,
            _captureKey,
            'import-review-${width.toInt()}-${dark ? 'dark' : 'light'}-200',
          );
        }
        final ignore = find.byKey(const ValueKey('import-review-ignore-all'));
        await tester.ensureVisible(ignore);
        await tester.pumpAndSettle();
        expect(ignore.hitTestable(), findsOneWidget);
        await tester.tap(ignore);
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        expect(result.completed, isTrue);
        expect(result.value, isEmpty);
      });
    }
  }
}
