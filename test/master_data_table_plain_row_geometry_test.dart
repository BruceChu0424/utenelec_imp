import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/theme/light_theme.dart';
import 'package:uten_imp/features/basic_data/widgets/master_data_table_view.dart';

void main() {
  for (final platform in [TargetPlatform.windows, TargetPlatform.android]) {
    for (final scale in [1.0, 2.0]) {
      for (final selectionColumn in [false, true]) {
        testWidgets(
          'single-line fast geometry equals measured controls $platform/$scale/$selectionColumn',
          (tester) async {
            final custom = ValueNotifier(false);
            addTearDown(custom.dispose);
            const rows = ['中文货品 Ag', '한글 material', '🙂 mixed', ''];
            final theme = buildLightTheme().copyWith(platform: platform);
            await tester.pumpWidget(
              MaterialApp(
                theme: theme,
                builder: (context, child) => MediaQuery(
                  data: MediaQuery.of(
                    context,
                  ).copyWith(textScaler: TextScaler.linear(scale)),
                  child: child!,
                ),
                home: Scaffold(
                  body: ValueListenableBuilder<bool>(
                    valueListenable: custom,
                    builder: (_, rich, _) => MasterDataTableView<int>(
                      virtualized: true,
                      selectable: true,
                      showSelectionColumn: selectionColumn,
                      rowKeyOf: (row) => '$row',
                      idOf: (row) => '$row',
                      selectedIds: const {'1'},
                      rowDecorationBuilder: (_, row, child) =>
                          KeyedSubtree(key: ValueKey('row-$row'), child: child),
                      temporaryLeadingColumnKeys: const ['status'],
                      items: const [0, 1, 2, 3],
                      columns: [
                        MasterColumnDef<int>(
                          key: 'status',
                          label: '状态',
                          width: 120,
                          value: (row) => rows[row],
                          cellBuilder: rich
                              ? (_, row) => Text(
                                  rows[row],
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                )
                              : null,
                        ),
                        MasterColumnDef<int>(
                          key: 'name',
                          label: '名称',
                          width: 240,
                          value: (row) => 'value-$row',
                          cellBuilder: rich
                              ? (_, row) => Text(
                                  'value-$row',
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                )
                              : null,
                        ),
                      ],
                      facets: const {},
                      nullCounts: const {},
                      filters: const {},
                      onFilterChanged: (_, _) {},
                      showFullscreenToggle: false,
                    ),
                  ),
                ),
              ),
            );
            await tester.pumpAndSettle();
            final fast = [
              for (var row = 0; row < 4; row++)
                tester.getSize(find.byKey(ValueKey('row-$row'))).height,
            ];
            custom.value = true;
            await tester.pumpAndSettle();
            for (var row = 0; row < 4; row++) {
              expect(
                tester.getSize(find.byKey(ValueKey('row-$row'))).height,
                closeTo(fast[row], .01),
              );
            }
            expect(tester.takeException(), isNull);
          },
        );
      }
    }
  }
}
