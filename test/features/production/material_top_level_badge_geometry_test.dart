import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/features/production/pages/production_material_analysis_page.dart';
import 'package:uten_imp/shared/widgets/uten_tree_table_cell.dart';

void main() {
  for (final platform in [TargetPlatform.windows, TargetPlatform.android]) {
    for (final dark in [false, true]) {
      testWidgets(
        'top-level badge fits its minimum identity width: $platform dark=$dark',
        (tester) async {
          final semantics = tester.ensureSemantics();
          try {
            for (final scale in [1.0, 2.0, 3.0]) {
              var toggles = 0;
              await tester.pumpWidget(
                MaterialApp(
                  theme: (dark ? ThemeData.dark() : ThemeData.light()).copyWith(
                    platform: platform,
                  ),
                  builder: (context, child) => MediaQuery(
                    data: MediaQuery.of(
                      context,
                    ).copyWith(textScaler: TextScaler.linear(scale)),
                    child: child!,
                  ),
                  home: Scaffold(
                    body: Builder(
                      builder: (context) {
                        final badgeWidth = MaterialTopLevelBadge.widthOf(
                          context,
                        );
                        return SizedBox(
                          key: const Key('identity-column'),
                          width: UtenTreeTableCell.compactMinimumWidthOf(
                            context,
                            depth: 0,
                            titleWidth: 24 + badgeWidth + 4,
                          ),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 12,
                              vertical: 4,
                            ),
                            child: UtenTreeTableCell.compact(
                              depth: 0,
                              title: '完整保留顶层产品与来源身份',
                              titleBadge: const MaterialTopLevelBadge(),
                              titleBadgeLabel: '顶层',
                              hasChildren: true,
                              onToggle: () => toggles++,
                              toggleKey: const Key('identity-toggle'),
                            ),
                          ),
                        );
                      },
                    ),
                  ),
                ),
              );
              final badge = find.byType(MaterialTopLevelBadge);
              final column = find.byKey(const Key('identity-column'));
              expect(
                tester.getRect(badge).right,
                lessThanOrEqualTo(tester.getRect(column).right),
              );
              expect(
                tester.getSize(badge).width,
                closeTo(
                  MaterialTopLevelBadge.widthOf(tester.element(badge)),
                  0.01,
                ),
              );
              expect(
                find.bySemanticsLabel(RegExp('完整保留顶层产品与来源身份，顶层')),
                findsOneWidget,
              );
              await tester.tap(find.byKey(const Key('identity-toggle')));
              expect(toggles, 1);
              expect(tester.takeException(), isNull);
            }
          } finally {
            semantics.dispose();
          }
        },
      );
    }
  }
}
