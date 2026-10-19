// flat 树选中色块（2026-10-19 用户口径「盖过名字 + 从左滑入」）：
// 色块自左缘生长盖过名字（宽 = 箭头位 + 名字自然宽 + 呼吸位，上限行宽 60%），
// 文字/箭头随色块反白；浏览态右缘对勾退役。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/features/basic_data/models/payment_style_node.dart';
import 'package:uten_imp/features/basic_data/widgets/uten_category_tree_view.dart';

void main() {
  testWidgets('选中色块从左滑入、盖过名字，浏览态无对勾', (tester) async {
    await tester.pumpWidget(const _TreeHost());
    await tester.pumpAndSettle();

    // 行序：0=原材料(父) 1=五金件(子)。选中前两行色块宽度均为 0。
    Finder blockOf(int row) => find
        .descendant(
          of: find.byType(AnimatedPositioned).at(row),
          matching: find.byType(DecoratedBox),
        );
    expect(tester.getSize(blockOf(0)).width, 0);
    expect(tester.getSize(blockOf(1)).width, 0);

    // 点行选中：第一帧仍在起点附近，中段在生长，末段盖过名字 = 从左滑入。
    final block = blockOf(1);
    await tester.tap(find.text('五金件'));
    await tester.pump();
    final startWidth = tester.getSize(block).width;
    await tester.pump(const Duration(milliseconds: 110));
    final midWidth = tester.getSize(block).width;
    await tester.pumpAndSettle();
    final fullWidth = tester.getSize(block).width;
    expect(startWidth, lessThan(midWidth));
    expect(midWidth, lessThan(fullWidth));
    // 盖过名字：宽度 = 箭头位(8+32+4) + 名字自然宽 + 呼吸 8（组件与量测同源
    // TextPainter 公式；此处校验明显越过名字起点 + 合理名字宽）。
    expect(fullWidth, greaterThan(8 + 32 + 4 + 20));
    // 名字默认占比上限：色块不吞行（240 宽左栏的 60% = 144）。
    expect(fullWidth, lessThanOrEqualTo(144 + 0.5));
    // 浏览态(flat+none)右缘对勾退役。
    expect(find.byIcon(Icons.check_circle_rounded), findsNothing);
    expect(tester.takeException(), isNull);

    // 点另一行：新行色块滑入，旧行收回。
    await tester.tap(find.text('原材料'));
    await tester.pumpAndSettle();
    expect(tester.getSize(blockOf(0)).width, greaterThan(0));
    expect(tester.getSize(blockOf(1)).width, 0);
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
