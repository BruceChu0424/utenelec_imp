import 'production_exact_quantity.dart';
import 'material_preparation_supply_slice.dart';

/// A read-only budget for the current selection. Quantities already owned by a
/// source remain private; order/append inputs are new increments and reserve
/// only the shared pool. Nothing here changes persisted stock or order facts.
class MaterialPreparationBudgetLine {
  const MaterialPreparationBudgetLine({
    required this.materialLineId,
    required this.poolKey,
    required this.ownedAvailableQty,
    required this.uncoveredBeforeSharedQty,
    required this.requestedQty,
    required this.selected,
    this.useAvailableQty = true,
    this.inputKey,
    this.priority = 0,
    this.adoptableSharedQty,
    this.supplySlices,
    this.quantityFactsExact = const {},
  });

  final String materialLineId;
  final String poolKey;
  final double ownedAvailableQty;
  final double uncoveredBeforeSharedQty;
  final double requestedQty;
  final bool selected;

  /// Extra purchasing can keep the shared pool available for future demand.
  /// This choice affects draft reservations, not existing private coverage.
  final bool useAvailableQty;
  final String? inputKey;
  final int priority;
  final double? adoptableSharedQty;
  final List<MaterialPreparationSupplySlice>? supplySlices;
  final Map<String, String> quantityFactsExact;
  BigInt amount(String key) {
    final Object? legacy = switch (key) {
      'ownedAvailableQty' => ownedAvailableQty,
      'uncoveredBeforeSharedQty' => uncoveredBeforeSharedQty,
      'requestedQty' => requestedQty,
      'adoptableSharedQty' => adoptableSharedQty,
      _ => null,
    };
    return MaterialPreparationDraftBudget.units(
      quantityFactsExact[key] ?? productionExactQuantityText(legacy),
    );
  }
}

class MaterialPreparationBudgetRow {
  const MaterialPreparationBudgetRow({
    required this.reservedSharedQty,
    required this.remainingSharedQty,
    required this.availableQty,
    required this.netShortageQty,
    this.reservedSharedQtyExact,
    this.remainingSharedQtyExact,
    this.availableQtyExact,
    this.netShortageQtyExact,
  });

  final double reservedSharedQty;
  final double remainingSharedQty;
  final double availableQty;
  final double netShortageQty;
  final String? reservedSharedQtyExact,
      remainingSharedQtyExact,
      availableQtyExact,
      netShortageQtyExact;
  String? get reservedSharedQtyText =>
      productionExactQuantityText(reservedSharedQtyExact ?? reservedSharedQty);
  String? get remainingSharedQtyText => productionExactQuantityText(
    remainingSharedQtyExact ?? remainingSharedQty,
  );
  String? get availableQtyText =>
      productionExactQuantityText(availableQtyExact ?? availableQty);
  String? get netShortageQtyText =>
      productionExactQuantityText(netShortageQtyExact ?? netShortageQty);
}

class MaterialPreparationDraftBudget {
  const MaterialPreparationDraftBudget({
    required this.rows,
    this.inputs = const {},
    this.remainingSlices = const {},
    this.coveredReservations = const {},
    this.pendingReason,
  });

  final String? pendingReason;
  final Map<String, MaterialPreparationBudgetRow> rows;
  final Map<String, MaterialPreparationBudgetLine> inputs;
  final Map<String, Map<String, BigInt>> remainingSlices;
  final Map<String, BigInt> coveredReservations;

