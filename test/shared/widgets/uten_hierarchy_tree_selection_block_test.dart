// flat 树选中色块（2026-10-19 用户口径「盖过名字 + 左出右进」）：
// 色块为块体刚性平移——选中 left:0 盖过箭头与名字（宽 = 箭头位 + 名字自然宽 +
// 呼吸位，上限为扣除行尾控件后的标题簇宽），未选中 left:-宽 整块滑出左缘；切换选中 = 旧行向左
// 滑出、新行向右滑入。选中文字 = 色块反色（深绿块→白字、白块→深绿字）且加粗
// w700；浏览态右缘对勾退役。
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/features/basic_data/models/payment_style_node.dart';
import 'package:uten_imp/features/basic_data/widgets/uten_category_tree_view.dart';
import 'package:uten_imp/shared/widgets/uten_hierarchy_tree_view.dart';

void main() {
  for (final dark in [false, true]) {
    for (final scale in [1.0, 2.0]) {
      testWidgets('长选中标题位于色块内且不覆盖行尾控件 dark=$dark scale=$scale', (tester) async {
        const name = '外贸客户分类完整名称及编号需要保留核对';
        await tester.pumpWidget(
          MaterialApp(
            theme: ThemeData(
              brightness: dark ? Brightness.dark : Brightness.light,
              platform: TargetPlatform.windows,
            ),
            home: MediaQuery(
              data: MediaQueryData(textScaler: TextScaler.linear(scale)),
              child: Scaffold(
                body: SizedBox(
                  width: 240,
                  height: 300,
                  child: UtenCategoryTreeView<PaymentStyleNode>(
                    nodes: [
                      PaymentStyleNode(
                        id: 'root',
                        code: 'ROOT',
                        name: name,
                        children: const [],
                      ),
                    ],
                    flatLevelColors: true,
                    showSearch: false,
                    mode: UtenCategoryTreeMode.single,
                    selectedIds: const {'root'},
                    trailingBuilder: (_) => const Icon(
                      Icons.star,
                      key: Key('row-action'),
                      size: 20,
                      color: Colors.white,
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        final block = find.descendant(
          of: find.byType(AnimatedPositioned),
          matching: find.byType(DecoratedBox),
        );
        final blockRect = tester.getRect(block);
        final labelRect = tester.getRect(find.text(name));
        expect(blockRect.left, 0);
        expect(blockRect.right, greaterThanOrEqualTo(labelRect.right));
        expect(
          blockRect.right,
          lessThanOrEqualTo(
            tester.getRect(find.byKey(const Key('row-action'))).left,
          ),
        );
        expect(
          blockRect.right,
          lessThanOrEqualTo(
            tester.getRect(find.byIcon(Icons.check_circle_rounded)).left,
          ),
        );
        expect(
          tester
              .renderObject<RenderParagraph>(find.text(name))
              .didExceedMaxLines,
          isTrue,
        );
        expect(find.byTooltip(name), findsOneWidget);
        expect(
          tester.getCenter(find.byKey(const Key('row-action'))).dy,
          tester.getCenter(find.text(name)).dy,
        );
        expect(tester.takeException(), isNull);
      });
    }
  }

  testWidgets('行皮肤：深绿一级行的行尾图标反白、浅色行用辅助色', (tester) async {
    Icon iconNear(String name) => tester.widget<Icon>(
      find
          .descendant(
            of: find
                .ancestor(of: find.text(name), matching: find.byType(InkWell))
                .first,
            matching: find.byIcon(Icons.star),
          )
          .first,
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 240,
            height: 560,
            child: UtenCategoryTreeView<PaymentStyleNode>(
              nodes: [
                PaymentStyleNode(
                  id: 'root',
                  code: 'ROOT001',
                  name: '原材料',
                  children: [
                    PaymentStyleNode(
                      id: 'child',
                      code: 'CHILD01',
                      name: '五金件',
                      children: const [],
                    ),
                  ],
                ),
              ],
              flatLevelColors: true,
              showSearch: false,
              trailingBuilder: (node) => Builder(
                builder: (rowContext) => Icon(
                  Icons.star,
                  size: 16,
                  color:
                      UtenHierarchyRowSkin.maybeOf(rowContext)?.foreground ??
                      const Color(0xFF123456),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // 深绿一级行 → 白；浅色子行 → onSurfaceVariant（皮肤由树组件统一下发）。
    expect(iconNear('原材料').color, Colors.white);
    expect(iconNear('五金件').color, ThemeData().colorScheme.onSurfaceVariant);
    expect(tester.takeException(), isNull);
  });

  testWidgets('选中色块右滑入盖过名字、换选后旧行左滑出，浏览态无对勾', (tester) async {
    await tester.pumpWidget(const _TreeHost());
    await tester.pumpAndSettle();

    // 行序：0=原材料(父) 1=五金件(子)。选中前块体整块停在左缘外（不可见）。
    Finder blockOf(int row) => find.descendant(
      of: find.byType(AnimatedPositioned).at(row),
      matching: find.byType(DecoratedBox),
    );
    // 块体在 240 宽行内的可见部分（滑入/滑出的观感度量）。
    double visibleOf(Finder block) {
      final r = tester.getRect(block);
      return r.right.clamp(0, 240) - r.left.clamp(0, 240);
    }

    final block = blockOf(1);
    expect(tester.getRect(block).right, lessThanOrEqualTo(0));
    expect(visibleOf(blockOf(0)), 0);

    // 点行选中：块体自左缘向右滑入——起点可见 0，中段部分可见，到位盖过名字。
    await tester.tap(find.text('五金件'));
    await tester.pump();
    final startVisible = visibleOf(block);
    await tester.pump(const Duration(milliseconds: 130));
    final midVisible = visibleOf(block);
    await tester.pumpAndSettle();
    final fullVisible = visibleOf(block);
    expect(startVisible, lessThan(midVisible));
    expect(midVisible, lessThan(fullVisible));
    // 到位：贴左缘，可见宽 = 块宽 = 箭头位(8+32+4) + 名字自然宽 + 呼吸 8
    //（组件与量测同源 TextPainter 公式；此处校验明显越过名字起点 + 合理名字宽）。
    expect(tester.getRect(block).left, 0);
    expect(fullVisible, greaterThan(8 + 32 + 4 + 20));
    // 色块最多占实际标题簇；行尾动作区在簇外独立布局，不靠百分比猜测。
    expect(fullVisible, lessThanOrEqualTo(240));
    // 浏览态(flat+none)右缘对勾退役。
    expect(find.byIcon(Icons.check_circle_rounded), findsNothing);
    // 选中文字 = 色块反色（浅色行深绿块 → 白字）+ 加粗 w700。
    final rendered = tester
        .renderObject<RenderParagraph>(find.text('五金件'))
        .text
        .style;
    expect(rendered?.color, Colors.white);
    expect(rendered?.fontWeight, FontWeight.w700);
    expect(tester.takeException(), isNull);

    // 点另一行：旧行块体向左滑出（可见宽回 0），新行滑入到位。
    await tester.tap(find.text('原材料'));
    await tester.pumpAndSettle();
    expect(visibleOf(block), 0);
    expect(tester.getRect(block).right, lessThanOrEqualTo(0));
    expect(tester.getRect(blockOf(0)).left, 0);
    expect(visibleOf(blockOf(0)), greaterThan(0));
    expect(tester.takeException(), isNull);
  });
}

class _TreeHost extends StatefulWidget {
  const _TreeHost();

  @override
  State<_TreeHost> createState() => _TreeHostState();
}

class _TreeHostState extends State<_TreeHost> {
  String? _selectedId;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      home: Scaffold(
        body: SizedBox(
          width: 240,
          height: 560,
          child: UtenCategoryTreeView<PaymentStyleNode>(
            nodes: [
              PaymentStyleNode(
                id: 'root',
                code: 'ROOT001',
                name: '原材料',
                children: [
                  PaymentStyleNode(
                    id: 'child',
                    code: 'CHILD01',
                    name: '五金件',
                    children: const [],
                  ),
                ],
              ),
            ],
            flatLevelColors: true,
            showSearch: false,
            selectedIds: {_selectedId}.whereType<String>().toSet(),
            onNodeTap: (node) => setState(() => _selectedId = node.id),
          ),
        ),
      ),
    );
  }
}
