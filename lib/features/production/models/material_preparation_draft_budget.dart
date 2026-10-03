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
}

class MaterialPreparationBudgetRow {
  const MaterialPreparationBudgetRow({
    required this.reservedSharedQty,
    required this.remainingSharedQty,
    required this.availableQty,
    required this.netShortageQty,
  });

  final double reservedSharedQty;
  final double remainingSharedQty;
  final double availableQty;
  final double netShortageQty;
}

class MaterialPreparationDraftBudget {
  const MaterialPreparationDraftBudget({
    required this.rows,
    this.inputs = const {},
    this.remainingSlices = const {},
    this.coveredReservations = const {},
  });

  final Map<String, MaterialPreparationBudgetRow> rows;
  final Map<String, MaterialPreparationBudgetLine> inputs;
  final Map<String, Map<String, int>> remainingSlices;
  final Map<String, int> coveredReservations;

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
    var reserved = 0, remaining = 0, available = 0, shortage = 0;
    for (final ids in byPool.values) {
      final free = units(rows[ids.first]!.remainingSharedQty);
      final used = ids.fold<int>(
        0,
        (sum, id) => sum + units(rows[id]!.reservedSharedQty),
      );
      final need = ids.fold<int>(
        0,
        (sum, id) => sum + units(inputs[id]!.uncoveredBeforeSharedQty),
      );
      reserved += used;
      remaining += free;
      available += free;
      final needs = {
        for (final id in ids)
          id:
              (units(inputs[id]!.uncoveredBeforeSharedQty) -
                      (coveredReservations[id] ?? 0))
                  .clamp(0, 9007199254740991),
      };
      final slices = remainingSlices[inputs[ids.first]!.poolKey];
      final gap = slices == null
          ? need - used - free
          : needs.values.fold<int>(0, (sum, value) => sum + value) -
                _allocateCoverage(
                  needs: {
                    for (final id in ids)
                      id: _cappedNeed(
                        inputs[id]!,
                        alreadyCovered: coveredReservations[id] ?? 0,
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
      shortage += gap > 0 ? gap : 0;
    }
    return MaterialPreparationBudgetRow(
      reservedSharedQty: reserved / 10000,
      remainingSharedQty: remaining / 10000,
      availableQty: available / 10000,
      netShortageQty: shortage / 10000,
    );
  }

  factory MaterialPreparationDraftBudget.project({
    required Iterable<MaterialPreparationBudgetLine> lines,
    required Map<String, double> sharedAvailableByPool,
  }) {
    // The API quantity scale is four decimals. Accumulating its integer units
    // avoids losing the final 0.0001 across many selected sources.
    double qty(int value) => value / 10000;
    final remaining = {
      for (final entry in sharedAvailableByPool.entries)
        entry.key: units(entry.value),
    };
    final byId = {for (final line in lines) line.materialLineId: line};
    final slicesByPool = <String, Map<String, int>>{};
    for (final line in byId.values) {
      if (line.supplySlices == null) continue;
      final pool = slicesByPool.putIfAbsent(line.poolKey, () => {});
      for (final slice in line.supplySlices!) {
        if (slice.key.isEmpty) continue;
        final quantity = units(slice.availableQty);
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
    final legacyCaps = <String, Set<int>>{};
    for (final line in byId.values) {
      if (line.adoptableSharedQty != null) {
        legacyCaps
            .putIfAbsent(line.poolKey, () => {})
            .add(units(line.adoptableSharedQty!));
      }
    }
    for (final entry in remaining.entries) {
      slicesByPool.putIfAbsent(entry.key, () {
        final limits = {
          entry.value,
          for (final cap in legacyCaps[entry.key] ?? const <int>{})
            cap.clamp(0, entry.value),
        }.toList()..sort();
        var previous = 0;
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
          entry.key: units(entry.value.first.requestedQty),
      },
    );
    final coveredReservations = legal.byLine;
    final reservations = Map<String, int>.from(coveredReservations);
    for (final entry in legal.bySource.entries) {
      final key = entry.key;
      slicesByPool[key.pool]![key.source] =
          slicesByPool[key.pool]![key.source]! - entry.value;
      remaining[key.pool] = (remaining[key.pool] ?? 0) - entry.value;
    }
    // Extra entered amounts still reduce the editing balance, as requested,
    // but cannot turn an ineligible/self source into demand coverage.
    for (final group in groupedInputs.values) {
      var requested =
          units(group.first.requestedQty) -
          group.fold<int>(
            0,
            (sum, line) =>
                sum + (coveredReservations[line.materialLineId] ?? 0),
          );
      for (final line in group) {
        if (requested <= 0) break;
        final slices = slicesByPool[line.poolKey]!;
        for (final key in slices.keys.toList()..sort()) {
          final free = slices[key]!;
          final take = requested < free ? requested : free;
          slices[key] = free - take;
          remaining[line.poolKey] = (remaining[line.poolKey] ?? 0) - take;
          reservations.update(
            line.materialLineId,
            (value) => value + take,
            ifAbsent: () => take,
          );
          requested -= take;
          if (requested == 0) break;
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
            final reserved = reservations[line.materialLineId] ?? 0;
            final free = remaining[line.poolKey] ?? 0;
            // uncoveredBeforeSharedQty already excludes real private coverage.
            // A selected source retains its own reservation when other rows use
            // the rest of the pool, but cannot consume another source's share.
            final ownCover = coveredReservations[line.materialLineId] ?? 0;
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
                      .fold<int>(0, (sum, entry) => sum + entry.value);
            final adoptable = ownCover + eligibleFree;
            final cap = line.adoptableSharedQty == null
                ? adoptable
                : units(line.adoptableSharedQty!);
            final coverage = adoptable < cap ? adoptable : cap;
            final uncovered = units(line.uncoveredBeforeSharedQty) - coverage;
            return MaterialPreparationBudgetRow(
              reservedSharedQty: qty(reserved),
              remainingSharedQty: qty(free),
              availableQty: qty(free),
              netShortageQty: qty(uncovered > 0 ? uncovered : 0),
            );
          })(),
      },
    );
  }

  static int units(double value) =>
      value.isFinite && value > 0 ? (value * 10000).round() : 0;
}

typedef _BudgetSupplyKey = ({String pool, String source});

int _cappedNeed(MaterialPreparationBudgetLine line, {int alreadyCovered = 0}) {
  final need =
      (MaterialPreparationDraftBudget.units(line.uncoveredBeforeSharedQty) -
              alreadyCovered)
          .clamp(0, 9007199254740991);
  final cap = line.adoptableSharedQty;
  return cap == null
      ? need
      : need.clamp(
          0,
          (MaterialPreparationDraftBudget.units(cap) - alreadyCovered).clamp(
            0,
            9007199254740991,
          ),
        );
}

Set<_BudgetSupplyKey> _eligibleKeys(
  MaterialPreparationBudgetLine line,
  Map<String, int> pool,
) => {
  for (final key
      in line.supplySlices == null
          ? pool.keys.where(
              (key) =>
                  line.adoptableSharedQty == null ||
                  (key.startsWith('legacy:') &&
                      (int.tryParse(key.substring(7)) ?? 9007199254740991) <=
                          MaterialPreparationDraftBudget.units(
                            line.adoptableSharedQty!,
                          )),
            )
          : line.supplySlices!
                .where((slice) => slice.adoptable)
                .map((slice) => slice.key))
    (pool: line.poolKey, source: key),
};

/// Exact overlap accounting with a small capacitated bipartite flow. The
/// optional input layer preserves one total for a multi-source quantity editor.
({int total, Map<String, int> byLine, Map<_BudgetSupplyKey, int> bySource})
_allocateCoverage({
  required Map<String, int> needs,
  required Map<_BudgetSupplyKey, int> supply,
  required Map<String, Set<_BudgetSupplyKey>> eligible,
  Map<String, String> inputByLine = const {},
  Map<String, int>? inputLimits,
}) {
  final demands = needs.entries.where((entry) => entry.value > 0).toList();
  final sources = supply.entries.where((entry) => entry.value > 0).toList();
  if (demands.isEmpty || sources.isEmpty) {
    return (total: 0, byLine: {}, bySource: {});
  }
  final limits = inputLimits ?? needs;
  final common = eligible[demands.first.key] ?? const <_BudgetSupplyKey>{};
  if (demands.every((demand) {
    final keys = eligible[demand.key] ?? const <_BudgetSupplyKey>{};
    return keys.length == common.length && keys.containsAll(common);
  })) {
    // Repeated BOM paths commonly have identical supply eligibility. Their
    // coverage is a simple common-pool allocation, with no graph per path.
    final groupsRemaining = Map<String, int>.from(limits);
    var free = common.fold<int>(0, (sum, key) => sum + (supply[key] ?? 0));
    var total = 0;
    final byLine = <String, int>{};
    for (final demand in demands) {
      final group = inputByLine[demand.key] ?? demand.key;
      final cap = groupsRemaining[group] ?? 0;
      final wanted = demand.value < cap ? demand.value : cap;
      final take = wanted < free ? wanted : free;
      byLine[demand.key] = take;
      groupsRemaining[group] = cap - take;
      free -= take;
      total += take;
    }
    final bySource = <_BudgetSupplyKey, int>{};
    var allocated = total;
    for (final key in common) {
      final available = supply[key] ?? 0;
      final take = allocated < available ? allocated : available;
      bySource[key] = take;
      allocated -= take;
      if (allocated == 0) break;
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
  _BudgetFlowEdge add(int from, int to, int qty) {
    final forward = _BudgetFlowEdge(to, graph[to].length, qty);
    final backward = _BudgetFlowEdge(from, graph[from].length, 0);
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
  var total = 0;
  final maximum = demands.fold<int>(0, (sum, entry) => sum + entry.value);
  while (true) {
    final levels = List.filled(graph.length, -1);
    final queue = <int>[0];
    levels[0] = 0;
    for (var head = 0; head < queue.length; head++) {
      for (final edge in graph[queue[head]]) {
        if (edge.qty <= 0 || levels[edge.to] >= 0) continue;
        levels[edge.to] = levels[queue[head]] + 1;
        queue.add(edge.to);
      }
    }
    if (levels[sink] < 0) break;
    final next = List.filled(graph.length, 0);
    int send(int node, int limit) {
      if (node == sink) return limit;
      while (next[node] < graph[node].length) {
        final edge = graph[node][next[node]];
        if (edge.qty > 0 && levels[edge.to] == levels[node] + 1) {
          final pushed = send(edge.to, edge.qty < limit ? edge.qty : limit);
          if (pushed > 0) {
            edge.qty -= pushed;
            graph[edge.to][edge.reverse].qty += pushed;
            return pushed;
          }
        }
        next[node]++;
      }
      return 0;
    }

    while (true) {
      final pushed = send(0, maximum);
      if (pushed == 0) break;
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
  int qty;
}