  MaterialPreparationBudgetRow summarize(Iterable<String> lineIds) {
    final uniqueIds = lineIds.toSet();
    if (uniqueIds.length == 1 && rows.containsKey(uniqueIds.single)) {
      return rows[uniqueIds.single]!;
    }
    final byPool = <String, List<String>>{};
    for (final id in uniqueIds) {
      final input = inputs[id];
      if (input != null) byPool.putIfAbsent(input.poolKey, () => []).add(id);
    }
    var reserved = BigInt.zero,
        remaining = BigInt.zero,
        available = BigInt.zero,
        shortage = BigInt.zero;
    for (final ids in byPool.values) {
      final free = units(rows[ids.first]!.remainingSharedQtyText);
      final used = ids.fold<BigInt>(
        BigInt.zero,
        (sum, id) => sum + units(rows[id]!.reservedSharedQtyText),
      );
      final need = ids.fold<BigInt>(
        BigInt.zero,
        (sum, id) => sum + inputs[id]!.amount('uncoveredBeforeSharedQty'),
      );
      reserved += used;
      remaining += free;
      available += free;
      final needs = {
        for (final id in ids)
          id: _positive(
            inputs[id]!.amount('uncoveredBeforeSharedQty') -
                (coveredReservations[id] ?? BigInt.zero),
          ),
      };
      final slices = remainingSlices[inputs[ids.first]!.poolKey];
      final gap = slices == null
          ? need - used - free
          : needs.values.fold<BigInt>(
                  BigInt.zero,
                  (sum, value) => sum + value,
                ) -
                _allocateCoverage(
                  needs: {
                    for (final id in ids)
                      id: _cappedNeed(
                        inputs[id]!,
                        alreadyCovered: coveredReservations[id] ?? BigInt.zero,
                      ),
                  },
                  supply: {
                    for (final source in slices.entries)
                      (pool: inputs[ids.first]!.poolKey, source: source.key):
                          source.value,
                  },
                  eligible: {
                    for (final id in ids)
                      id: _eligibleKeys(inputs[id]!, slices),
                  },
                ).total;
      shortage += _positive(gap);
    }
    return MaterialPreparationBudgetRow(
      reservedSharedQty: _qty(reserved),
      reservedSharedQtyExact: _text(reserved),
      remainingSharedQty: _qty(remaining),
      remainingSharedQtyExact: _text(remaining),
      availableQty: _qty(available),
      availableQtyExact: _text(available),
      netShortageQty: _qty(shortage),
      netShortageQtyExact: _text(shortage),
    );
  }

