import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/components/data_display/uten_revision_table.dart';
import 'package:uten_imp/core/theme/uten_colors.dart';
import 'package:uten_imp/features/basic_data/widgets/master_data_table_view.dart';

void main() {
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
