import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/features/production/widgets/material_shared_future_claim_dialog.dart';

void main() {
  testWidgets(
    'shared future pool supports explicit partial claims without double counting',
    (tester) async {
      MaterialSharedFutureClaimDraft? result;
      await _pump(
        tester,
        rows: const [
          MaterialSharedFutureClaimRow(
            actionGroupKey: 'a',
            poolKey: 'same-pool',
            label: '物料 A',
            unit: '个',
            needQty: 1000,
            timelyQty: 900,
            lateQty: 0,
          ),
          MaterialSharedFutureClaimRow(
            actionGroupKey: 'b',
            poolKey: 'same-pool',
            label: '物料 B',
            unit: '个',
            needQty: 1000,
            timelyQty: 900,
            lateQty: 0,
          ),
        ],
        onResult: (value) => result = value,
      );
      await tester.enterText(
        find.byKey(const ValueKey('shared-future-claim-qty-a')),
        '400',
      );
      await tester.enterText(
        find.byKey(const ValueKey('shared-future-claim-qty-b')),
        '500',
      );
      await tester.tap(
        find.byKey(const Key('material-table-confirm-claim-shared')),
      );
      await tester.pumpAndSettle();
      // 2026-09-13 起晚到/交期未明确默认接受，不再有显式勾选。
      expect(result?.allowLateSupply, isTrue);
      expect(result?.quantities.map((row) => row.toJson()), [
        {'actionGroupKey': 'a', 'qty': 400.0},
        {'actionGroupKey': 'b', 'qty': 500.0},
      ]);
    },
  );

  testWidgets(
    'late 900 is accepted by default and stays a future commitment at 375px',
    (tester) async {
      MaterialSharedFutureClaimDraft? result;
      await _pump(
        tester,
        size: const Size(375, 844),
        rows: const [
          MaterialSharedFutureClaimRow(
            actionGroupKey: 'a',
            poolKey: 'pool',
            label: '未来供给',
            unit: '个',
            needQty: 1000,
            timelyQty: 0,
            lateQty: 900,
          ),
        ],
        onResult: (value) => result = value,
      );
      expect(
        tester
            .widget<TextField>(
              find.byKey(const ValueKey('shared-future-claim-qty-a')),
            )
            .controller
            ?.text,
        '900',
        reason: '晚到份额默认计入可认领池并预填',
      );
      expect(find.byKey(const Key('shared-future-accept-late')), findsNothing);
      await tester.tap(
        find.byKey(const Key('material-table-confirm-claim-shared')),
      );
      await tester.pumpAndSettle();
      expect(result?.allowLateSupply, isTrue);
      expect(result?.quantities.single.qty, 900);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('overlapping paths cannot claim more than the one public pool', (
    tester,
  ) async {
    MaterialSharedFutureClaimDraft? result;
    await _pump(
      tester,
      rows: const [
        MaterialSharedFutureClaimRow(
          actionGroupKey: 'a',
          poolKey: 'pool',
          label: '甲路径',
          unit: '个',
          needQty: 1000,
          timelyQty: 900,
          lateQty: 0,
        ),
        MaterialSharedFutureClaimRow(
          actionGroupKey: 'b',
          poolKey: 'pool',
          label: '乙路径',
          unit: '个',
          needQty: 1000,
          timelyQty: 900,
          lateQty: 0,
        ),
      ],
      onResult: (value) => result = value,
    );
    await tester.enterText(
      find.byKey(const ValueKey('shared-future-claim-qty-a')),
      '500',
    );
    await tester.enterText(
      find.byKey(const ValueKey('shared-future-claim-qty-b')),
      '500',
    );
    await tester.tap(
      find.byKey(const Key('material-table-confirm-claim-shared')),
    );
    await tester.pumpAndSettle();
    expect(result, isNull);
    expect(
      find.byKey(const ValueKey('shared-future-claim-qty-b')),
      findsOneWidget,
    );
  });
}

Future<void> _pump(
  WidgetTester tester, {
  required List<MaterialSharedFutureClaimRow> rows,
  required ValueChanged<MaterialSharedFutureClaimDraft?> onResult,
  Size size = const Size(1200, 900),
}) async {
  await tester.binding.setSurfaceSize(size);
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(
    MaterialApp(
      home: Builder(
        builder: (context) => Scaffold(
          body: TextButton(
            onPressed: () async => onResult(
              await showDialog<MaterialSharedFutureClaimDraft>(
                context: context,
                builder: (_) => MaterialSharedFutureClaimDialog(rows: rows),
              ),
            ),
            child: const Text('采用未来供给'),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('采用未来供给'));
  await tester.pumpAndSettle();
}
