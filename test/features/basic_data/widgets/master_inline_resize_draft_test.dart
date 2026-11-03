import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/theme/light_theme.dart';
import 'package:uten_imp/features/basic_data/widgets/master_data_table_view.dart';
import 'package:uten_imp/features/basic_data/widgets/master_inline_edit.dart';

typedef _Row = ({String id, String name, String balance});

void main() {
  for (final richPreview in [false, true]) {
    testWidgets(
      'inline draft survives balance refresh and desktop mobile desktop resize (richPreview=$richPreview)',
      (tester) async {
        tester.view.physicalSize = const Size(1280, 720);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final controller = MasterInlineEditController<_Row>()..begin();
        final source = ValueNotifier<_Row>((
          id: 'account',
          name: '基本户',
          balance: '1286400.50',
        ));
        addTearDown(controller.dispose);
        addTearDown(source.dispose);
        await tester.pumpWidget(
          MaterialApp(
            theme: buildLightTheme().copyWith(platform: TargetPlatform.windows),
            home: Scaffold(
              body: ValueListenableBuilder<_Row>(
                valueListenable: source,
                builder: (context, row, _) => MasterDataTableView<_Row>(
                  key: const ValueKey('same-table'),
                  columns: controller.columns(
                    columns: [
                      MasterColumnDef(
                        key: 'name',
                        label: '账户名称',
                        width: 210,
                        value: (row) => row.name,
                        cellBuilder: richPreview
                            ? (_, row) => Text(
                                row.name,
                                style: const TextStyle(
                                  fontWeight: FontWeight.w600,
                                ),
                              )
                            : null,
                      ),
                      MasterColumnDef(
                        key: 'balance',
                        label: '当前余额',
                        width: 210,
                        value: (row) => row.balance,
                      ),
                    ],
                    idOf: (row) => row.id,
                    fields: {
                      'name': MasterInlineField(
                        key: 'name',
                        read: (row) => row.name,
                        required: true,
                      ),
                    },
                  ),
                  items: [row],
                  idOf: (row) => row.id,
                  expensiveRowMounts: true,
                  selectable: true,
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
        await tester.tap(
          find.byKey(const ValueKey('inline-activate-account-name')),
        );
        await tester.pumpAndSettle();
        final editor = find.byType(TextField);
        expect(editor, findsOneWidget);
        const draft = '基本户盘点名称草稿';
        await tester.enterText(editor, draft);
        await tester.pumpAndSettle();
        expect(controller.patchFor('account'), {'name': draft});
        source.value = (id: 'account', name: '基本户', balance: '1287000.50');
        await tester.pumpAndSettle();
        expect(tester.widget<TextField>(editor).controller!.text, draft);
        for (final size in [const Size(390, 844), const Size(1280, 720)]) {
          tester.view.physicalSize = size;
          await tester.pumpAndSettle();
          expect(controller.patchFor('account'), {'name': draft});
          expect(editor, findsOneWidget);
          expect(tester.widget<TextField>(editor).controller!.text, draft);
        }
        expect(tester.takeException(), isNull);
      },
    );
  }
}