  factory MaterialPreparationDraftBudget.project({
    required Iterable<MaterialPreparationBudgetLine> lines,
    required Map<String, double> sharedAvailableByPool,
    Map<String, String> sharedAvailableExactByPool = const {},
  }) {
    final captured = lines.toList(growable: false);
    try {
      return _project(
        lines: captured,
        sharedAvailableByPool: sharedAvailableByPool,
        sharedAvailableExactByPool: sharedAvailableExactByPool,
      );
    } on FormatException catch (error) {
      return MaterialPreparationDraftBudget(
        rows: const {},
        pendingReason: error.message,
        inputs: {for (final line in captured) line.materialLineId: line},
      );
    }
  }
  static MaterialPreparationDraftBudget _project({
    required Iterable<MaterialPreparationBudgetLine> lines,
    required Map<String, double> sharedAvailableByPool,
    required Map<String, String> sharedAvailableExactByPool,
  }) {
    // Every edge/capacity keeps full 24-place units, including on JavaScript.
    // Node IDs and traversal levels remain discrete ints; no business amount is rounded.
    double qty(BigInt value) => _qty(value);
    final remaining = {
      for (final entry in sharedAvailableByPool.entries)
        entry.key: units(
          sharedAvailableExactByPool[entry.key] ??
              productionExactQuantityText(entry.value),
        ),
    };
    final byId = {for (final line in lines) line.materialLineId: line};
    final slicesByPool = <String, Map<String, BigInt>>{};
    for (final line in byId.values) {
      if (line.supplySlices == null) continue;
      final pool = slicesByPool.putIfAbsent(line.poolKey, () => {});
      for (final slice in line.supplySlices!) {
        if (slice.key.isEmpty) continue;
        final quantity = units(slice.availableQtyText);
        pool.update(
          slice.key,
          (old) => old < quantity ? old : quantity,
          ifAbsent: () => quantity,
        );
      }
    }
    final ordered = byId.values.toList()
      ..sort((left, right) {
        final priority = left.priority.compareTo(right.priority);
        return priority != 0
            ? priority
            : left.materialLineId.compareTo(right.materialLineId);
      });
    // Old servers have no source proof. Nested anonymous capacity tiers give a
    // conservative overlap bound when only per-row caps are available; caps
    // never prove that two rows can consume separate underlying sources.
    final legacyCaps = <String, Set<BigInt>>{};
    for (final line in byId.values) {
      if (line.adoptableSharedQty != null) {
        legacyCaps
            .putIfAbsent(line.poolKey, () => {})
            .add(line.amount('adoptableSharedQty'));
      }
    }
    for (final entry in remaining.entries) {
      slicesByPool.putIfAbsent(entry.key, () {
        final limits = {
          entry.value,
          for (final cap in legacyCaps[entry.key] ?? const <BigInt>{})
            _min(_positive(cap), entry.value),
        }.toList()..sort();
        var previous = BigInt.zero;
        return {
          for (final limit in limits)
            'legacy:$limit': (() {
              final amount = limit - previous;
              previous = limit;
              return amount;
            })(),
        };
      });
    }
    final groupedInputs = <String, List<MaterialPreparationBudgetLine>>{};
    for (final line in ordered.where(
      (line) => line.selected && line.useAvailableQty,
    )) {
      groupedInputs
          .putIfAbsent(line.inputKey ?? line.materialLineId, () => [])
          .add(line);
    }
    final selected = [for (final group in groupedInputs.values) ...group];
    final legal = _allocateCoverage(
      needs: {
        for (final line in selected) line.materialLineId: _cappedNeed(line),
      },
      supply: {
        for (final pool in slicesByPool.entries)
          for (final source in pool.value.entries)
            (pool: pool.key, source: source.key): source.value,
      },
      eligible: {
        for (final line in selected)
          line.materialLineId: _eligibleKeys(line, slicesByPool[line.poolKey]!),
      },
      inputByLine: {
        for (final line in selected)
          line.materialLineId: line.inputKey ?? line.materialLineId,
      },
      inputLimits: {
        for (final entry in groupedInputs.entries)
          entry.key: entry.value.first.amount('requestedQty'),
      },
    );
    final coveredReservations = legal.byLine;
    final reservations = Map<String, BigInt>.from(coveredReservations);
    for (final entry in legal.bySource.entries) {
      final key = entry.key;
      slicesByPool[key.pool]![key.source] =
          slicesByPool[key.pool]![key.source]! - entry.value;
      remaining[key.pool] = (remaining[key.pool] ?? BigInt.zero) - entry.value;
    }
    // Extra entered amounts still reduce the editing balance, as requested,
    // but cannot turn an ineligible/self source into demand coverage.
    for (final group in groupedInputs.values) {
      var requested =
          group.first.amount('requestedQty') -
          group.fold<BigInt>(
            BigInt.zero,
            (sum, line) =>
                sum + (coveredReservations[line.materialLineId] ?? BigInt.zero),
          );
      for (final line in group) {
        if (requested <= BigInt.zero) break;
        final slices = slicesByPool[line.poolKey]!;
        for (final key in slices.keys.toList()..sort()) {
          final free = slices[key]!;
          final take = requested < free ? requested : free;
          slices[key] = free - take;
          remaining[line.poolKey] =
              (remaining[line.poolKey] ?? BigInt.zero) - take;
          reservations.update(
            line.materialLineId,
            (value) => value + take,
            ifAbsent: () => take,
          );
          requested -= take;
          if (requested == BigInt.zero) break;
        }
      }
    }
    return MaterialPreparationDraftBudget(
      inputs: byId,
      remainingSlices: slicesByPool,
      coveredReservations: coveredReservations,
      rows: {
        for (final line in ordered)
          line.materialLineId: (() {
            final reserved = reservations[line.materialLineId] ?? BigInt.zero;
            final free = remaining[line.poolKey] ?? BigInt.zero;
            // uncoveredBeforeSharedQty already excludes real private coverage.
            // A selected source retains its own reservation when other rows use
            // the rest of the pool, but cannot consume another source's share.
            final ownCover =
                coveredReservations[line.materialLineId] ?? BigInt.zero;
            final slices = slicesByPool[line.poolKey];
            final allowed = slices == null
                ? const <_BudgetSupplyKey>{}
                : _eligibleKeys(line, slices);
            final eligibleFree = slices == null
                ? free
                : slices.entries
                      .where(
                        (entry) => allowed.contains((
                          pool: line.poolKey,
                          source: entry.key,
                        )),
                      )
                      .fold<BigInt>(
                        BigInt.zero,
                        (sum, entry) => sum + entry.value,
                      );
            final adoptable = ownCover + eligibleFree;
            final cap = line.adoptableSharedQty == null
                ? adoptable
                : line.amount('adoptableSharedQty');
            final coverage = adoptable < cap ? adoptable : cap;
            final uncovered =
                line.amount('uncoveredBeforeSharedQty') - coverage;
            return MaterialPreparationBudgetRow(
              reservedSharedQty: qty(reserved),
              remainingSharedQty: qty(free),
              availableQty: qty(free),
              netShortageQty: qty(_positive(uncovered)),
              reservedSharedQtyExact: _text(reserved),
              remainingSharedQtyExact: _text(free),
              availableQtyExact: _text(free),
              netShortageQtyExact: _text(_positive(uncovered)),
            );
          })(),
      },
    );
  }

