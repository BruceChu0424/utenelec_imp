import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/components/data_display/uten_revision_table.dart';
import 'package:uten_imp/core/theme/uten_colors.dart';
import 'package:uten_imp/features/basic_data/widgets/master_data_table_view.dart';
import 'package:uten_imp/shared/platform_tables/platform_table_binding.dart';
import 'package:uten_imp/shared/platform_tables/platform_table_models.dart';

void main() {
  testWidgets('冻结扩展字段沿用审核单格变化样式和基础隐藏列', (tester) async {
    const definition = PlatformColumnDefinition(
      id: 'note',
      scope: 'expense_claim_item',
      name: '附加说明',
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: UtenRevisionTable<String>(
            tableKey: 'expense.claim.items',
            platformBinding: PlatformTableBinding<String>(
              tableKey: 'expense.claim.items',
              scope: 'expense_claim_item',
              recordIdOf: (_) => 'record',
              snapshotOf: (value) => PlatformRowValues(
                recordId: 'record',
                version: 1,
                cells: [
                  PlatformColumnCell(
                    columnId: 'note',
                    definition: definition,
                    value: value,
                  ),
                ],
              ),
            ),
            columns: [
              MasterColumnDef(
                key: 'name',
                label: '名称',
                width: 100,
                value: (_) => '费用',
              ),
              MasterColumnDef(
                key: 'hidden',
                label: '默认隐藏',
                width: 100,
                defaultVisible: false,
                value: (_) => '隐藏值',
              ),
            ],
            rows: const [
              UtenRevisionRow(value: '原说明', kind: UtenRevisionKind.removed),
              UtenRevisionRow(
                value: '',
                kind: UtenRevisionKind.added,
                changedKeys: {'platform:note'},
              ),
            ],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('隐藏值'), findsNothing);
    expect(find.text('原说明'), findsOneWidget);
    final cleared = tester.widget<Text>(find.text('未填写'));
    expect(cleared.style!.color, UtenColors.errorText);
    expect(cleared.style!.fontWeight, FontWeight.w800);
    await tester.tap(
      find.byKey(const Key('platform-table-add-column')).hitTestable().last,
    );
    await tester.pumpAndSettle();
    expect(find.text('显示列'), findsWidgets);
    expect(find.byKey(const Key('platform-column-new')), findsNothing);
    expect(find.text('复用已有列'), findsNothing);
    await tester.tap(find.text('默认隐藏'));
    await tester.pumpAndSettle();
    expect(find.text('隐藏值'), findsWidgets);
    expect(find.text('原说明'), findsOneWidget);
  });
  testWidgets('清空字段在新行里显示可见的红粗空值提示', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: UtenRevisionTable<String>(
            columns: [
              MasterColumnDef(
                key: 'remark',
                label: '备注',
                width: 240,
                value: (value) => value,
              ),
            ],
            rows: const [
              UtenRevisionRow(value: '旧备注', kind: UtenRevisionKind.removed),
              UtenRevisionRow(
                value: '',
                kind: UtenRevisionKind.added,
                changedKeys: {'remark'},
              ),
            ],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final cleared = tester.widget<Text>(find.text('未填写'));
    expect(cleared.style!.color, UtenColors.errorText);
    expect(cleared.style!.fontWeight, FontWeight.w800);
  });
  for (final brightness in Brightness.values) {
    for (final width in [375.0, 1440.0]) {
      testWidgets('整行划线、红绿字和窄屏滚动 $brightness $width', (tester) async {
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = Size(width, 720);
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        await tester.pumpWidget(
          MaterialApp(
            theme: ThemeData(brightness: brightness),
            home: Scaffold(
              body: MediaQuery(
                data: MediaQueryData(
                  size: Size(width, 720),
                  textScaler: TextScaler.linear(width == 375 ? 2 : 1),
                ),
                child: UtenRevisionTable<String>(
                  columns: [
                    MasterColumnDef(
                      key: 'goods',
                      label: '货品名称',
                      width: 260,
                      value: (value) => value,
                    ),
                    const MasterColumnDef(
                      key: 'qty',
                      label: '数量',
                      width: 100,
                      value: _qty,
                    ),
                  ],
                  rows: const [
                    UtenRevisionRow(
                      value: '旧货品',
                      kind: UtenRevisionKind.removed,
                    ),
                    UtenRevisionRow(
                      value: '新货品',
                      kind: UtenRevisionKind.added,
                      changedKeys: {'qty'},
                    ),
                    UtenRevisionRow(
                      value: '保留货品',
                      kind: UtenRevisionKind.unchanged,
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        final strike = find.byType(UtenRevisionStrike);
        expect(strike, findsOneWidget);
        final oldText = tester.widget<Text>(find.text('旧货品'));
        expect(
          oldText.style!.color,
          brightness == Brightness.dark
              ? UtenColors.errorOnDark
              : UtenColors.errorText,
        );
        final newText = tester.widget<Text>(find.text('新货品'));
        expect(
          newText.style!.color,
          brightness == Brightness.dark
              ? UtenColors.successOnDark
              : UtenColors.successText,
        );
        expect(tester.getSize(strike).width, greaterThan(400));
        final changedQty = tester.widget<Text>(find.text('6'));
        expect(
          changedQty.style!.color,
          brightness == Brightness.dark
              ? UtenColors.errorOnDark
              : UtenColors.errorText,
        );
        expect(changedQty.style!.fontWeight, FontWeight.w800);
        expect(newText.style!.fontWeight, isNot(FontWeight.w800));
      });
    }
  }
}

String _qty(String value) => value == '旧货品'
    ? '10'
    : value == '新货品'
    ? '6'
    : '2';
