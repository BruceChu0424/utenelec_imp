import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/components/buttons/uten_back_button.dart';
import 'package:uten_imp/components/layout/uten_content_container.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/core/theme/dark_theme.dart';
import 'package:uten_imp/features/basic_data/widgets/goods_cost_import_dialog.dart';

void main() {
  for (final size in [const Size(390, 900), const Size(1440, 900)]) {
    testWidgets(
      '${size.width}px cost import route aligns header and content without duplicate gutters',
      (tester) async {
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final theme = buildDarkTheme().copyWith(
          platform: TargetPlatform.windows,
        );
        final gutter = UtenContentContainer.gutterForWidth(size.width);
        Rect? standaloneTable;
        for (final inherited in [false, true]) {
          await tester.pumpWidget(const SizedBox.shrink());
          await tester.pumpWidget(
            MaterialApp(
              theme: theme,
              localizationsDelegates: AppLocalizations.localizationsDelegates,
              supportedLocales: AppLocalizations.supportedLocales,
              locale: const Locale('zh'),
              home: Scaffold(
                body: Builder(
                  builder: (context) => TextButton(
                    onPressed: () => Navigator.of(context).push<void>(
                      MaterialPageRoute<void>(
                        builder: (_) {
                          const page = GoodsCostImportDialog(
                            filename: '成本导入.xlsx',
                            preview: {
                              'id': 'import-test',
                              'blocks': [
                                {
                                  'key': 'sheet-1',
                                  'label': '材料报价',
                                  'rows': [
                                    {
                                      'key': 'row-1',
                                      'code': 'PART-001',
                                      'name': '待核材料',
                                    },
                                  ],
                                },
                              ],
                            },
                            lines: [
                              {
                                'path': 'edge-1',
                                'goodsCode': 'PART-001',
                                'goodsName': '组件',
                              },
                            ],
                          );
                          return inherited
                              ? UtenContentContainer.wide(
                                  selectable: false,
                                  child: page,
                                )
                              : page;
                        },
                      ),
                    ),
                    child: const Text('打开'),
                  ),
                ),
              ),
            ),
          );
          await tester.tap(find.text('打开'));
          await tester.pumpAndSettle();
          final back = find.descendant(
            of: find.byType(UtenBackButton),
            matching: find.byType(IconButton),
          );
          expect(tester.getRect(back).left, closeTo(gutter, .01));
          final filename = find.byWidgetPredicate(
            (widget) =>
                widget is SelectableText && widget.data == '1/1  成本导入.xlsx',
          );
          expect(tester.getRect(filename).left, closeTo(gutter, .01));
          final table = tester.getRect(
            find.byKey(const ValueKey<String?>('sheet-1')),
          );
          expect(table.left, closeTo(gutter, .01));
          expect(table.height, greaterThan(0));
          if (standaloneTable == null) {
            standaloneTable = table;
            final background = find
                .descendant(
                  of: find.byType(GoodsCostImportDialog),
                  matching: find.byType(ColoredBox),
                )
                .first;
            expect(
              tester.widget<ColoredBox>(background).color,
              theme.scaffoldBackgroundColor,
            );
            expect(tester.getRect(background), Offset.zero & size);
          } else {
            expect(table, standaloneTable);
          }
          expect(tester.takeException(), isNull);
        }
      },
    );
  }

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
