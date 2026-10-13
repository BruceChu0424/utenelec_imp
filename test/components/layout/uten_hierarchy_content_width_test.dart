import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/components/layout/uten_split_view.dart';
import 'package:uten_imp/features/basic_data/models/payment_style_node.dart';
import 'package:uten_imp/features/basic_data/widgets/uten_category_tree_view.dart';

const _label = '海外客户销售部完整分类ABCDEFGHIJKLMN(TEST)';
const _paneKey = Key('hierarchy-pane-width');
final _gutter = find.byTooltip('拖动调整宽度 · 双击复位');

Widget _host({double textScale = 1}) => MaterialApp(
  home: MediaQuery(
    data: MediaQueryData(
      size: const Size(1400, 800),
      textScaler: TextScaler.linear(textScale),
    ),
    child: Scaffold(
      body: UtenSplitView(
        persistenceKey: 'hierarchy-width-regression',
        initialLeadingWidth: 230,
        minLeadingWidth: 200,
        maxLeadingWidth: 230,
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
            mode: UtenCategoryTreeMode.single,
            selectedIds: const {'root'},
            flatLevelColors: true,
            showSearch: false,
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
  testWidgets('恢复、拖拽、键盘和复位不能压窄分类完整单行', (tester) async {
    tester.view.physicalSize = const Size(1400, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    SharedPreferences.setMockInitialValues({
      'uten.splitView.hierarchy-width-regression': 210.0,
    });
    await tester.pumpWidget(_host());
    await tester.pumpAndSettle();
    _expectFullTitle(tester, 1);
    final floor = tester.getSize(find.byKey(_paneKey)).width;
    expect(floor, greaterThan(230));

    await tester.drag(_gutter, const Offset(-800, 0));
    await tester.pumpAndSettle();
    expect(tester.getSize(find.byKey(_paneKey)).width, floor);
    _expectFullTitle(tester, 1);

    await tester.tap(_gutter);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    await tester.pumpAndSettle();
    expect(tester.getSize(find.byKey(_paneKey)).width, floor);

    await tester.tap(_gutter);
    await tester.pump(const Duration(milliseconds: 60));
    await tester.tap(_gutter);
    await tester.pumpAndSettle();
    expect(tester.getSize(find.byKey(_paneKey)).width, floor);
    _expectFullTitle(tester, 1);

    await tester.pumpWidget(_host(textScale: 1.5));
    await tester.pumpAndSettle();
    _expectFullTitle(tester, 1.5);
    expect(tester.getSize(find.byKey(_paneKey)).width, greaterThan(floor));

    tester.view.physicalSize = const Size(1000, 800);
    await tester.pumpAndSettle();
    expect(_gutter, findsNothing);
    await tester.tap(find.byIcon(Icons.account_tree_rounded));
    await tester.pumpAndSettle();
    _expectFullTitle(tester, 1.5);
    expect(find.text('右侧内容'), findsNothing);
  });
}
