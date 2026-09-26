// 表头右键菜单（固定到左侧 / 向左·右移一格 / 放到最前·最后 / 隐藏此列）集成测试。
//
// 覆盖（2026-09-25 需求）：
// 1. 右击列头弹菜单条目（替代此前 SelectionArea 的系统「全选/复制」工具条）；
// 2. 固定后列搬至多选框列右侧，横滚时钉在视口左缘（表头 + 数据行同款）；
// 3. 取消固定后列放回固定前的原位（2026-09-25 用户口径「回到对应的地方」）；
// 4. 移动/最前/最后按「固定块 / 普通列区」分区语义生效、不越块界；
// 5. 菜单隐藏 = 既有「至少留一列」守卫，隐藏固定列自动解除固定。
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/features/basic_data/widgets/master_data_table_view.dart';

class _Row {
  const _Row(this.id);
  final String id;
}

void main() {
  const rows = [_Row('a'), _Row('b')];

  // 8 列 × 150 = 1248 (+48 勾选框) —— 700 宽视口装不下，横滚才有意义；
  // 列0~列3 的中心都在视口内，可直接右击。
  Widget host({bool selectable = true}) => MaterialApp(
    home: Scaffold(
      body: SizedBox(
        width: 700,
        height: 400,
        child: MasterDataTableView<_Row>(
          columns: [
            for (var i = 0; i < 8; i++)
              MasterColumnDef<_Row>(
                key: 'c$i',
                label: '列$i',
                width: 150,
                value: (item) => '${item.id}-$i',
              ),
          ],
          items: rows,
          facets: const {},
          nullCounts: const {},
          filters: const {},
          onFilterChanged: (_, _) {},
          selectable: selectable,
          idOf: (item) => item.id,
          onSelectedIdsChanged: (_) {},
        ),
      ),
    ),
  );

  /// 以鼠标右键点在 [finder] 中心。
  Future<void> rightClick(WidgetTester tester, Finder finder) async {
    final gesture = await tester.startGesture(
      tester.getCenter(finder),
      kind: PointerDeviceKind.mouse,
      buttons: kSecondaryButton,
    );
    await gesture.up();
    await tester.pump();
  }

  double dxOf(Finder f) => (f.evaluate().first.renderObject as RenderBox)
      .localToGlobal(Offset.zero)
      .dx;

  /// 可命中（视口内）实例的全 x 坐标：横滚后固定列有「原件(滚出) + 冻结副本(钉左)」
  /// 两份，断言只该认视口内那份。
  Iterable<double> visibleDxOf(Finder f) => f.hitTestable().evaluate().map(
    (e) => (e.renderObject as RenderBox).localToGlobal(Offset.zero).dx,
  );

  testWidgets('右击列头弹固定/移动/隐藏菜单', (tester) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(host());
    await tester.pumpAndSettle();

    await rightClick(tester, find.text('列0'));
    expect(find.text('固定到左侧'), findsOneWidget);
    expect(find.text('向左移一格'), findsOneWidget);
    expect(find.text('向右移一格'), findsOneWidget);
    expect(find.text('放到最前'), findsOneWidget);
    expect(find.text('放到最后'), findsOneWidget);
    expect(find.text('隐藏此列'), findsOneWidget);
    // 收起菜单。
    await tester.tapAt(const Offset(5, 5));
    await tester.pumpAndSettle();
  });

  testWidgets('固定后列搬至多选框右侧，横滚时钉在视口左缘（表头+数据行）', (tester) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(host());
    await tester.pumpAndSettle();

    // 固定「列3」。
    await rightClick(tester, find.text('列3'));
    await tester.tap(find.text('固定到左侧'));
    await tester.pumpAndSettle();

    // 固定块前缀：列3 变成多选框之后的第一列，表头右上角显图钉。
    expect(dxOf(find.text('列3')), lessThan(dxOf(find.text('列0'))));
    expect(find.byIcon(Icons.push_pin_rounded), findsOneWidget);

    // 往右拖表体，把普通列滚出视口。
    await tester.drag(find.text('a-1'), const Offset(-500, 0));
    await tester.pumpAndSettle();

    // 固定列表头 + 数据文本仍钉在视口左缘（多选框 48 + 列宽 150 = 198 之内）。
    expect(
      visibleDxOf(find.text('列3')).any((d) => d >= 0 && d < 198),
      isTrue,
      reason: '固定列表头必须钉在视口左缘',
    );
    expect(
      visibleDxOf(find.text('a-3')).any((d) => d >= 0 && d < 198),
      isTrue,
      reason: '固定列数据格必须钉在视口左缘',
    );
    // 被滚走的普通列已出视口。
    expect(dxOf(find.text('a-1')), lessThan(0));

    // 冻结表头副本自带不透明底（surfaceContainerHigh）：正常表头底色来自外层
    // Material，副本浮在滚动的列头之上，不带底色会把底下列头透出来
    // （2026-09-25 用户反馈「固定的那列的表头不要透明」）。
    final theme = Theme.of(tester.element(find.text('列3').hitTestable().first));
    final headerCopyColors = find
        .ancestor(
          of: find.text('列3').hitTestable().first,
          matching: find.byType(ColoredBox),
        )
        .evaluate()
        .map((e) => (e.widget as ColoredBox).color);
    expect(
      headerCopyColors,
      contains(theme.colorScheme.surfaceContainerHigh),
      reason: '冻结表头副本必须有与表头一致的不透明底',
    );

    // 横滚态右击固定列副本仍出菜单（取消固定入口在线）。
    await rightClick(tester, find.text('列3').hitTestable().first);
    expect(find.text('取消固定'), findsOneWidget);
    await tester.tap(find.text('取消固定'));
    await tester.pumpAndSettle();
  });

  testWidgets('取消固定后列回到原来的位置、不再钉左', (tester) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(host());
    await tester.pumpAndSettle();

    await rightClick(tester, find.text('列2'));
    await tester.tap(find.text('固定到左侧'));
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.push_pin_rounded), findsOneWidget);
    await rightClick(tester, find.text('列2'));
    await tester.tap(find.text('取消固定'));
    await tester.pumpAndSettle();

    // 用户口径（2026-09-25）：取消固定回到对应的地方——列2 回到列1 与列3
    // 之间（固定前的原位），且不再是固定列（无图钉、随表体滚走）。
    expect(dxOf(find.text('列1')), lessThan(dxOf(find.text('列2'))));
    expect(dxOf(find.text('列2')), lessThan(dxOf(find.text('列3'))));
    expect(find.byIcon(Icons.push_pin_rounded), findsNothing);

    await tester.drag(find.text('a-1'), const Offset(-500, 0));
    await tester.pumpAndSettle();
    expect(dxOf(find.text('a-2')), lessThan(0), reason: '取消固定后数据格随表体滚走');
  });

  testWidgets('向右移一格 / 放到最前 / 放到最后（普通列区内语义）', (tester) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(host());
    await tester.pumpAndSettle();

    // 列1 右移一格 → 列0、列2、列1。
    await rightClick(tester, find.text('列1'));
    await tester.tap(find.text('向右移一格'));
    await tester.pumpAndSettle();
    expect(dxOf(find.text('列2')), lessThan(dxOf(find.text('列1'))));

    // 列1 放到最前 → 回到第一列。
    await rightClick(tester, find.text('列1'));
    await tester.tap(find.text('放到最前'));
    await tester.pumpAndSettle();
    expect(dxOf(find.text('列1')), lessThan(dxOf(find.text('列0'))));

    // 列1 放到最后 → 列7 之后。
    await rightClick(tester, find.text('列1'));
    await tester.tap(find.text('放到最后'));
    await tester.pumpAndSettle();
    expect(dxOf(find.text('列7')), lessThan(dxOf(find.text('列1'))));
  });

  testWidgets('固定块与普通列区不越界：固定列（块末）右移/最后置灰', (tester) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(host());
    await tester.pumpAndSettle();

    // 固定列2（成为固定块唯一成员，块末）。
    await rightClick(tester, find.text('列2'));
    await tester.tap(find.text('固定到左侧'));
    await tester.pumpAndSettle();
    await rightClick(tester, find.text('列2'));

    // 置灰条目仍渲染但不可点（InkWell onTap=null）。
    for (final label in ['向右移一格', '放到最后']) {
      final ink = find.ancestor(
        of: find.text(label),
        matching: find.byType(InkWell),
      );
      expect(
        (ink.evaluate().single.widget as InkWell).onTap,
        isNull,
        reason: '$label：固定块末位列不可越界',
      );
    }
    await tester.tapAt(const Offset(5, 5));
    await tester.pumpAndSettle();
  });

  testWidgets('菜单隐藏此列：固定列隐藏后自动解除固定', (tester) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(host());
    await tester.pumpAndSettle();

    await rightClick(tester, find.text('列2'));
    await tester.tap(find.text('固定到左侧'));
    await tester.pumpAndSettle();
    await rightClick(tester, find.text('列2'));
    await tester.tap(find.text('隐藏此列'));
    await tester.pumpAndSettle();

    expect(find.text('列2'), findsNothing);
    expect(find.byIcon(Icons.push_pin_rounded), findsNothing);
  });

  testWidgets('非多选表（无勾选框列）固定列同样生效', (tester) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(host(selectable: false));
    await tester.pumpAndSettle();

    await rightClick(tester, find.text('列4'));
    await tester.tap(find.text('固定到左侧'));
    await tester.pumpAndSettle();
    expect(dxOf(find.text('列4')), lessThan(dxOf(find.text('列0'))));

    await tester.drag(find.text('a-1'), const Offset(-500, 0));
    await tester.pumpAndSettle();
    expect(dxOf(find.text('a-4')) < 150, isTrue, reason: '无多选框表：固定列数据格钉在视口最左');
  });
}
