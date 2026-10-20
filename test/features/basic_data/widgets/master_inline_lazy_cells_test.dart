import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/components/buttons/uten_button.dart';
import 'package:uten_imp/features/basic_data/models/goods_node.dart';
import 'package:uten_imp/features/basic_data/models/unit_node.dart';
import 'package:uten_imp/features/basic_data/providers/color_unit_dict.dart';
import 'package:uten_imp/features/basic_data/repositories/goods_repository.dart';
import 'package:uten_imp/features/basic_data/widgets/goods_inline_edit.dart';
import 'package:uten_imp/features/basic_data/widgets/master_data_table_view.dart';
import 'package:uten_imp/features/basic_data/widgets/master_inline_edit.dart';
import 'package:uten_imp/shared/auth/permissions.dart';

class _Repository implements GoodsRepository {
  final calls = <String>[];
  final pending = Completer<GoodsDetail>();

  @override
  Future<GoodsDetail> detail(String id) {
    calls.add(id);
    return pending.future;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Cells extends ConsumerWidget {
  const _Cells({required this.controller});
  final MasterInlineEditController<GoodsListItem> controller;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final fields = goodsInlineFields(context, ref);
    final columns = controller.columns(
      columns: [
        MasterColumnDef<GoodsListItem>(
          key: 'name',
          label: '名称',
          width: 240,
          value: (row) => row.name,
        ),
        MasterColumnDef<GoodsListItem>(
          key: 'unitLegacyId',
          label: '单位',
          width: 240,
          value: (row) => row.unitName,
        ),
      ],
      idOf: (row) => row.id,
      fields: fields,
    );
    return Column(
      children: [
        for (var index = 1; index <= 2; index++)
          for (final column in columns)
            SizedBox(
              width: 240,
              child: column.cellBuilder!(
                context,
                GoodsListItem(
                  id: '$index',
                  name: '货品 $index',
                  unitId: 'unit',
                  unitName: '个',
                  version: 7,
                  writable: true,
                ),
              ),
            ),
      ],
    );
  }
}

void main() {
  testWidgets(
    'unit capability is lazy and its slow request does not block other cells',
    (tester) async {
      final repository = _Repository();
      final controller = MasterInlineEditController<GoodsListItem>()..begin();
      addTearDown(controller.dispose);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            goodsRepositoryProvider.overrideWithValue(repository),
            currentPermissionsProvider.overrideWithValue({Perm.goodsEdit}),
            colorDictProvider.overrideWith((ref) async => const []),
            unitDictProvider.overrideWith(
              (ref) async => const [UnitListItem(id: 'unit', name: '个')],
            ),
          ],
          child: MaterialApp(
            home: Scaffold(body: _Cells(controller: controller)),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byType(TextField), findsNothing);
      expect(repository.calls, isEmpty);

      await tester.tap(find.byKey(const ValueKey('inline-activate-1-unitId')));
      await tester.pump();
      expect(repository.calls, ['1']);
      final checking = find.byKey(const ValueKey('goods-inline-unit-check-1'));
      expect(tester.widget<UtenButton>(checking).isLoading, isTrue);
      expect(tester.widget<UtenButton>(checking).onPressed, isNull);
      expect(
        find.descendant(
          of: checking,
          matching: find.byType(CircularProgressIndicator),
        ),
        findsOneWidget,
      );
      expect(find.text('个'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('inline-activate-2-name')));
      await tester.pump();
      await tester.enterText(find.byType(TextField), '后端仍在等待时继续编辑');
      await tester.pump();
      expect(controller.patchFor('2'), {'name': '后端仍在等待时继续编辑'});
      expect(repository.pending.isCompleted, isFalse);
      expect(repository.calls, ['1']);
      repository.pending.complete(
        const GoodsDetail(
          id: '1',
          version: 7,
          writable: true,
          quantityUnitLocked: true,
        ),
      );
      await tester.pumpAndSettle();
      expect(checking, findsNothing);
      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(find.text('后端仍在等待时继续编辑'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'an inactive editable cell is reachable and activates from the keyboard',
    (tester) async {
      final controller = MasterInlineEditController<GoodsListItem>()..begin();
      addTearDown(controller.dispose);
      final field = MasterInlineField<GoodsListItem>(
        key: 'name',
        read: (row) => row.name,
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) {
                final column = controller
                    .columns(
                      columns: [
                        MasterColumnDef<GoodsListItem>(
                          key: 'name',
                          label: '名称',
                          width: 240,
                          value: (row) => row.name,
                        ),
                      ],
                      idOf: (row) => row.id,
                      fields: {'name': field},
                    )
                    .single;
                return SizedBox(
                  width: 240,
                  child: column.cellBuilder!(
                    context,
                    const GoodsListItem(id: '1', name: '键盘编辑'),
                  ),
                );
              },
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byType(TextField), findsNothing);
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(find.byType(TextField), findsOneWidget);
      await tester.enterText(find.byType(TextField), '键盘修改');
      expect(controller.patchFor('1'), {'name': '键盘修改'});
      expect(tester.takeException(), isNull);
    },
  );
}
