import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/components/inputs/uten_dropdown_field.dart';
import 'package:uten_imp/core/theme/light_theme.dart';

const Key _fieldKey = ValueKey('content-width-field');
const _name = '配电装置壳体及端子装配完成接收产品';
const _fullContext = 'HP00003583 · 配电装置壳体及端子装配完成接收产品 · 可接收 3000 个 · 深灰色';
const _items = [
  UtenDropdownItem(value: 'a', label: _name, tooltip: _fullContext),
  UtenDropdownItem(value: 'b', label: '产品乙'),
];

Finder _option(String value) => find.byKey(
  ValueKey<(String, Key?, String?)>(('uten-dropdown-option', _fieldKey, value)),
);

Future<void> _pumpField(
  WidgetTester tester, {
  bool matchContent = false,
  double width = 160,
  double textScale = 1,
  Alignment alignment = Alignment.center,
  List<UtenDropdownItem> items = _items,
  bool searchable = false,
  Key fieldKey = _fieldKey,
  ValueChanged<String?>? onChanged,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: buildLightTheme(),
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(
          context,
        ).copyWith(textScaler: TextScaler.linear(textScale)),
        child: child!,
      ),
      home: Scaffold(
        body: Align(
          alignment: alignment,
          child: SizedBox(
            width: width,
            child: UtenDropdownField(
              key: fieldKey,
              value: null,
              items: items,
              allowClear: false,
              searchable: searchable,
              menuMatchContentWidth: matchContent,
              onChanged: onChanged ?? (_) {},
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(fieldKey));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets(
    'runtime field and item identities keep their exact menu key when names match',
    (tester) async {
      final fieldKey = ValueKey(
        'daily-allocation-destination-${identityHashCode(Object())}',
      );
      String? chosen;
      await _pumpField(
        tester,
        fieldKey: fieldKey,
        matchContent: true,
        items: const [
          UtenDropdownItem(
            value: 'first-demand',
            label: _name,
            tooltip: 'HP001 · 可接收 10 个',
          ),
          UtenDropdownItem(
            value: 'second-demand',
            label: _name,
            tooltip: 'HP002 · 可接收 20 个',
          ),
        ],
        onChanged: (value) => chosen = value,
      );
      final owner = tester.widget<UtenDropdownField>(find.byKey(fieldKey));
      for (final item in owner.items) {
        // Widget.key and item.value preserve their nullable declared types. A
        // caller using key! or a nonnullable literal must specify the same record
        // generic explicitly: ValueKey also compares its runtime generic type.
        final key = ValueKey(('uten-dropdown-option', owner.key, item.value));
        expect(find.byKey(key), findsOneWidget);
        expect(tester.widget<Tooltip>(find.byKey(key)).key, key);
      }
      final second = owner.items.last;
      await tester.tap(
        find.byKey(ValueKey(('uten-dropdown-option', owner.key, second.value))),
      );
      await tester.pumpAndSettle();
      expect(chosen, 'second-demand');
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('default menu retains field width and complete wrapping labels', (
    tester,
  ) async {
    await _pumpField(tester);
    expect(tester.getSize(_option('a')).width, 160);
    final text = tester.widget<Text>(find.text(_name));
    expect(text.maxLines, isNull);
    expect(text.overflow, TextOverflow.clip);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'opt-in menu measures visible name and keeps full metadata in tooltip only',
    (tester) async {
      await _pumpField(tester, matchContent: true);
      final row = tester.getRect(_option('a'));
      expect(row.width, greaterThan(160));
      final tooltip = tester.widget<Tooltip>(_option('a'));
      expect(tooltip.message, _fullContext);
      expect(find.text(_fullContext), findsNothing);
      final text = tester.widget<Text>(find.text(_name));
      final painter = TextPainter(
        text: TextSpan(text: _name, style: text.style),
        textDirection: TextDirection.ltr,
        textScaler: MediaQuery.textScalerOf(tester.element(_option('a'))),
      )..layout();
      expect(row.width, greaterThanOrEqualTo(painter.width + 46));
      expect(
        tester.getSize(find.text(_name)).height,
        lessThan(painter.preferredLineHeight * 1.5),
      );
      painter.dispose();
      expect(text.maxLines, isNull);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'larger text and indentation expand the measured menu without hidden-label inflation',
    (tester) async {
      const visible = UtenDropdownItem(
        value: 'a',
        label: _name,
        indent: 24,
        enabled: false,
      );
      await _pumpField(tester, matchContent: true, items: const [visible]);
      final normal = tester.getSize(_option('a')).width;
      await tester.tapAt(const Offset(10, 10));
      await tester.pumpAndSettle();
      await _pumpField(
        tester,
        matchContent: true,
        textScale: 1.5,
        items: [
          visible,
          UtenDropdownItem(
            value: 'hidden',
            label: List.filled(40, _name).join(),
            visible: false,
          ),
        ],
      );
      final large = tester.getSize(_option('a')).width;
      expect(large, greaterThan(normal));
      expect(
        large,
        lessThan(784),
        reason: 'invisible historical labels never determine menu width',
      );
      expect(find.text(List.filled(40, _name).join()), findsNothing);
      expect(
        tester.widget<Text>(find.text(_name)).style?.fontWeight,
        FontWeight.w600,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('opt-in menu near the right edge shifts inside the viewport', (
    tester,
  ) async {
    await _pumpField(
      tester,
      matchContent: true,
      alignment: Alignment.centerRight,
    );
    final rect = tester.getRect(_option('a'));
    expect(rect.left, greaterThanOrEqualTo(8));
    expect(rect.right, lessThanOrEqualTo(792));
    expect(rect.left, lessThan(tester.getTopLeft(find.byKey(_fieldKey)).dx));
    expect(tester.takeException(), isNull);
  });

  testWidgets('overwide names wrap fully within a narrow viewport', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(320, 600));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final name = List.filled(4, _name).join();
    await _pumpField(
      tester,
      matchContent: true,
      alignment: Alignment.centerRight,
      items: [UtenDropdownItem(value: 'a', label: name)],
    );
    final rect = tester.getRect(_option('a'));
    expect(rect.left, greaterThanOrEqualTo(8));
    expect(rect.right, lessThanOrEqualTo(312));
    final text = tester.widget<Text>(find.text(name));
    expect(text.data, name);
    expect(text.maxLines, isNull);
    expect(text.overflow, isNot(TextOverflow.ellipsis));
    expect(tester.getSize(find.text(name)).height, greaterThan(40));
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'search does not shrink menu and same-name values remain independently selectable',
    (tester) async {
      String? chosen;
      await _pumpField(
        tester,
        matchContent: true,
        searchable: true,
        items: const [
          UtenDropdownItem(
            value: 'a',
            label: _name,
            tooltip: 'HP001 · 可接收 10 个',
          ),
          UtenDropdownItem(
            value: 'b',
            label: _name,
            tooltip: 'HP002 · 可接收 20 个',
          ),
          UtenDropdownItem(value: 'c', label: '短名'),
        ],
        onChanged: (value) => chosen = value,
      );
      final before = tester.getSize(_option('a')).width;
      expect(tester.widget<Tooltip>(_option('a')).message, 'HP001 · 可接收 10 个');
      expect(tester.widget<Tooltip>(_option('b')).message, 'HP002 · 可接收 20 个');
      await tester.enterText(find.widgetWithText(TextField, '输入关键字搜索'), '短名');
      await tester.pumpAndSettle();
      expect(tester.getSize(_option('c')).width, before);
      await tester.enterText(find.widgetWithText(TextField, '输入关键字搜索'), _name);
      await tester.pumpAndSettle();
      await tester.tap(_option('b'));
      await tester.pumpAndSettle();
      expect(chosen, 'b');
      expect(_option('a'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );
}
