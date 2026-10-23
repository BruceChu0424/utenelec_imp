import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/core/theme/dark_theme.dart';
import 'package:uten_imp/features/basic_data/widgets/goods_cost_import_dialog.dart';

void main() {
  testWidgets('cost import full page remains usable at 390dp with 200% text', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final warning = List.filled(6, '旧文件价格包含需人工核对的缓存公式').join('；');
    await tester.pumpWidget(
      MaterialApp(
        theme: buildDarkTheme(),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('zh'),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: const TextScaler.linear(2)),
          child: child!,
        ),
        home: GoodsCostImportDialog(
          preview: {
            'id': 'import-test',
            'warnings': [warning],
            'blocks': const [
              {
                'key': 'sheet-1',
                'label': '从旧成本表导入的报价区块',
                'rows': [
                  {'key': 'row-1', 'code': 'PART-001', 'name': '待核材料'},
                ],
              },
            ],
          },
          lines: const [
            {'path': 'edge-1', 'goodsCode': 'PART-001', 'goodsName': '组件'},
          ],
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    final review = find.byKey(const ValueKey('cost-import-reviewed-row-1'));
    await tester.ensureVisible(review);
    await tester.pumpAndSettle();
    expect(review.hitTestable(), findsOneWidget);
    final apply = find.text('采用到本单');
    await tester.ensureVisible(apply);
    await tester.pumpAndSettle();
    expect(apply.hitTestable(), findsOneWidget);
  });
}
