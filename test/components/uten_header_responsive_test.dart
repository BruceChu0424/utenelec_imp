import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/components/buttons/uten_app_bar_action_button.dart';
import 'package:uten_imp/components/layout/uten_app_bar.dart';
import 'package:uten_imp/components/layout/uten_segment_row.dart';
import 'package:uten_imp/core/theme/light_theme.dart';
import 'package:uten_imp/features/basic_data/widgets/uten_detail_tab_bar.dart';

void main() {
  testWidgets('phone groups refresh and permissions behind one action', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(375, 812);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          appBar: UtenAppBar(
            title: '采购任务工作台',
            showPagePermissionAction: false,
            actions: [
              UtenAppBarActionButton(label: '刷新', onPressed: () {}),
              UtenAppBarActionButton(label: '权限设置', onPressed: () {}),
            ],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('更多操作'), findsOneWidget);
    expect(find.text('刷新'), findsNothing);
    await tester.tap(find.text('更多操作'));
    await tester.pumpAndSettle();
    expect(find.text('刷新'), findsOneWidget);
    expect(find.text('权限设置'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('crowded tablet header measures labels and keeps every action', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(900, 700);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    var selected = -1;
    const labels = ['备料汇总预览', '物料分析记录', '生产计划历史', '取消分析', '刷新', '权限设置'];
    await tester.pumpWidget(
      MaterialApp(
        theme: buildLightTheme().copyWith(platform: TargetPlatform.windows),
        home: Scaffold(
          appBar: UtenAppBar(
            title: '物料分析准备',
            showBackButton: true,
            showPagePermissionAction: false,
            actions: [
              for (var i = 0; i < labels.length; i++)
                UtenAppBarActionButton(
                  label: labels[i],
                  onPressed: () => selected = i,
                ),
            ],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('更多操作'), findsOneWidget);
    expect(find.text(labels.first), findsNothing);
    await tester.tap(find.text('更多操作'));
    await tester.pumpAndSettle();
    for (final label in labels) {
      expect(find.text(label), findsOneWidget);
    }
    await tester.tap(find.text(labels[2]));
    await tester.pumpAndSettle();
    expect(selected, 2);
    expect(find.text(labels[2]), findsNothing);
    expect(tester.takeException(), isNull);

    tester.view.physicalSize = const Size(1600, 700);
    await tester.pumpAndSettle();
    expect(find.text('更多操作'), findsNothing);
    for (final label in labels) {
      expect(find.text(label), findsOneWidget);
    }
    expect(tester.takeException(), isNull);
  });

  testWidgets('detail categories share selection with swiped tab content', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: buildLightTheme(),
        home: DefaultTabController(
          length: 3,
          child: Scaffold(
            body: Builder(
              builder: (context) => Column(
                children: [
                  buildUtenDetailTabBar(
                    context,
                    tabs: const [
                      Tab(text: '基本信息'),
                      Tab(text: '组装信息'),
                      Tab(text: '库存与出入库'),
                    ],
                  ),
                  const Expanded(
                    child: TabBarView(
                      children: [
                        Center(child: Text('基本内容')),
                        Center(child: Text('组装内容')),
                        Center(child: Text('库存内容')),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('库存与出入库'));
    await tester.pumpAndSettle();
    expect(find.text('库存内容'), findsOneWidget);
    expect(
      tester
          .widget<UtenSegmentRow<int>>(find.byType(UtenSegmentRow<int>))
          .selected,
      {2},
    );
    await tester.drag(find.byType(TabBarView), const Offset(600, 0));
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<UtenSegmentRow<int>>(find.byType(UtenSegmentRow<int>))
          .selected,
      {1},
    );
    expect(tester.takeException(), isNull);
  });
}
