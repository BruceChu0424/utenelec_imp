import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/components/layout/uten_split_view.dart';
import 'package:uten_imp/features/basic_data/models/payment_style_node.dart';
import 'package:uten_imp/features/basic_data/widgets/uten_category_tree_view.dart';

const _label = '海外客户销售部完整分类ABCDEFGHIJKLMN';
const _paneKey = Key('hierarchy-pane-width');
final _gutter = find.byTooltip('拖动调整宽度 · 双击复位');

Widget _host({
  double textScale = 1,
  bool wideActions = false,
  VoidCallback? onAction,
}) => MaterialApp(
  theme: ThemeData(platform: TargetPlatform.windows),
  home: MediaQuery(
    data: MediaQueryData(
      size: const Size(1400, 800),
      textScaler: TextScaler.linear(textScale),
    ),
    child: Scaffold(
      body: UtenSplitView(
        persistenceKey: 'hierarchy-width-regression',
        initialLeadingWidth: wideActions ? 420 : 230,
        minLeadingWidth: 200,
        maxLeadingWidth: wideActions ? 600 : 230,
        leading: SizedBox(
          key: _paneKey,
          child: UtenCategoryTreeView<PaymentStyleNode>(
            nodes: [
              PaymentStyleNode(
                id: 'root',
                code: 'TEST',
                name: '海外客户销售部完整分类ABCDEFGHIJKLMN',
                children: const [],
              ),
            ],
            mode: wideActions
                ? UtenCategoryTreeMode.multi
                : UtenCategoryTreeMode.single,
            selectedIds: const {'root'},
            flatLevelColors: true,
            showSearch: false,
            trailingBuilder: wideActions
                ? (_) => SizedBox(
                    width: 180,
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        for (var index = 0; index < 3; index++)
                          IconButton(
                            key: ValueKey('row-action-$index'),
                            constraints: const BoxConstraints.tightFor(
                              width: 48,
                              height: 48,
                            ),
                            padding: EdgeInsets.zero,
                            onPressed: onAction ?? () {},
                            icon: const Icon(Icons.more_horiz),
                          ),
                      ],
                    ),
                  )
                : null,
          ),
        ),
        trailing: const Text('右侧内容'),
      ),
    ),
  ),
);

void _expectFullTitle(WidgetTester tester, double scale) {
  final title = find.text(_label);
  final widget = tester.widget<Text>(title);
  final painter = TextPainter(
    text: TextSpan(text: _label, style: widget.style),
    textDirection: TextDirection.ltr,
    textScaler: TextScaler.linear(scale),
  )..layout();
  expect(tester.getSize(title).width, greaterThanOrEqualTo(painter.width));
  painter.dispose();
  expect(tester.takeException(), isNull);
}

void main() {
  testWidgets('自动宽度保护分类完整单行，字体放大和空间不足仍自适应', (tester) async {
    tester.view.physicalSize = const Size(1400, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    SharedPreferences.setMockInitialValues({});
    await tester.pumpWidget(_host());
    await tester.pumpAndSettle();
    _expectFullTitle(tester, 1);
    final floor = tester.getSize(find.byKey(_paneKey)).width;
    expect(floor, greaterThan(230));

    await tester.pumpWidget(_host(textScale: 1.5));
    await tester.pumpAndSettle();
    _expectFullTitle(tester, 1.5);
    expect(tester.getSize(find.byKey(_paneKey)).width, greaterThan(floor));

    tester.view.physicalSize = const Size(800, 800);
    await tester.pumpAndSettle();
    expect(_gutter, findsNothing);
    await tester.tap(find.byIcon(Icons.account_tree_rounded));
    await tester.pumpAndSettle();
    _expectFullTitle(tester, 1.5);
    expect(find.text('右侧内容'), findsNothing);
  });

  testWidgets('恢复的手动窄宽和键盘左调不再被最长分类标题覆盖', (tester) async {
    tester.view.physicalSize = const Size(1400, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    SharedPreferences.setMockInitialValues({
      'uten.splitView.hierarchy-width-regression': 210.0,
    });
    await tester.pumpWidget(_host());
    await tester.pumpAndSettle();
    expect(tester.getSize(find.byKey(_paneKey)).width, 210);
    expect(find.byTooltip(_label), findsOneWidget);

    await tester.tap(_gutter);
    await tester.pump(const Duration(milliseconds: 350));
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    await tester.pumpAndSettle();
    expect(tester.getSize(find.byKey(_paneKey)).width, 200);

    await tester.pumpWidget(_host(textScale: 1.5));
    await tester.pumpAndSettle();
    expect(tester.getSize(find.byKey(_paneKey)).width, 200);
    expect(find.byTooltip(_label), findsOneWidget);
    tester.view.physicalSize = const Size(1000, 800);
    await tester.pumpAndSettle();
    expect(_gutter, findsOneWidget);
    expect(tester.getSize(find.byKey(_paneKey)).width, 200);
    expect(find.text('右侧内容'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('主动缩窄仍给多选框和宽操作区保留空间', (tester) async {
    tester.view.physicalSize = const Size(1800, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    SharedPreferences.setMockInitialValues({});
    var actions = 0;
    await tester.pumpWidget(
      _host(wideActions: true, onAction: () => actions++),
    );
    await tester.pumpAndSettle();
    final naturalWidth = tester.getSize(find.byKey(_paneKey)).width;
    _expectFullTitle(tester, 1);

    await tester.drag(_gutter, const Offset(-1500, 0));
    await tester.pumpAndSettle();
    final compactWidth = tester.getSize(find.byKey(_paneKey)).width;
    expect(compactWidth, greaterThan(200));
    expect(compactWidth, lessThan(naturalWidth));
    await tester.pumpWidget(
      _host(textScale: 2, wideActions: true, onAction: () => actions++),
    );
    await tester.pumpAndSettle();
    expect(
      tester.getSize(find.byKey(_paneKey)).width,
      greaterThan(compactWidth),
    );
    expect(tester.getSize(find.byKey(_paneKey)).width, lessThan(naturalWidth));
    expect(tester.getSize(find.text(_label)).width, greaterThan(0));
    final pane = tester.getRect(find.byKey(_paneKey));
    for (var index = 0; index < 3; index++) {
      final action = find.byKey(ValueKey('row-action-$index'));
      expect(pane.contains(tester.getTopLeft(action)), isTrue);
      expect(pane.contains(tester.getBottomRight(action)), isTrue);
    }
    expect(pane.contains(tester.getCenter(find.byType(Checkbox))), isTrue);
    await tester.tap(find.byKey(const ValueKey('row-action-2')));
    await tester.pumpAndSettle();
    expect(actions, 1);
    expect(tester.takeException(), isNull);
  });
}