  static BigInt units(Object? value) {
    final exact = productionExactQuantityUnits(value);
    if (exact == null) throw const FormatException('备料数量缺少完整原值，请重新读取来源；原输入已保留');
    return exact;
  }
}

typedef _BudgetSupplyKey = ({String pool, String source});

BigInt _cappedNeed(
  MaterialPreparationBudgetLine line, {
  BigInt? alreadyCovered,
}) {
  final used = alreadyCovered ?? BigInt.zero;
  final need = _positive(line.amount('uncoveredBeforeSharedQty') - used);
  return line.adoptableSharedQty == null
      ? need
      : _min(need, _positive(line.amount('adoptableSharedQty') - used));
}

Set<_BudgetSupplyKey> _eligibleKeys(
  MaterialPreparationBudgetLine line,
  Map<String, BigInt> pool,
) => {
  for (final key
      in line.supplySlices == null
          ? pool.keys.where(
              (key) =>
                  line.adoptableSharedQty == null ||
                  (key.startsWith('legacy:') &&
                      (BigInt.tryParse(key.substring(7)) ??
                              BigInt.from(10).pow(100)) <=
                          line.amount('adoptableSharedQty')),
            )
          : line.supplySlices!
                .where((slice) => slice.adoptable)
                .map((slice) => slice.key))
    (pool: line.poolKey, source: key),
};

