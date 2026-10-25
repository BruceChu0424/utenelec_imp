import 'dart:ui' show PointerDeviceKind;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/components/inputs/uten_dropdown_field.dart';
import 'package:uten_imp/components/inputs/uten_dropdown_geometry.dart';
import 'package:uten_imp/core/network/server_config.dart';
import 'package:uten_imp/core/responsive/display_zoom.dart';
import 'package:uten_imp/core/theme/light_theme.dart';
import 'package:uten_imp/shared/providers/authenticated_scope_provider.dart';
import 'package:uten_imp/shared/providers/shared_providers.dart';

import '../../support/audit_screenshot_support.dart';

const Key _field = ValueKey('resizable-color');
const _preferenceKey = 'master.GoodsListItem.colorId';
const _capture = bool.fromEnvironment('UTEN_DROPDOWN_SCREENSHOT');
final _captureKey = GlobalKey();
final _items = [
  for (var i = 1; i <= 40; i++)
    UtenDropdownItem(value: '$i', label: '白色$i 玻璃面板专用颜色'),
];

Finder _edge(UtenDropdownEdge edge) => find.byKey(
  ValueKey<(String, Key?, UtenDropdownEdge)>((
    'uten-dropdown-resize',
    _field,
    edge,
  )),
);
Rect _menu(WidgetTester tester) => tester.getRect(
  find
      .ancestor(of: find.byType(ListView), matching: find.byType(Material))
      .first,
);

Future<void> _pump(
  WidgetTester tester, {
  double zoom = 1,
  Alignment alignment = Alignment.topLeft,
  ProviderContainer? container,
  Key fieldKey = _field,
}) async {
  if (_capture) await loadAuditScreenshotFonts(tester);
  await tester.binding.setSurfaceSize(const Size(1280, 1000));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  final theme = buildLightTheme();
  Widget app = MaterialApp(
    theme: _capture ? auditScreenshotTheme(theme) : theme,
    builder: (context, child) => RepaintBoundary(
      key: _captureKey,
      child: UtenDisplayZoomBox(fontFactor: zoom, child: child!),
    ),
    home: Scaffold(
      body: Padding(
        padding: const EdgeInsets.all(60),
        child: Align(
          alignment: alignment,
          child: SizedBox(
            width: 120,
            child: UtenDropdownField(
              key: fieldKey,
              value: null,
              items: _items,
              dense: true,
              searchable: true,
              menuMatchContentWidth: true,
              menuPreferenceKey: _preferenceKey,
              onChanged: (_) {},
            ),
          ),
        ),
      ),
    ),
  );
  if (container != null) {
    app = UncontrolledProviderScope(container: container, child: app);
  }
  await tester.pumpWidget(app);
  await tester.tap(find.byKey(fieldKey));
  await tester.pumpAndSettle();
}

Future<void> _drag(WidgetTester tester, Finder handle, Offset delta) async {
  final gesture = await tester.startGesture(
    tester.getCenter(handle),
    kind: PointerDeviceKind.mouse,
  );
  final distance = delta.distance;
  await gesture.moveBy(
    distance == 0 ? const Offset(24, 0) : delta / distance * 24,
  );
  await tester.pump();
  await gesture.moveBy(
    delta - (distance == 0 ? const Offset(24, 0) : delta / distance * 24),
  );
  await tester.pump();
  await gesture.up();
  await gesture.removePointer();
  await tester.pumpAndSettle();
}

class _CaptureBinding extends AutomatedTestWidgetsFlutterBinding {
  @override
  bool get disableShadows => false;
}

