// UtenFilterPickerField（2026-09-11 全站「点开侧滑面板选」的筛选入口字段）：
// - 未筛选显示占位（默认「全部」），已筛选显示当前值；
// - 点击回调打开面板；enabled=false 不可点；
// - 圆角固定 UtenRadius.control（全平台唯一控件圆角）。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/components/inputs/uten_filter_picker_field.dart';
import 'package:uten_imp/core/theme/uten_tokens.dart';

void main() {
  Widget wrap(Widget child) => MaterialApp(
    home: Scaffold(body: Center(child: child)),
  );

  testWidgets('未选时显示标签 + 占位「全部」，点击拉面板', (tester) async {
    var taps = 0;
    await tester.pumpWidget(
      wrap(
        UtenFilterPickerField(label: '货品分类', value: null, onTap: () => taps++),
      ),
    );

    expect(find.text('货品分类'), findsOneWidget);
    expect(find.text('全部'), findsOneWidget);

    await tester.tap(find.byType(UtenFilterPickerField));
    await tester.pumpAndSettle();
    expect(taps, 1);
  });

  testWidgets('已选时显示当前值而非占位', (tester) async {
    await tester.pumpWidget(
      wrap(UtenFilterPickerField(label: '仓库', value: '成品仓库', onTap: () {})),
    );

    expect(find.text('成品仓库'), findsOneWidget);
    expect(find.text('全部'), findsNothing);
  });

  testWidgets('enabled=false 不可点', (tester) async {
    var taps = 0;
    await tester.pumpWidget(
      wrap(
        UtenFilterPickerField(
          label: '仓库',
          value: null,
          enabled: false,
          onTap: () => taps++,
        ),
      ),
    );

    await tester.tap(find.byType(UtenFilterPickerField));
    await tester.pumpAndSettle();
    expect(taps, 0);
  });

  testWidgets('圆角走 UtenRadius.control（控件圆角唯一口径）', (tester) async {
    await tester.pumpWidget(
      wrap(UtenFilterPickerField(label: '仓库', value: null, onTap: () {})),
    );

    final material = tester.widget<Material>(
      find
          .descendant(
            of: find.byType(UtenFilterPickerField),
            matching: find.byType(Material),
          )
          .first,
    );
    final shape = material.shape! as RoundedRectangleBorder;
    expect(shape.borderRadius, UtenRadius.controlAll);
  });
}
