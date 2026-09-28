// 报工「去向分配」重排(V736/ADR-127)的纯算法契约：先急后缓逐个分满、余量下移、送入仓库合并、
// 工人定过的条目不被替换、多行共用同一上层工单「还差多少」、单位换算与服务端同一舍入。
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/features/production/models/daily_output_allocation.dart';
import 'package:uten_imp/features/production/models/production_direct_transfer_candidate.dart';

ProductionDirectTransferCandidate _parent(
  String id,
  double remaining, {
  double requiredQty = 0,
  double covered = 0,
}) => ProductionDirectTransferCandidate(
  demandId: id,
  executionSegmentId: 'segment-$id',
  executionSegmentCode: 'ZX-$id',
  remainingQty: remaining,
  requiredQty: requiredQty,
  alreadyCoveredQty: covered,
);

OutputAllocationRowInput _row(
  double? quantity, {
  List<ProductionDirectTransferCandidate> candidates = const [],
  List<OutputAllocationSlot> slots = const [],
  String source = 'plan-item',
  double rate = 1,
  bool known = true,
  int limit = 1 << 30,
  Set<String> declined = const {},
}) => OutputAllocationRowInput(
  sourceKey: source,
  quantity: quantity,
  unitRate: rate,
  candidates: candidates,
  slots: slots,
  candidatesKnown: known,
  receiverLimit: limit,
  declined: declined,
);

List<(String?, double, bool)> _lines(OutputAllocationRowPlan plan) => [
  for (final line in plan.lines) (line.demandId, line.qty, line.fixed),
];

/// 与报工页同口径把上一次的结果当作下一次的输入：固定条目带工人自己要的数，建议条目不带数。
List<OutputAllocationSlot> _slotsFrom(OutputAllocationRowPlan plan) => [
  for (final line in plan.lines)
    OutputAllocationSlot(
      demandId: line.demandId,
      fixed: line.fixed,
      requested: line.fixed ? line.requested : null,
    ),
];

