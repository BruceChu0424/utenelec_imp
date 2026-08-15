// 验证 UtenCollapsingHeaderScrollView + MasterDataTableView(primary:true) 联动折叠
// （对齐货品资料页的实际用法：collapsingHeader=卡片，body=搜索行+Expanded(表格)）：
// 1) primary 模式整树能正常构建（不抛布局/控制器附着异常）；
// 2) 向上滚（鼠标滚轮）先把卡片收起（其顶边 dy 减小），body 里的搜索行仍在（吸顶）；
// 3) 反向滚能把收起的卡片拉回。
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/components/layout/uten_collapsing_header_scroll_view.dart';
import 'package:uten_imp/features/basic_data/widgets/master_data_table_view.dart';

String _identity(String value) => value;

// 对齐货品资料 _DetailPane：卡片在 collapsingHeader（滚走），搜索行+表格在 body。
Widget _harness() {
  final items = [for (var i = 0; i < 60; i++) 'ROW-$i'];
  return MaterialApp(
    home: Scaffold(
      body: SizedBox(
        width: 800,
        height: 600,
        child: UtenCollapsingHeaderScrollView(
          collapsingHeader: Container(
            key: const ValueKey('card'),
            height: 180,
            color: Colors.amber,
            alignment: Alignment.centerLeft,
            child: const Text('CARD'),
          ),
          body: Column(
            children: [
              Container(
                key: const ValueKey('searchrow'),
                height: 48,
                color: Colors.blue,
                alignment: Alignment.centerLeft,
                child: const Text('SEARCH'),
              ),
              Expanded(
                child: MasterDataTableView<String>(
                  primary: true,
                  columns: const [
                    MasterColumnDef<String>(
                      key: 'value',
                      label: '值',
                      width: 240,
                      value: _identity,
                    ),
                  ],
                  items: items,
                  facets: const {},
                  nullCounts: const {},
                  filters: const {},
                  onFilterChanged: (_, _) {},
                ),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}

void main() {
  testWidgets('primary 模式整树正常构建（不抛异常）', (tester) async {
    await tester.pumpWidget(_harness());
    await tester.pumpAndSettle();

    expect(find.byType(NestedScrollView), findsOneWidget);
    expect(find.text('CARD'), findsOneWidget);
    expect(find.text('SEARCH'), findsOneWidget);
    expect(find.text('ROW-0'), findsOneWidget);
  });

  testWidgets('向上滚先把卡片收起、搜索行仍吸顶', (tester) async {
    await tester.pumpWidget(_harness());
    await tester.pumpAndSettle();

    final cardFinder = find.byKey(const ValueKey('card'));
    final bodyFinder = find.byWidgetPredicate(
      (w) => w is MasterDataTableView<String>,
    );

    final cardTopBefore = tester.getTopLeft(cardFinder).dy;

    // 滚轮「向下滚」（Offset(0, +)）= 内容上移。卡片展开时 NestedScrollView 先收卡片。
    // 滚 100（< 卡片高 180）使其部分收起、仍留树里可量。
    final center = tester.getCenter(bodyFinder);
    final pointer = TestPointer(1, PointerDeviceKind.mouse);
    await tester.sendEventToBinding(pointer.hover(center));
    await tester.sendEventToBinding(pointer.scroll(const Offset(0, 100)));
    await tester.pumpAndSettle();

    final cardTopAfter = tester.getTopLeft(cardFinder).dy;
    expect(
      cardTopAfter,
      lessThan(cardTopBefore),
      reason: '卡片应随上滚上移（顶边 dy 减小）；未动说明联动未生效',
    );
    // 搜索行在 body 里（表格的 Column 兄弟），不随表格内滚而消失。
    expect(find.byKey(const ValueKey('searchrow')), findsOneWidget);
  });

  testWidgets('向下滚能把收起的卡片拉回（反向协调）', (tester) async {
    await tester.pumpWidget(_harness());
    await tester.pumpAndSettle();

    final cardFinder = find.byKey(const ValueKey('card'));
    final bodyFinder = find.byWidgetPredicate(
      (w) => w is MasterDataTableView<String>,
    );
    final pointer = TestPointer(2, PointerDeviceKind.mouse);
    final center = tester.getCenter(bodyFinder);

    // 先向上滚把卡片部分收起。
    await tester.sendEventToBinding(pointer.hover(center));
    await tester.sendEventToBinding(pointer.scroll(const Offset(0, 100)));
    await tester.pumpAndSettle();
    final collapsedTop = tester.getTopLeft(cardFinder).dy;

    // 再向下滚（Offset(0, -)）= 内容下移：body 回顶后卡片随即拉回。
    await tester.sendEventToBinding(pointer.hover(center));
    await tester.sendEventToBinding(pointer.scroll(const Offset(0, -100)));
    await tester.pumpAndSettle();
    final restoredTop = tester.getTopLeft(cardFinder).dy;

    expect(
      restoredTop,
      greaterThan(collapsedTop),
      reason: '向下滚后卡片应被拉回（顶边 dy 增大）',
    );
  });
}