void main() {
  if (_capture) _CaptureBinding();
  test(
    'every edge remains bounded after the viewport changes during a gesture',
    () {
      for (final edge in UtenDropdownEdge.values) {
        final result = resizeDropdownRect(
          const Rect.fromLTWH(700, 600, 120, 100),
          const Offset(500, 500),
          edge,
          const Rect.fromLTWH(8, 8, 300, 240),
          const Size(180, 320),
        );
        expect(result.left, greaterThanOrEqualTo(8));
        expect(result.top, greaterThanOrEqualTo(8));
        expect(result.right, lessThanOrEqualTo(308));
        expect(result.bottom, lessThanOrEqualTo(248));
      }
    },
  );

  testWidgets(
    'resize two axes, move, reopen and reset without editing a value',
    (tester) async {
      await _pump(tester);
      final original = _menu(tester);
      await _drag(tester, _edge(UtenDropdownEdge.right), const Offset(160, 0));
      expect(_menu(tester).width, closeTo(original.width + 160, 1));
      await _drag(
        tester,
        _edge(UtenDropdownEdge.bottom),
        const Offset(0, -220),
      );
      expect(_menu(tester).height, closeTo(original.height - 220, 1));
      final beforeMove = _menu(tester);
      await _drag(
        tester,
        find.byKey(
          const ValueKey<(String, Key?)>(('uten-dropdown-move', _field)),
        ),
        const Offset(80, 30),
      );
      expect(_menu(tester).left, closeTo(beforeMove.left + 80, 1));
      expect(_menu(tester).top, closeTo(beforeMove.top + 30, 1));
      final adjusted = _menu(tester);
      await tester.tapAt(const Offset(1200, 40));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(_field));
      await tester.pumpAndSettle();
      expect(_menu(tester), adjusted);
      if (_capture) {
        await saveAuditScreenshot(
          tester,
          _captureKey,
          'dropdown-resized-moved-desktop',
        );
      }
      await tester.enterText(find.byType(TextField), '白色40');
      await tester.pumpAndSettle();
      expect(
        _menu(tester),
        adjusted,
        reason: 'search does not discard the preferred size',
      );
      await tester.tap(
        find.byKey(
          const ValueKey<(String, Key?)>((
            'uten-dropdown-reset-geometry',
            _field,
          )),
        ),
      );
      await tester.pumpAndSettle();
      expect(_menu(tester).height, lessThan(adjusted.height / 2));
      expect(_menu(tester).left, original.left);
      expect(tester.takeException(), isNull);
    },
  );

  for (final zoom in [.85, 2.0]) {
    testWidgets(
      'mouse resizing uses actual overlay coordinates at zoom $zoom',
      (tester) async {
        await _pump(tester, zoom: zoom);
        final original = _menu(tester);
        await _drag(
          tester,
          _edge(UtenDropdownEdge.right),
          const Offset(100, 0),
        );
        expect(_menu(tester).width, closeTo(original.width + 100, 1));
        await _drag(
          tester,
          _edge(UtenDropdownEdge.bottom),
          const Offset(0, -120),
        );
        expect(_menu(tester).height, closeTo(original.height - 120, 1));
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'top and left edges resize an upward menu with the opposite edge fixed',
    (tester) async {
      await _pump(tester, alignment: Alignment.bottomRight);
      final original = _menu(tester);
      await _drag(tester, _edge(UtenDropdownEdge.top), const Offset(0, 150));
      expect(_menu(tester).bottom, closeTo(original.bottom, 1));
      expect(_menu(tester).height, closeTo(original.height - 150, 1));
      final beforeLeft = _menu(tester);
      await _drag(tester, _edge(UtenDropdownEdge.left), const Offset(-120, 0));
      expect(_menu(tester).right, closeTo(beforeLeft.right, 1));
      expect(_menu(tester).width, closeTo(beforeLeft.width + 120, 1));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('a new row and fresh provider restore the same field geometry', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    ProviderContainer fresh() => ProviderContainer(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(prefs),
        authenticatedScopeProvider.overrideWithValue(null),
        apiBaseUrlProvider.overrideWithValue('https://geometry.invalid/api'),
      ],
    );
    var container = fresh();
    await _pump(tester, container: container);
    await _drag(tester, _edge(UtenDropdownEdge.right), const Offset(160, 0));
    await _drag(tester, _edge(UtenDropdownEdge.bottom), const Offset(0, -220));
    await _drag(
      tester,
      find.byKey(
        const ValueKey<(String, Key?)>(('uten-dropdown-move', _field)),
      ),
      const Offset(80, 30),
    );
    final preferred = _menu(tester);
    expect(
      container.read(dropdownGeometryPrefsProvider).containsKey(_preferenceKey),
      isTrue,
    );
    await tester.pumpWidget(const SizedBox.shrink());
    container.dispose();
    container = fresh();
    addTearDown(container.dispose);
    await _pump(
      tester,
      container: container,
      fieldKey: const ValueKey('another-row'),
    );
    expect(_menu(tester), preferred);
    await tester.enterText(find.byType(TextField), '白');
    await tester.pumpAndSettle();
    if (_capture) {
      await saveAuditScreenshot(
        tester,
        _captureKey,
        'dropdown-restored-field-geometry',
      );
    }
    await tester.binding.setSurfaceSize(const Size(390, 620));
    await tester.pumpAndSettle();
    expect(_menu(tester).right, lessThanOrEqualTo(382));
    expect(_menu(tester).bottom, lessThanOrEqualTo(612));
    expect(
      container.read(dropdownGeometryPrefsProvider)[_preferenceKey]!.width,
      preferred.width,
    );
    await tester.binding.setSurfaceSize(const Size(1280, 1000));
    await tester.pumpAndSettle();
    expect(
      _menu(tester),
      preferred,
      reason: 'temporary viewport clamping preserves the larger preference',
    );
    expect(tester.takeException(), isNull);
  });
}
