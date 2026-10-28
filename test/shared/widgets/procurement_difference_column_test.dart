import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/features/basic_data/widgets/master_data_table_view.dart';
import 'package:uten_imp/shared/widgets/procurement_difference_column.dart';

typedef _Fact = ({String? difference, String? unit});

void main() {
  testWidgets('exact facts retain precision and unknown values stay unknown', (
    tester,
  ) async {
    late MasterColumnDef<_Fact> column;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) {
            column = procurementDifferenceColumn<_Fact>(
              context: context,
              differenceOf: (row) => row.difference,
              unitOf: (row) => row.unit,
            );
            return const SizedBox();
          },
        ),
      ),
    );
    const exact = (difference: '-9007199254740993.0001', unit: ' 个 ');
    expect(column.value(exact), '-9007199254740993.0001 个');
    expect(column.exactValueOf!(exact), exact.difference);
    expect(column.value((difference: '0.0000', unit: null)), '0');
    expect(column.value((difference: '2.5000', unit: '套')), '2.5 套');
    for (final unavailable in [null, '', 'invalid']) {
      expect(column.value((difference: unavailable, unit: '个')), '—');
    }
    expect(column.filterFromRows, isTrue);
    expect(column.sortable, isTrue);
    expect(column.supportsKeywordSearch, isTrue);
  });

  testWidgets('paged differences require an explicit server search contract', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) {
            MasterColumnDef<_Fact> column(bool serverSearch) =>
                procurementDifferenceColumn<_Fact>(
                  context: context,
                  differenceOf: (row) => row.difference,
                  unitOf: (row) => row.unit,
                  filterFromRows: false,
                  serverSearchEnabled: serverSearch,
                );
            expect(column(false).supportsKeywordSearch, isFalse);
            expect(column(true).supportsKeywordSearch, isTrue);
            expect(column(true).filterFromRows, isFalse);
            return const SizedBox();
          },
        ),
      ),
    );
  });

  testWidgets(
    'difference header searches exact numeric facts while retaining units',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(900, 700));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(
            home: Scaffold(
              body: Builder(
                builder: (context) {
                  return MasterDataTableView<_Fact>(
                    columns: [
                      procurementDifferenceColumn<_Fact>(
                        context: context,
                        differenceOf: (row) => row.difference,
                        unitOf: (row) => row.unit,
                      ),
                    ],
                    items: const [
                      (difference: '-9007199254740993.0001', unit: '件'),
                      (difference: '-9007199254740993.0002', unit: '箱'),
                      (difference: '0', unit: '件'),
                      (difference: null, unit: '件'),
                    ],
                    facets: const {},
                    nullCounts: const {},
                    filters: const {},
                    onFilterChanged: (_, _) {},
                  );
                },
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Delivery difference'));
      await tester.pumpAndSettle();
      final input = find.byType(TextField);
      expect(input, findsOneWidget);
      await tester.enterText(input, '=-9007199254740993.0001');
      await tester.tap(find.text('搜索'));
      await tester.pumpAndSettle();
      expect(find.text('-9007199254740993.0001 件'), findsOneWidget);
      expect(find.text('-9007199254740993.0002 箱'), findsNothing);
      expect(find.text('0 件'), findsNothing);
      expect(find.text('—'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('request and source-order columns explain distinct quantities', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) {
            final request = procurementDifferenceColumn<_Fact>(
              context: context,
              differenceOf: (row) => row.difference,
              unitOf: (row) => row.unit,
              scope: ProcurementDifferenceScope.request,
            );
            final source = procurementDifferenceColumn<_Fact>(
              context: context,
              differenceOf: (row) => row.difference,
              unitOf: (row) => row.unit,
              key: 'sourceOrderDifferenceQty',
              scope: ProcurementDifferenceScope.sourceOrder,
            );
            expect(request.info, contains('not yet ordered'));
            expect(request.label, 'Order difference');
            expect(request.info, contains('Pending orders are excluded'));
            expect(request.info, contains('gifts'));
            expect(source.key, 'sourceOrderDifferenceQty');
            expect(source.label, 'Source order difference');
            expect(source.info, contains('current source order difference'));
            return const SizedBox();
          },
        ),
      ),
    );
  });

  for (final selected in [false, true]) {
    testWidgets('negative emphasis respects selected foreground $selected', (
      tester,
    ) async {
      late Text cell;
      late Color expected;
      await tester.pumpWidget(
        MaterialApp(
          home: MasterDataTableCellScope(
            selected: selected,
            foregroundColor: Colors.white,
            child: Builder(
              builder: (context) {
                final column = procurementDifferenceColumn<_Fact>(
                  context: context,
                  differenceOf: (row) => row.difference,
                  unitOf: (row) => row.unit,
                );
                cell =
                    column.cellBuilder!(context, (
                          difference: '-0.0001',
                          unit: '件',
                        ))
                        as Text;
                expected = selected
                    ? Colors.white
                    : Theme.of(context).colorScheme.error;
                return cell;
              },
            ),
          ),
        ),
      );
      expect(cell.data, '-0.0001 件');
      expect(cell.style?.color, expected);
      expect(cell.style?.fontWeight, FontWeight.w700);
    });
  }
}
