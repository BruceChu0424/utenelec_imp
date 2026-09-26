// UtenEditableGrid 行级查重标红（EditableGridRow.flagged，2026-09-25）：
//  - flagged = true 的行整行 errorContainer 42% 红底（DecoratedBox 底色）；
//  - 通知器置位/清除只局部重绘行底色，无需宿主 setState；
//  - 同时提供 widget.rowColor 时 flagged 优先。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/components/layout/uten_editable_grid.dart';

class _FlagRow extends EditableGridRow {
  _FlagRow(this.label);

  final String label;
}

class _FlagGridHost extends StatefulWidget {
  const _FlagGridHost({super.key, this.rowColor});

  final Color? Function(_FlagRow row)? rowColor;

  @override
  State<_FlagGridHost> createState() => _FlagGridHostState();
}

class _FlagGridHostState extends State<_FlagGridHost> {
  final _controller = UtenEditableGridController<_FlagRow>(
    initial: [_FlagRow('A'), _FlagRow('B')],
  );

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      home: Scaffold(
        body: UtenEditableGrid<_FlagRow>(
          controller: _controller,
          createBlankRow: () => _FlagRow(''),
          rowColor: widget.rowColor,
          columns: [
            EditableGridColumn<_FlagRow>(
              key: 'label',
              label: '名称',
              width: 160,
              cellBuilder: (context, row) => Text(row.label),
            ),
          ],
        ),
      ),
    );
  }
}

void main() {
  Finder rowsWithColor(Color color) => find.byWidgetPredicate(
    (w) =>
        w is DecoratedBox &&
        w.decoration is BoxDecoration &&
        (w.decoration as BoxDecoration).color == color,
  );

  testWidgets('flagged 行整行红底；清除后恢复默认底色', (tester) async {
    final key = GlobalKey<_FlagGridHostState>();
    await tester.pumpWidget(_FlagGridHost(key: key));
    await tester.pumpAndSettle();

    final ctx = tester.element(find.text('A'));
    final tint = Theme.of(
      ctx,
    ).colorScheme.errorContainer.withValues(alpha: 0.42);
    expect(rowsWithColor(tint), findsNothing);

    // 标红第一行：不 setState，靠通知器局部重绘。
    key.currentState!._controller[0].flagged = true;
    await tester.pump();
    expect(rowsWithColor(tint), findsOneWidget);

    key.currentState!._controller[0].flagged = false;
    await tester.pump();
    expect(rowsWithColor(tint), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('flagged 优先于页面提供的 rowColor', (tester) async {
    final key = GlobalKey<_FlagGridHostState>();
    const pageTint = Color(0x33FFC107);
    await tester.pumpWidget(_FlagGridHost(key: key, rowColor: (_) => pageTint));
    await tester.pumpAndSettle();

    expect(rowsWithColor(pageTint), findsNWidgets(2));

    key.currentState!._controller[1].flagged = true;
    await tester.pump();

    final ctx = tester.element(find.text('B'));
    final tint = Theme.of(
      ctx,
    ).colorScheme.errorContainer.withValues(alpha: 0.42);
    expect(rowsWithColor(pageTint), findsOneWidget);
    expect(rowsWithColor(tint), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
