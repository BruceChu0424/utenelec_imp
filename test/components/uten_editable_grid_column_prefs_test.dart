import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/components/layout/uten_editable_grid.dart';

class _Row extends EditableGridRow {}

// 表头单元格无稳定 ValueKey，按表头文本定位（正文单元渲染的是小写文本，
// 与表头 '列A' 不冲突；表头设置弹层打开时另用 option key 定位）。
Widget _app({
  List<String> keys = const ['列A', '列B', '列C'],
  List<String>? initialOrder,
  Set<String>? initialHidden,
  void Function(List<String> order, Set<String> hidden)? onChanged,
}) {
  final controller = UtenEditableGridController<_Row>(initial: [_Row()]);
  return MaterialApp(
    home: Scaffold(
      body: ListView(
        children: [
          UtenEditableGrid<_Row>(
            controller: controller,
            columns: [
              for (final key in keys)
                EditableGridColumn<_Row>(
                  key: key,
                  label: key,
                  width: 120,
                  cellBuilder: (_, _) => Text(key.toLowerCase()),
                ),
            ],
            showAddRow: false,
            showRowDelete: false,
            showColumnSettings: true,
            initialColumnOrder: initialOrder,
            initialHiddenColumnKeys: initialHidden,
            onColumnSettingsChanged: onChanged,
          ),
        ],
      ),
    ),
  );
}

Finder _option(String key) => find.byKey(ValueKey('uten-column-option-$key'));

/// 点弹层外空白关闭（锚定浮层与货品资料同款：无关闭钮，点外部即关）。
Future<void> _closeSheet(WidgetTester tester) async {
  await tester.tapAt(const Offset(10, 10));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('persisted order and hidden keys replay on first build', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1200, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    // 持久化：隐藏列A、顺序 列C→列B（列A 仍参与顺序但被隐藏）。
    await tester.pumpWidget(
      _app(initialOrder: const ['列C', '列B', '列A'], initialHidden: const {'列A'}),
    );
    await tester.pumpAndSettle();

    expect(find.text('表头设置 2/3'), findsOneWidget);
    expect(find.text('列A'), findsNothing);
    // 列C 在列B 之前（横向位置比较）。
    expect(
      tester.getTopLeft(find.text('列C')).dx,
      lessThan(tester.getTopLeft(find.text('列B')).dx),
    );
  });

  testWidgets('unknown keys ignored and missing keys appended', (tester) async {
    tester.view.physicalSize = const Size(1200, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      _app(initialOrder: const ['不存在列', '列B'], initialHidden: const {'也没这列'}),
    );
    await tester.pumpAndSettle();

    // 未知 key 被忽略、缺失列（列A/列C）按默认序补齐、无隐藏。
    expect(find.text('表头设置 3/3'), findsOneWidget);
    expect(
      tester.getTopLeft(find.text('列B')).dx,
      lessThan(tester.getTopLeft(find.text('列A')).dx),
    );
    expect(
      tester.getTopLeft(find.text('列A')).dx,
      lessThan(tester.getTopLeft(find.text('列C')).dx),
    );
  });

  testWidgets('all-hidden persisted state falls back to showing everything', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1200, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(_app(initialHidden: const {'列A', '列B', '列C'}));
    await tester.pumpAndSettle();

    expect(find.text('表头设置 3/3'), findsOneWidget);
  });

  testWidgets('sheet toggle and restore-default notify the host', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1200, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final changes = <(List<String>, Set<String>)>[];
    await tester.pumpWidget(
      _app(
        onChanged: (order, hidden) {
          changes.add((order, hidden));
        },
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('表头设置 3/3'));
    await tester.pumpAndSettle();
    await tester.tap(_option('列A'));
    await tester.pumpAndSettle();
    expect(changes, hasLength(1));
    expect(changes.single.$1, const ['列A', '列B', '列C']);
    expect(changes.single.$2, const {'列A'});
    // 回调交出的是不可变快照。
    expect(() => changes.single.$1.add('x'), throwsA(isA<UnsupportedError>()));

    await tester.tap(find.text('恢复默认'));
    await tester.pumpAndSettle();
    expect(changes, hasLength(2));
    expect(changes.last.$2, isEmpty);
  });

  testWidgets('late-arriving initial values respect user changes', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1200, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(_app());
    await tester.pumpAndSettle();

    // 用户先隐藏列A（本次会话已手动改过列设置）。
    await tester.tap(find.text('表头设置 3/3'));
    await tester.pumpAndSettle();
    await tester.tap(_option('列A'));
    await tester.pumpAndSettle();
    await _closeSheet(tester);
    expect(find.text('列A'), findsNothing);

    // 服务端偏好迟到（如登录后同步）：不得覆盖用户本次会话的选择。
    await tester.pumpWidget(_app(initialHidden: const {'列B'}));
    await tester.pumpAndSettle();
    expect(find.text('列A'), findsNothing);
    expect(find.text('列B'), findsOneWidget);
  });

  testWidgets('untouched session replays late-arriving initial values', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1200, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(_app());
    await tester.pumpAndSettle();
    expect(find.text('表头设置 3/3'), findsOneWidget);

    // 同一会话先以默认值构建（未手动改过列设置），偏好迟到后照常重放。
    await tester.pumpWidget(
      _app(initialOrder: const ['列C', '列B', '列A'], initialHidden: const {'列B'}),
    );
    await tester.pumpAndSettle();
    expect(find.text('列B'), findsNothing);
    expect(
      tester.getTopLeft(find.text('列C')).dx,
      lessThan(tester.getTopLeft(find.text('列A')).dx),
    );
  });
}