void main() {
  test(
    'the most urgent parent comes first, the rest cascades, then the warehouse',
    () {
      final plan = planOutputAllocations([
        _row(10000, candidates: [_parent('A', 1000), _parent('B', 1000)]),
      ]).single;
      expect(_lines(plan), [
        ('A', 1000, false),
        ('B', 1000, false),
        (null, 8000, false),
      ]);
      expect(plan.directTotal + plan.warehouseTotal, 10000);
    },
  );

  test(
    'without any parent that can take it the whole quantity goes to the warehouse',
    () {
      final plan = planOutputAllocations([_row(12)]).single;
      expect(_lines(plan), [(null, 12, false)]);
      expect(planOutputAllocations([_row(null)]).single.lines, isEmpty);
    },
  );

  test(
    'lowering a worker row flows the remainder to the next parent, then the warehouse',
    () {
      final plan = planOutputAllocations([
        _row(
          10000,
          candidates: [_parent('A', 5000), _parent('B', 1000)],
          slots: const [
            OutputAllocationSlot(demandId: 'A', requested: 3000, fixed: true),
          ],
        ),
      ]).single;
      expect(_lines(plan), [
        ('A', 3000, true),
        ('B', 1000, false),
        (null, 6000, false),
      ]);
    },
  );

  test(
    'raising a worker row shrinks the rows below and never loses what was typed',
    () {
      const slots = [
        OutputAllocationSlot(demandId: 'A', requested: 800, fixed: true),
        OutputAllocationSlot(requested: 200, fixed: true),
      ];
      final smaller = planOutputAllocations([
        _row(500, candidates: [_parent('A', 1000)], slots: slots),
      ]).single;
      expect(_lines(smaller), [
        ('A', 500, true),
        (null, 0, true),
      ], reason: '产量变小：下面的条目被压到 0 先藏起来，不删');
      expect(smaller.lines.map((line) => line.requested), [800, 200]);
      // 逐键改完工申报量(先经过 1、再到 1000)：每一步都拿上一步的结果当输入，与页面一样。
      final typing = planOutputAllocations([
        _row(1, candidates: [_parent('A', 1000)], slots: _slotsFrom(smaller)),
      ]).single;
      expect(_lines(typing), [('A', 1, true), (null, 0, true)]);
      final restored = planOutputAllocations([
        _row(1000, candidates: [_parent('A', 1000)], slots: _slotsFrom(typing)),
      ]).single;
      expect(_lines(restored), [('A', 800, true), (null, 200, true)]);
      // 清空完工申报量也不丢工人定的条目。
      final cleared = planOutputAllocations([
        _row(
          null,
          candidates: [_parent('A', 1000)],
          slots: _slotsFrom(smaller),
        ),
      ]).single;
      expect(_lines(cleared), [('A', 0, true), (null, 0, true)]);
      expect(cleared.issues, isEmpty);
    },
  );

  test('only a row the worker set to 0 or cleared is dropped', () {
    final plan = planOutputAllocations([
      _row(
        10,
        candidates: [_parent('A', 20)],
        slots: const [
          OutputAllocationSlot(demandId: 'A', requested: 0, fixed: true),
          OutputAllocationSlot(fixed: true),
        ],
      ),
    ]).single;
    expect(_lines(plan), [('A', 10, false)]);
  });

  test(
    'a parked row neither submits nor raises a problem while it is hidden',
    () {
      final plan = planOutputAllocations([
        _row(
          10,
          candidates: [_parent('A', 5)],
          slots: const [
            OutputAllocationSlot(requested: 10, fixed: true),
            OutputAllocationSlot(demandId: 'gone', requested: 4, fixed: true),
            OutputAllocationSlot(demandId: 'A', requested: 9, fixed: true),
          ],
        ),
      ]).single;
      expect(_lines(plan), [
        (null, 10, true),
        ('gone', 0, true),
        ('A', 0, true),
      ]);
      expect(plan.issues, isEmpty, reason: '藏起来的条目不能拦住提交');
      expect(plan.directTotal + plan.warehouseTotal, 10);
    },
  );

  test(
    'leftover taken by a chosen warehouse row stays a suggestion on the next reflow',
    () {
      final candidates = [_parent('P1', 1000), _parent('P2', 5000)];
      final first = planOutputAllocations([
        _row(
          10000,
          candidates: candidates,
          declined: const {'P1'},
          slots: const [OutputAllocationSlot(requested: 1000, fixed: true)],
        ),
      ]).single;
      expect(_lines(first), [(null, 5000, true), ('P2', 5000, false)]);
      expect(
        first.lines.first.requested,
        1000,
        reason: '送入仓库那条顺带接下的 4000 余量不算工人要的',
      );
      final smaller = planOutputAllocations([
        _row(
          6000,
          candidates: candidates,
          declined: const {'P1'},
          slots: _slotsFrom(first),
        ),
      ]).single;
      expect(_lines(smaller), [(null, 1000, true), ('P2', 5000, false)]);
    },
  );

  test(
    'at most one warehouse row: two warehouse choices merge and it absorbs the rest',
    () {
      final plan = planOutputAllocations([
        _row(
          10,
          candidates: [_parent('A', 2)],
          slots: const [
            OutputAllocationSlot(requested: 3, fixed: true),
            OutputAllocationSlot(demandId: 'A', requested: 2, fixed: true),
            OutputAllocationSlot(requested: 1, fixed: true),
          ],
        ),
      ]).single;
      expect(_lines(plan), [(null, 8, true), ('A', 2, true)]);
    },
  );

  test(
    'the row being typed into stays even at zero and reports overflow instead of rewriting',
    () {
      final editing = planOutputAllocations([
        _row(
          10,
          candidates: [_parent('A', 20)],
          slots: const [
            OutputAllocationSlot(
              demandId: 'A',
              requested: 0,
              fixed: true,
              editing: true,
            ),
          ],
        ),
      ]).single;
      expect(_lines(editing), [('A', 0, true), (null, 10, false)]);
      final over = planOutputAllocations([
        _row(
          10,
          candidates: [_parent('A', 20)],
          slots: const [
            OutputAllocationSlot(
              demandId: 'A',
              requested: 15,
              fixed: true,
              editing: true,
            ),
          ],
        ),
      ]).single;
      expect(over.lines.first.qty, 10);
      expect(over.lines.first.issue, contains('超过本行还没分配的 10'));
    },
  );

  test(
    'rows of one report share a parent need; the same source also shares its quota',
    () {
      // 不同来源：共用上层工单还差的 100(需求 100、已备 0)；各自来源份额 60。
      final different = planOutputAllocations([
        _row(50, source: 'a', candidates: [_parent('D', 60, requiredQty: 100)]),
        _row(51, source: 'b', candidates: [_parent('D', 60, requiredQty: 100)]),
      ]);
      expect(_lines(different[0]), [('D', 50, false)]);
      expect(_lines(different[1]), [('D', 50, false), (null, 1, false)]);
      // 同一来源：两行共用本来源的 60。
      final same = planOutputAllocations([
        _row(50, candidates: [_parent('D', 60, requiredQty: 100)]),
        _row(50, candidates: [_parent('D', 60, requiredQty: 100)]),
      ]);
      expect(_lines(same[1]), [('D', 10, false), (null, 40, false)]);
      expect(same[1].roomBase['D'], 10, reason: '下拉「还差 N」已扣掉本张报工其它行');
      expect(same[0].roomBase['D'], 50);
    },
  );

  test(
    'worker allocations above what a parent still needs are flagged, not rerouted',
    () {
      final plans = planOutputAllocations([
        _row(
          60,
          source: 'a',
          candidates: [_parent('D', 60, requiredQty: 100)],
          slots: const [
            OutputAllocationSlot(demandId: 'D', requested: 60, fixed: true),
          ],
        ),
        _row(
          60,
          source: 'b',
          candidates: [_parent('D', 60, requiredQty: 100)],
          slots: const [
            OutputAllocationSlot(demandId: 'D', requested: 60, fixed: true),
          ],
        ),
      ]);
      for (final plan in plans) {
        expect(plan.lines.single.demandId, 'D');
        expect(plan.lines.single.issue, contains('ZX-D 最多还能收 40'));
      }
    },
  );

  test(
    'a chosen parent that can no longer take it keeps the choice with a reason',
    () {
      const slots = [
        OutputAllocationSlot(demandId: 'gone', requested: 4, fixed: true),
      ];
      final known = planOutputAllocations([
        _row(10, candidates: [_parent('A', 10)], slots: slots),
      ]).single;
      expect(known.lines.first.demandId, 'gone');
      expect(known.lines.first.issue, contains('现在不能收'));
      expect(_lines(known).skip(1), [('A', 6, false)]);
      // 候选读取失败：不知道能不能收，不判错、不给新的转送建议。
      final unknown = planOutputAllocations([
        _row(10, slots: slots, known: false),
      ]).single;
      expect(unknown.lines.first.issue, isNull);
      expect(_lines(unknown), [('gone', 4, true), (null, 6, false)]);
    },
  );

  test('base units follow the server rounding for every conversion', () {
    // 换算率 5：上层工单还差 150(基本单位) = 30(报工单位)。
    final five = planOutputAllocations([
      _row(40, rate: 5, candidates: [_parent('A', 150)]),
    ]).single;
    expect(_lines(five), [('A', 30, false), (null, 10, false)]);
    // 1.005 × 0.01 = 0.01005 → 四舍五入 0.0101，正好不超过还差的 0.0101。
    final tiny = planOutputAllocations([
      _row(1.005, rate: .01, candidates: [_parent('A', .0101)]),
    ]).single;
    expect(_lines(tiny), [('A', 1.005, false)]);
    expect(outputAllocationWithinRoom(9000, 1000, 1), 1000);
    expect(outputAllocationWithinRoom(3, 1000, 1), 3);
    expect(outputAllocationWithinRoom(100, 150, 5), 30);
  });

  test('a parent the worker took away is not suggested again below', () {
    final plan = planOutputAllocations([
      OutputAllocationRowInput(
        sourceKey: 'plan-item',
        quantity: 10,
        unitRate: 1,
        candidates: [_parent('A', 6), _parent('B', 3)],
        declined: const {'B'},
        slots: const [
          OutputAllocationSlot(demandId: 'A', requested: 2, fixed: true),
          OutputAllocationSlot(requested: 3, fixed: true),
        ],
      ),
    ]).single;
    expect(_lines(plan), [('A', 2, true), (null, 8, true)]);
  });

  test('suggestions stop at the per-line receiver limit', () {
    final plan = planOutputAllocations([
      _row(
        10,
        limit: 2,
        candidates: [_parent('A', 1), _parent('B', 1), _parent('C', 1)],
      ),
    ]).single;
    expect(_lines(plan), [('A', 1, false), ('B', 1, false), (null, 8, false)]);
  });

  test('quantity text drops trailing zeros', () {
    expect(outputAllocationQuantityText(10), '10');
    expect(outputAllocationQuantityText(1.5), '1.5');
    expect(outputAllocationQuantityText(0.0101), '0.0101');
  });
}
