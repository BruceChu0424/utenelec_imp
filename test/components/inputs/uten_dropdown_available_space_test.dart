import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/components/inputs/uten_dropdown_field.dart';
import 'package:uten_imp/core/theme/dark_theme.dart';
import 'package:uten_imp/core/theme/light_theme.dart';

import '../../support/audit_screenshot_support.dart';

const Key _field = ValueKey('available-space-color');
final _capture = GlobalKey();
const _captureScreenshots = bool.fromEnvironment('UTEN_DROPDOWN_SCREENSHOT');
final _colors = [
  for (var i = 1; i <= 40; i++)
    UtenDropdownItem(value: 'white-$i', label: '白色$i 玻璃面板专用颜色'),
];

Finder _option(String value) => find.byKey(
  ValueKey<(String, Key?, String?)>(('uten-dropdown-option', _field, value)),
);

Future<void> _open(
  WidgetTester tester, {
  required Size size,
  Alignment alignment = Alignment.topLeft,
  double textScale = 1,
  bool dark = false,
  EdgeInsets padding = EdgeInsets.zero,
  double keyboardHeight = 0,
  ValueChanged<String?>? onChanged,
}) async {
  if (_captureScreenshots) await loadAuditScreenshotFonts(tester);
  await tester.binding.setSurfaceSize(size);
  addTearDown(() => tester.binding.setSurfaceSize(null));
  final theme = dark ? buildDarkTheme() : buildLightTheme();
  await tester.pumpWidget(
    MaterialApp(
      theme: _captureScreenshots ? auditScreenshotTheme(theme) : theme,
      builder: (context, child) => RepaintBoundary(
        key: _capture,
        child: MediaQuery(
          data: MediaQuery.of(context).copyWith(
            textScaler: TextScaler.linear(textScale),
            padding: padding,
            viewInsets: EdgeInsets.only(bottom: keyboardHeight),
          ),
          child: child!,
        ),
      ),
      home: Scaffold(
        resizeToAvoidBottomInset: false,
        body: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 60),
          child: Align(
            alignment: alignment,
            child: SizedBox(
              width: 120,
              child: UtenDropdownField(
                key: _field,
                dense: true,
                value: null,
                allowClear: false,
                searchable: true,
                menuMatchContentWidth: true,
                items: _colors,
                onChanged: onChanged ?? (_) {},
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.byKey(_field));
  await tester.pumpAndSettle();
}

Rect _menuRect(WidgetTester tester) => tester.getRect(
  find
      .ancestor(of: find.byType(ListView), matching: find.byType(Material))
      .first,
);

Future<void> _captureMenu(WidgetTester tester, String name) async {
  if (_captureScreenshots) await saveAuditScreenshot(tester, _capture, name);
}

class _CaptureBinding extends AutomatedTestWidgetsFlutterBinding {
  @override
  bool get disableShadows => false;
}

void main() {
  if (_captureScreenshots) _CaptureBinding();
  testWidgets(
    'color search uses tall desktop space and shrinks for one match',
    (tester) async {
      await _open(tester, size: const Size(1280, 1000));
      await tester.enterText(find.byType(TextField), '白');
      await tester.pumpAndSettle();
      final menu = _menuRect(tester);
      expect(menu.height, greaterThan(700));
      expect(menu.top, tester.getRect(find.byKey(_field)).bottom + 2);
      expect(menu.bottom, lessThanOrEqualTo(992));
      expect(menu.width, greaterThan(120));
      expect(menu.contains(tester.getCenter(_option('white-12'))), isTrue);
      await _captureMenu(tester, 'dropdown-white-desktop');
      final width = menu.width;
      await tester.enterText(find.byType(TextField), '白色40');
      await tester.pumpAndSettle();
      expect(_menuRect(tester).height, lessThan(160));
      expect(_menuRect(tester).width, width);
      expect(_option('white-40'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'bottom color menu uses space above and keyboard picks exact ID',
    (tester) async {
      String? selected;
      await _open(
        tester,
        size: const Size(1280, 1000),
        alignment: Alignment.bottomRight,
        onChanged: (value) => selected = value,
      );
      final menu = _menuRect(tester);
      expect(menu.height, greaterThan(700));
      expect(menu.bottom, tester.getRect(find.byKey(_field)).top - 2);
      expect(menu.top, greaterThanOrEqualTo(8));
      expect(menu.right, lessThanOrEqualTo(1272));
      await tester.enterText(find.byType(TextField), '白色40');
      await tester.pumpAndSettle();
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();
      expect(selected, 'white-40');
      expect(find.byType(ListView), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  for (final size in [const Size(390, 620), const Size(760, 640)]) {
    testWidgets('large-text dark menu stays usable in $size', (tester) async {
      String? selected;
      await _open(
        tester,
        size: size,
        alignment: Alignment.centerRight,
        textScale: 2,
        dark: true,
        padding: const EdgeInsets.fromLTRB(12, 24, 12, 16),
        onChanged: (value) => selected = value,
      );
      final menu = _menuRect(tester);
      expect(menu.left, greaterThanOrEqualTo(20));
      expect(menu.right, lessThanOrEqualTo(size.width - 20));
      expect(menu.top, greaterThanOrEqualTo(32));
      expect(menu.bottom, lessThanOrEqualTo(size.height - 24));
      await tester.drag(find.byType(ListView), const Offset(0, -10000));
      await tester.pumpAndSettle();
      await _captureMenu(tester, 'dropdown-dark-${size.width.toInt()}');
      final visible = tester
          .getRect(_option('white-40'))
          .intersect(tester.getRect(find.byType(ListView)));
      expect(visible.height, greaterThan(24));
      await tester.tapAt(visible.center);
      await tester.pumpAndSettle();
      expect(selected, 'white-40');
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('menu remains above keyboard even when its anchor is obscured', (
    tester,
  ) async {
    await _open(
      tester,
      size: const Size(430, 800),
      alignment: Alignment.bottomRight,
      keyboardHeight: 300,
    );
    final menu = _menuRect(tester);
    expect(menu.top, greaterThanOrEqualTo(8));
    expect(menu.bottom, lessThanOrEqualTo(492));
    expect(menu.height, greaterThan(320));
    expect(find.byKey(const Key('uten-dropdown-search-input')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