/// Exact overlap accounting with a small capacitated bipartite flow. The
/// optional input layer preserves one total for a multi-source quantity editor.
({
  BigInt total,
  Map<String, BigInt> byLine,
  Map<_BudgetSupplyKey, BigInt> bySource,
})
_allocateCoverage({
  required Map<String, BigInt> needs,
  required Map<_BudgetSupplyKey, BigInt> supply,
  required Map<String, Set<_BudgetSupplyKey>> eligible,
  Map<String, String> inputByLine = const {},
  Map<String, BigInt>? inputLimits,
}) {
  final demands = needs.entries
      .where((entry) => entry.value > BigInt.zero)
      .toList();
  final sources = supply.entries
      .where((entry) => entry.value > BigInt.zero)
      .toList();
  if (demands.isEmpty || sources.isEmpty) {
    return (total: BigInt.zero, byLine: {}, bySource: {});
  }
  final limits = inputLimits ?? needs;
  final common = eligible[demands.first.key] ?? const <_BudgetSupplyKey>{};
  if (demands.every((demand) {
    final keys = eligible[demand.key] ?? const <_BudgetSupplyKey>{};
    return keys.length == common.length && keys.containsAll(common);
  })) {
    // Repeated BOM paths commonly have identical supply eligibility. Their
    // coverage is a simple common-pool allocation, with no graph per path.
    final groupsRemaining = Map<String, BigInt>.from(limits);
    var free = common.fold<BigInt>(
      BigInt.zero,
      (sum, key) => sum + (supply[key] ?? BigInt.zero),
    );
    var total = BigInt.zero;
    final byLine = <String, BigInt>{};
    for (final demand in demands) {
      final group = inputByLine[demand.key] ?? demand.key;
      final cap = groupsRemaining[group] ?? BigInt.zero;
      final wanted = demand.value < cap ? demand.value : cap;
      final take = wanted < free ? wanted : free;
      byLine[demand.key] = take;
      groupsRemaining[group] = cap - take;
      free -= take;
      total += take;
    }
    final bySource = <_BudgetSupplyKey, BigInt>{};
    var allocated = total;
    for (final key in common) {
      final available = supply[key] ?? BigInt.zero;
      final take = allocated < available ? allocated : available;
      bySource[key] = take;
      allocated -= take;
      if (allocated == BigInt.zero) break;
    }
    return (total: total, byLine: byLine, bySource: bySource);
  }
  final groupKeys = limits.keys.toList();
  final groupIndex = {
    for (var i = 0; i < groupKeys.length; i++) groupKeys[i]: 1 + i,
  };
  final demandStart = 1 + groupKeys.length;
  final supplyStart = demandStart + demands.length;
  final sourceIndex = {
    for (var i = 0; i < sources.length; i++) sources[i].key: i,
  };
  final sink = supplyStart + sources.length;
  final graph = List.generate(sink + 1, (_) => <_BudgetFlowEdge>[]);
  _BudgetFlowEdge add(int from, int to, BigInt qty) {
    final forward = _BudgetFlowEdge(to, graph[to].length, qty);
    final backward = _BudgetFlowEdge(from, graph[from].length, BigInt.zero);
    graph[from].add(forward);
    graph[to].add(backward);
    return forward;
  }

  for (final key in groupKeys) {
    add(0, groupIndex[key]!, limits[key]!);
  }
  final lineEdges = <String, _BudgetFlowEdge>{};
  for (var i = 0; i < demands.length; i++) {
    final demand = demands[i];
    lineEdges[demand.key] = add(
      groupIndex[inputByLine[demand.key] ?? demand.key]!,
      demandStart + i,
      demand.value,
    );
    final allowed = eligible[demand.key] ?? const <_BudgetSupplyKey>{};
    for (final key in allowed) {
      final j = sourceIndex[key];
      if (j != null) add(demandStart + i, supplyStart + j, demand.value);
    }
  }
  final sourceEdges = <_BudgetSupplyKey, _BudgetFlowEdge>{};
  for (var j = 0; j < sources.length; j++) {
    sourceEdges[sources[j].key] = add(supplyStart + j, sink, sources[j].value);
  }
  var total = BigInt.zero;
  final maximum = demands.fold<BigInt>(
    BigInt.zero,
    (sum, entry) => sum + entry.value,
  );
  while (true) {
    final levels = List.filled(graph.length, -1);
    final queue = <int>[0];
    levels[0] = 0;
    for (var head = 0; head < queue.length; head++) {
      for (final edge in graph[queue[head]]) {
        if (edge.qty <= BigInt.zero || levels[edge.to] >= 0) continue;
        levels[edge.to] = levels[queue[head]] + 1;
        queue.add(edge.to);
      }
    }
    if (levels[sink] < 0) break;
    final next = List.filled(graph.length, 0);
    BigInt send(int node, BigInt limit) {
      if (node == sink) return limit;
      while (next[node] < graph[node].length) {
        final edge = graph[node][next[node]];
        if (edge.qty > BigInt.zero && levels[edge.to] == levels[node] + 1) {
          final pushed = send(edge.to, edge.qty < limit ? edge.qty : limit);
          if (pushed > BigInt.zero) {
            edge.qty -= pushed;
            graph[edge.to][edge.reverse].qty += pushed;
            return pushed;
          }
        }
        next[node]++;
      }
      return BigInt.zero;
    }

    while (true) {
      final pushed = send(0, maximum);
      if (pushed == BigInt.zero) break;
      total += pushed;
    }
  }
  return (
    total: total,
    byLine: {
      for (final entry in lineEdges.entries)
        entry.key: needs[entry.key]! - entry.value.qty,
    },
    bySource: {
      for (final entry in sourceEdges.entries)
        entry.key: supply[entry.key]! - entry.value.qty,
    },
  );
}

class _BudgetFlowEdge {
  _BudgetFlowEdge(this.to, this.reverse, this.qty);
  final int to, reverse;
  BigInt qty;
}

BigInt _positive(BigInt value) => value.isNegative ? BigInt.zero : value;
BigInt _min(BigInt left, BigInt right) => left < right ? left : right;
String _text(BigInt value) => productionQuantityTextFromUnits(value);
double _qty(BigInt value) => double.parse(_text(value));
