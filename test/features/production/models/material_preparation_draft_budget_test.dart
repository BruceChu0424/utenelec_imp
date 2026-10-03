import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/features/production/models/material_preparation_draft_budget.dart';
import 'package:uten_imp/features/production/models/material_preparation_supply_slice.dart';

MaterialPreparationBudgetLine line(
  String id, {
  String pool = 'goods|color|base-unit|warehouse',
  double owned = 0,
  double need = 1000,
  double requested = 1000,
  bool selected = false,
  bool useAvailableQty = true,
  int priority = 0,
  String? inputKey,
  double? cap,
  List<MaterialPreparationSupplySlice>? slices,
}) => MaterialPreparationBudgetLine(
  materialLineId: id,
  poolKey: pool,
  ownedAvailableQty: owned,
  uncoveredBeforeSharedQty: need,
  requestedQty: requested,
  selected: selected,
  useAvailableQty: useAvailableQty,
  priority: priority,
  inputKey: inputKey,
  adoptableSharedQty: cap,
  supplySlices: slices,
);

void main() {
  const pool = 'goods|color|base-unit|warehouse';
  test(
    'a scalar cap without source proof never invents two disjoint eligible supplies',
    () {
      final budget = MaterialPreparationDraftBudget.project(
        lines: [
          for (final id in ['a', 'b']) line(id, need: 100, cap: 100),
        ],
        sharedAvailableByPool: const {pool: 200},
      );
      expect(budget.summarize(['a', 'b']).availableQty, 200);
      expect(budget.summarize(['a', 'b']).netShortageQty, 100);
    },
  );
  List<MaterialPreparationSupplySlice> slices(Set<String> eligible) => [
    for (final key in ['X', 'Y'])
      MaterialPreparationSupplySlice(
        key: key,
        availableQty: 100,
        adoptable: eligible.contains(key),
      ),
  ];
  test(
    'X/Y exact slices keep an ineligible remainder from making A falsely ready',
    () {
      final budget = MaterialPreparationDraftBudget.project(
        lines: [
          line('a', need: 100, requested: 100, cap: 100, slices: slices({'Y'})),
          line(
            'b',
            need: 100,
            requested: 100,
            selected: true,
            cap: 100,
            slices: slices({'Y'}),
          ),
        ],
        sharedAvailableByPool: const {pool: 200},
      );
      expect(budget.rows['a']!.availableQty, 100);
      expect(budget.rows['a']!.netShortageQty, 100);
      expect(budget.rows['b']!.netShortageQty, 0);
      expect(budget.summarize(['a', 'b']).netShortageQty, 100);
    },
  );
  test(
    'summary never counts one eligible source for two independent needs',
    () {
      final budget = MaterialPreparationDraftBudget.project(
        lines: [
          for (final id in ['a', 'b'])
            line(id, need: 100, slices: slices({'Y'})),
        ],
        sharedAvailableByPool: const {pool: 200},
      );
      expect(budget.rows['a']!.netShortageQty, 0);
      expect(budget.rows['b']!.netShortageQty, 0);
      expect(budget.summarize(['a', 'b']).netShortageQty, 100);
      expect(budget.summarize(['a', 'b']).availableQty, 200);
    },
  );
  test(
    'selected eligible assignments reroute flexible A so restricted B can also be covered',
    () {
      final budget = MaterialPreparationDraftBudget.project(
        lines: [
          line(
            'a',
            need: 100,
            requested: 100,
            selected: true,
            slices: slices({'X', 'Y'}),
          ),
          line(
            'b',
            need: 100,
            requested: 100,
            selected: true,
            slices: slices({'X'}),
          ),
        ],
        sharedAvailableByPool: const {pool: 200},
      );
      expect(budget.rows['a']!.netShortageQty, 0);
      expect(budget.rows['b']!.netShortageQty, 0);
      expect(budget.summarize(['a', 'b']).netShortageQty, 0);
      expect(budget.summarize(['a', 'b']).reservedSharedQty, 200);
    },
  );
  test(
    'own public stock reduces the editing balance but never covers self demand',
    () {
      final budget = MaterialPreparationDraftBudget.project(
        lines: [
          line(
            'self',
            need: 100,
            requested: 100,
            selected: true,
            cap: 0,
            slices: slices({}),
          ),
        ],
        sharedAvailableByPool: const {pool: 200},
      );
      expect(budget.rows['self']!.availableQty, 100);
      expect(budget.rows['self']!.reservedSharedQty, 100);
      expect(budget.rows['self']!.netShortageQty, 100);
    },
  );
  test('two selected rows cannot cover twice from the same eligible slice', () {
    final budget = MaterialPreparationDraftBudget.project(
      lines: [
        for (final id in ['a', 'b'])
          line(
            id,
            need: 100,
            requested: 100,
            selected: true,
            slices: slices({'Y'}),
          ),
      ],
      sharedAvailableByPool: const {pool: 200},
    );
    expect(budget.summarize(['a', 'b']).reservedSharedQty, 200);
    expect(budget.summarize(['a', 'b']).availableQty, 0);
    expect(budget.summarize(['a', 'b']).netShortageQty, 100);
  });
  test('a grouped input spanning paths is budgeted only once', () {
    final budget = MaterialPreparationDraftBudget.project(
      lines: [
        line('a', requested: 1500, selected: true, inputKey: 'one-input'),
        line('b', requested: 1500, selected: true, inputKey: 'one-input'),
      ],
      sharedAvailableByPool: const {pool: 10000},
    );
    expect(
      budget.rows.values.fold<double>(
        0,
        (sum, row) => sum + row.reservedSharedQty,
      ),
      1500,
    );
    expect(budget.summarize(['a', 'b']).availableQty, 8500);
  });

  test('summary counts a shared remainder once across unselected sources', () {
    final budget = MaterialPreparationDraftBudget.project(
      lines: [line('a'), line('b')],
      sharedAvailableByPool: const {pool: 1000},
    );
    expect(budget.rows['a']!.netShortageQty, 0);
    expect(budget.rows['b']!.netShortageQty, 0);
    expect(budget.summarize(['a', 'b']).netShortageQty, 1000);
    expect(budget.summarize(['a', 'b']).availableQty, 1000);
  });
  test('only selected valid increments consume the shared pool once', () {
    final budget = MaterialPreparationDraftBudget.project(
      lines: [line('a', selected: true), line('b', requested: 9000)],
      sharedAvailableByPool: const {pool: 10000},
    );
    expect(budget.rows['a']!.reservedSharedQty, 1000);
    expect(budget.rows['a']!.availableQty, 9000);
    expect(budget.rows['b']!.availableQty, 9000);
    expect(budget.rows['b']!.reservedSharedQty, 0);
  });

  test(
    'extra purchasing leaves shared supply for selected rows that use it',
    () {
      final budget = MaterialPreparationDraftBudget.project(
        lines: [
          line(
            'a-extra',
            owned: 25,
            need: 100,
            requested: 250,
            selected: true,
            useAvailableQty: false,
            cap: 100,
            slices: slices({'Y'}),
          ),
          line(
            'b-use',
            need: 100,
            requested: 150,
            selected: true,
            cap: 100,
            slices: slices({'Y'}),
          ),
        ],
        sharedAvailableByPool: const {pool: 200},
      );

      expect(budget.rows['a-extra']!.reservedSharedQty, 0);
      expect(budget.coveredReservations['a-extra'] ?? 0, 0);
      expect(budget.inputs['a-extra']!.ownedAvailableQty, 25);
      expect(budget.inputs['a-extra']!.uncoveredBeforeSharedQty, 100);
      expect(budget.rows['a-extra']!.netShortageQty, 100);
      expect(budget.rows['b-use']!.reservedSharedQty, 150);
      expect(budget.rows['b-use']!.netShortageQty, 0);
      expect(budget.rows['a-extra']!.remainingSharedQty, 50);
      expect(budget.rows['b-use']!.availableQty, 50);
      expect(budget.summarize(['a-extra', 'b-use']).reservedSharedQty, 150);
      expect(budget.summarize(['a-extra', 'b-use']).availableQty, 50);
      expect(budget.summarize(['a-extra', 'b-use']).netShortageQty, 100);
    },
  );

  test('fully covered extra purchasing does not reserve the editing pool', () {
    final budget = MaterialPreparationDraftBudget.project(
      lines: [
        line(
          'append',
          owned: 100,
          need: 0,
          requested: 300,
          selected: true,
          useAvailableQty: false,
        ),
        line('future-demand', need: 200),
      ],
      sharedAvailableByPool: const {pool: 200},
    );

    expect(budget.rows['append']!.reservedSharedQty, 0);
    expect(budget.rows['append']!.availableQty, 200);
    expect(budget.rows['append']!.netShortageQty, 0);
    expect(budget.rows['future-demand']!.netShortageQty, 0);
    expect(budget.inputs['append']!.requestedQty, 300);
    expect(budget.inputs['append']!.ownedAvailableQty, 100);
    expect(budget.summarize(['append', 'future-demand']).availableQty, 200);
    expect(budget.summarize(['append', 'future-demand']).netShortageQty, 0);
  });

  test(
    'toggling extra purchasing releases and restores grouped reservations',
    () {
      MaterialPreparationDraftBudget project(bool useAvailableQty) =>
          MaterialPreparationDraftBudget.project(
            lines: [
              for (final id in ['a', 'b'])
                line(
                  id,
                  need: 100,
                  requested: 250,
                  selected: true,
                  useAvailableQty: useAvailableQty,
                  inputKey: 'one-input',
                ),
              line('future-demand', need: 100),
            ],
            sharedAvailableByPool: const {pool: 300},
          );

      final usingAvailable = project(true);
      expect(usingAvailable.summarize(['a', 'b']).reservedSharedQty, 250);
      expect(usingAvailable.rows['future-demand']!.availableQty, 50);
      expect(usingAvailable.rows['future-demand']!.netShortageQty, 50);

      final extraPurchasing = project(false);
      expect(extraPurchasing.summarize(['a', 'b']).reservedSharedQty, 0);
      expect(extraPurchasing.coveredReservations, isEmpty);
      expect(extraPurchasing.rows['future-demand']!.availableQty, 300);
      expect(extraPurchasing.rows['future-demand']!.netShortageQty, 0);
      expect(extraPurchasing.inputs['a']!.requestedQty, 250);
      expect(extraPurchasing.inputs['b']!.requestedQty, 250);

      final usingAvailableAgain = project(true);
      expect(usingAvailableAgain.summarize(['a', 'b']).reservedSharedQty, 250);
      expect(usingAvailableAgain.rows['future-demand']!.availableQty, 50);
      expect(usingAvailableAgain.rows['future-demand']!.netShortageQty, 50);
    },
  );

  test('private coverage stays with its owner and is not deducted twice', () {
    final budget = MaterialPreparationDraftBudget.project(
      lines: [
        line('a', owned: 1, need: 2, requested: 2, selected: true),
        line('b', need: 1, requested: 1),
      ],
      sharedAvailableByPool: const {pool: 2},
    );
    expect(budget.rows['a']!.reservedSharedQty, 2);
    expect(budget.rows['a']!.availableQty, 0);
    expect(budget.rows['a']!.netShortageQty, 0);
    expect(budget.rows['b']!.availableQty, 0);
    expect(budget.rows['b']!.netShortageQty, 1);
  });

  test('deselecting restores supply while retaining the entered amount', () {
    final lines = [line('a', requested: 9000), line('b', selected: true)];
    final budget = MaterialPreparationDraftBudget.project(
      lines: lines,
      sharedAvailableByPool: const {pool: 10000},
    );
    expect(lines.first.requestedQty, 9000);
    expect(budget.rows['a']!.availableQty, 9000);
    expect(budget.rows['b']!.netShortageQty, 0);
  });

  test(
    'competing rows preserve each selected reservation and expose shortage',
    () {
      final budget = MaterialPreparationDraftBudget.project(
        lines: [
          line('b', selected: true, priority: 2),
          line('a', requested: 700, selected: true, priority: 1),
          line('c', need: 500),
        ],
        sharedAvailableByPool: const {pool: 1000},
      );
      expect(budget.rows['a']!.reservedSharedQty, 700);
      expect(budget.rows['a']!.netShortageQty, 300);
      expect(budget.rows['b']!.reservedSharedQty, 300);
      expect(budget.rows['b']!.netShortageQty, 700);
      expect(budget.rows['c']!.netShortageQty, 500);
    },
  );

  test('warehouse unit and color scopes never borrow each others budget', () {
    final budget = MaterialPreparationDraftBudget.project(
      lines: [
        line('a', selected: true),
        line('b', pool: 'other-color', selected: true),
        line('c', pool: 'other-unit', selected: true),
        line('d', pool: 'other-warehouse', selected: true),
      ],
      sharedAvailableByPool: const {
        pool: 1000,
        'other-color': 2000,
        'other-unit': 3000,
        'other-warehouse': 4000,
      },
    );
    expect(budget.rows['a']!.remainingSharedQty, 0);
    expect(budget.rows['b']!.remainingSharedQty, 1000);
    expect(budget.rows['c']!.remainingSharedQty, 2000);
    expect(budget.rows['d']!.remainingSharedQty, 3000);
  });

  test(
    'invalid and cleared inputs consume nothing and fractional sums conserve',
    () {
      final budget = MaterialPreparationDraftBudget.project(
        lines: [
          line('a', requested: double.nan, selected: true),
          line('b', requested: -1, selected: true),
          line('c', requested: 0, selected: true),
          for (var i = 0; i < 1000; i++)
            line('fraction-$i', requested: 0.0001, selected: true),
        ],
        sharedAvailableByPool: const {pool: 0.1},
      );
      expect(budget.rows['a']!.reservedSharedQty, 0);
      expect(budget.rows['b']!.reservedSharedQty, 0);
      expect(budget.rows['c']!.reservedSharedQty, 0);
      expect(
        budget.rows.values.every((row) => row.remainingSharedQty == 0),
        isTrue,
      );
    },
  );
}
