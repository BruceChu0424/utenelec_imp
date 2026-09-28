// 报工「去向分配」的唯一计算(V736/ADR-127)：一行报工的实际产量逐个分给上层工单(先急后缓)，
// 剩下的送入仓库；工人可改任一条的去向与数量，系统把余量重新排到下面，合计始终等于实际产量。
//
// 纯函数、无界面依赖：报工页的去向子行、下拉里的「还差 N / 已分满」、提交前的问题清单都读这里。
// 能不能送、每个上层工单还能收多少只由服务端给出(候选接口，fn_workshop_direct_targets)；
// 这里只做「同一张报工里多行之间扣减」这一件算术(替代原来的跨行合计校验)。
import '../../../shared/formatters/exact_decimal.dart';
import 'production_direct_transfer_candidate.dart';

/// 数量精度：四位小数，全部按「万分之一」整数计算，避免浮点误差。
const int _scale = 10000;

int _ticks(double value) => (value * _scale).round();
double _value(int ticks) => ticks / _scale;

/// 报工单位数量 × 换算率 → 基本单位(与服务端同一舍入：四位小数)。
int _baseTicks(int ticks, double rate) {
  if (ticks <= 0) return 0;
  final units = financeExactProductUnits(
    outputAllocationQuantityText(_value(ticks)),
    rate.toString(),
  );
  return units == null ? (ticks * rate).round() : units.toInt();
}

/// 基本单位上限 → 报工单位最多能分多少(向下取，保证换算后不超)。
int _reportTicksWithin(int baseTicks, double rate) {
  if (baseTicks <= 0 || !rate.isFinite || rate <= 0) return 0;
  var ticks = (baseTicks / rate).floor();
  while (ticks > 0 && _baseTicks(ticks, rate) > baseTicks) {
    ticks--;
  }
  return ticks;
}

/// 数量文本：整数不带小数点，小数最多 4 位且不留尾零(与全站数量显示同口径)。
String outputAllocationQuantityText(double value) =>
    value == value.roundToDouble()
    ? value.toStringAsFixed(0)
    : value
          .toStringAsFixed(4)
          .replaceFirst(RegExp(r'0+$'), '')
          .replaceFirst(RegExp(r'\.$'), '');

/// 一条已有的去向(工人亲手定过的叫「固定」；其余是系统建议，每次重排都会重新给出)。
class OutputAllocationSlot {
  const OutputAllocationSlot({
    this.demandId,
    this.requested,
    this.fixed = false,
    this.editing = false,
  });

  /// 转给哪条上层工单的物料需求；null = 送入仓库。
  final String? demandId;

  /// 固定行工人要的数量(报工单位)。产量变小时显示值会被压低(压到 0 就先藏起来)，这个数不丢。
  final double? requested;
  final bool fixed;

  /// 正在输入数量的那一条：不删、不改它的文字，只按它算下面的余量。
  final bool editing;
}

/// 一行报工的重排输入。
class OutputAllocationRowInput {
  const OutputAllocationRowInput({
    required this.sourceKey,
    required this.quantity,
    required this.unitRate,
    required this.candidates,
    required this.slots,
    this.candidatesKnown = true,
    this.declined = const {},
    this.receiverLimit = 1 << 30,
  });

  /// 同一计划行拆出的工单共用「本来源最多可送」：计划行 id(没有时用工单 id)。
  final String sourceKey;

  /// 本行实际产量(报工单位)；空或不大于 0 时不分配。
  final double? quantity;
  final double unitRate;

  /// 服务端给的可送上层工单，已按先急后缓排好。
  final List<ProductionDirectTransferCandidate> candidates;
  final List<OutputAllocationSlot> slots;

  /// 候选读取失败时为 false：不给新的转送建议，也不把工人定过的转送判成「不能收」。
  final bool candidatesKnown;

  /// 工人在本行亲手改掉过的上层工单：不再自动建议给它(要给还可以在下拉里再选)。
  final Set<String> declined;

  /// 一行最多同时转给几个上层工单(服务端同一个常量)。
  final int receiverLimit;
}

/// 重排后的一条去向。
class OutputAllocationLine {
  const OutputAllocationLine({
    required this.demandId,
    required this.qty,
    required this.fixed,
    this.requested,
    this.slotIndex,
    this.issue,
  });

  final String? demandId;

  /// 实际分到的数量(报工单位)。0 = 固定条目被本行产量压没了：先藏起来、不提交，产量回升时原样回来。
  final double qty;
  final bool fixed;

  /// 固定条目工人自己要的数量(报工单位)：只算工人填的，不含本条顺带接下的余量
  /// (余量每次重排重新分配)。系统建议条目为 null。
  final double? requested;

  /// 来自第几条输入(复用它的输入框)；null = 新给出的建议行。
  final int? slotIndex;

  /// 这一条的问题(红框 + 提交时列出)；null = 没问题。
  final String? issue;

  bool get isWarehouse => demandId == null;
}

/// 一行报工的重排结果。
class OutputAllocationRowPlan {
  const OutputAllocationRowPlan({required this.lines, required this.roomBase});

  final List<OutputAllocationLine> lines;

  /// 每个可送上层工单：本行最多还能分给它多少(基本单位，已扣掉本张报工其它行分给它的)。
  /// 下拉显示「还差 N」，不大于 0 即「已分满」。
  final Map<String, double> roomBase;

  double get directTotal => lines
      .where((line) => !line.isWarehouse)
      .fold(0.0, (sum, line) => sum + line.qty);
  double get warehouseTotal => lines
      .where((line) => line.isWarehouse)
      .fold(0.0, (sum, line) => sum + line.qty);
  List<String> get issues => [
    for (final line in lines)
      if (line.issue != null) line.issue!,
  ];
}

class _Line {
  _Line(this.demandId, this.ticks, this.fixed, this.slotIndex, this.editing);
  final String? demandId;
  int ticks;
  final bool fixed;
  final int? slotIndex;
  final bool editing;
  String? issue;

  /// 固定条目工人自己要的数量(合并的同去向条目相加)；第 3 步接下的余量不算在内。
  int requestedTicks = 0;
}

/// 一张报工全部行一起重排：先扣所有固定行，再按行序给每行补建议行(先急后缓逐个分满)，
/// 最后剩下的送入仓库。多行投给同一个上层工单时共用它「还差多少」。
List<OutputAllocationRowPlan> planOutputAllocations(
  List<OutputAllocationRowInput> rows,
) {
  final lines = <List<_Line>>[];
  final remaining = <int>[];
  // 1) 每行的固定行：按顺序在本行产量内压低(不丢工人填的原数；压到 0 的留着、等产量回升)，
  //    工人自己填 0 或清空的删掉(正在输入的除外)，同一去向合并成一条。
  for (final row in rows) {
    final quantity = row.quantity;
    var available = quantity == null || !quantity.isFinite || quantity <= 0
        ? 0
        : _ticks(quantity);
    final kept = <_Line>[];
    for (var index = 0; index < row.slots.length; index++) {
      final slot = row.slots[index];
      if (!slot.fixed) continue;
      final requested = slot.requested;
      final wanted = requested == null || !requested.isFinite || requested <= 0
          ? 0
          : _ticks(requested);
      final ticks = wanted < available ? wanted : available;
      if (wanted <= 0 && !slot.editing) continue;
      final same = kept.where((line) => line.demandId == slot.demandId);
      if (same.isNotEmpty && !slot.editing && !same.first.editing) {
        same.first
          ..ticks += ticks
          ..requestedTicks += wanted;
      } else {
        kept.add(
          _Line(slot.demandId, ticks, true, index, slot.editing)
            ..requestedTicks = wanted,
        );
      }
      available -= ticks;
      if (slot.editing && wanted > ticks) {
        kept.last.issue =
            '超过本行还没分配的 ${outputAllocationQuantityText(_value(ticks))}';
      }
    }
    lines.add(kept);
    remaining.add(available);
  }

  // 2) 全部固定行对每个上层工单(及同一来源)的占用。
  final fixedAll = <String, int>{};
  final fixedSame = <String, int>{};
  for (var r = 0; r < rows.length; r++) {
    for (final line in lines[r]) {
      final demand = line.demandId;
      if (demand == null) continue;
      final base = _baseTicks(line.ticks, rows[r].unitRate);
      fixedAll[demand] = (fixedAll[demand] ?? 0) + base;
      final key = '${rows[r].sourceKey}|$demand';
      fixedSame[key] = (fixedSame[key] ?? 0) + base;
    }
  }

  int shortfallOf(ProductionDirectTransferCandidate candidate) =>
      candidate.requiredQty > 0 && candidate.requiredQty.isFinite
      ? _ticks(candidate.requiredQty - candidate.alreadyCoveredQty)
      : 1 << 52;

  // 3) 按行序给建议行：跳过本行已固定的工单，逐个取「本行还能分给它的」与余量的较小值。
  final takenAll = <String, int>{};
  final takenSame = <String, int>{};
  for (var r = 0; r < rows.length; r++) {
    final row = rows[r];
    var available = remaining[r];
    final used = {
      for (final line in lines[r])
        if (line.demandId != null) line.demandId!,
    };
    var receivers = used.length;
    for (final candidate
        in row.candidatesKnown
            ? row.candidates
            : const <ProductionDirectTransferCandidate>[]) {
      if (available <= 0 || receivers >= row.receiverLimit) break;
      final demand = candidate.demandId;
      if (used.contains(demand) || row.declined.contains(demand)) continue;
      final key = '${row.sourceKey}|$demand';
      final roomAll =
          shortfallOf(candidate) -
          (fixedAll[demand] ?? 0) -
          (takenAll[demand] ?? 0);
      final roomSame =
          _ticks(candidate.remainingQty) -
          (fixedSame[key] ?? 0) -
          (takenSame[key] ?? 0);
      final room = _reportTicksWithin(
        roomAll < roomSame ? roomAll : roomSame,
        row.unitRate,
      );
      if (room <= 0) continue;
      final ticks = available < room ? available : room;
      lines[r].add(_Line(demand, ticks, false, null, false));
      used.add(demand);
      receivers++;
      available -= ticks;
      final base = _baseTicks(ticks, row.unitRate);
      takenAll[demand] = (takenAll[demand] ?? 0) + base;
      takenSame[key] = (takenSame[key] ?? 0) + base;
    }
    if (available > 0) {
      // 余量并进已有的送入仓库那一条(一行只留一条)；正在输入的那条不去动它的文字。
      final warehouse = lines[r].where(
        (line) => line.demandId == null && !line.editing,
      );
      if (warehouse.isNotEmpty) {
        warehouse.first.ticks += available;
      } else {
        lines[r].add(_Line(null, available, false, null, false));
      }
    }
  }

  // 4) 固定行超出上层工单还能收的量、或所投工单已不能收：标出问题，不替人改
  //    (被产量压到 0、先藏起来的条目不提交，也不报问题)。
  final totalAll = <String, int>{};
  final totalSame = <String, int>{};
  for (var r = 0; r < rows.length; r++) {
    for (final line in lines[r]) {
      final demand = line.demandId;
      if (demand == null) continue;
      final base = _baseTicks(line.ticks, rows[r].unitRate);
      totalAll[demand] = (totalAll[demand] ?? 0) + base;
      final key = '${rows[r].sourceKey}|$demand';
      totalSame[key] = (totalSame[key] ?? 0) + base;
    }
  }
  final plans = <OutputAllocationRowPlan>[];
  for (var r = 0; r < rows.length; r++) {
    final row = rows[r];
    final byDemand = {
      for (final candidate in row.candidates) candidate.demandId: candidate,
    };
    final rowAll = <String, int>{};
    for (final line in lines[r]) {
      if (line.demandId == null) continue;
      rowAll[line.demandId!] =
          (rowAll[line.demandId!] ?? 0) + _baseTicks(line.ticks, row.unitRate);
    }
    final room = <String, double>{};
    for (final candidate in row.candidates) {
      final demand = candidate.demandId;
      final key = '${row.sourceKey}|$demand';
      final own = rowAll[demand] ?? 0;
      final others = (totalAll[demand] ?? 0) - own;
      final othersSame = (totalSame[key] ?? 0) - own;
      final all = shortfallOf(candidate) - others;
      final same = _ticks(candidate.remainingQty) - othersSame;
      room[demand] = _value(all < same ? all : same);
    }
    for (final line in lines[r]) {
      final demand = line.demandId;
      if (demand == null ||
          !line.fixed ||
          line.issue != null ||
          line.ticks <= 0) {
        continue;
      }
      final candidate = byDemand[demand];
      if (candidate == null) {
        if (row.candidatesKnown) line.issue = '原来选的上层工单现在不能收，请重新选择去向';
        continue;
      }
      final cap = _ticks(room[demand] ?? 0);
      if (_baseTicks(line.ticks, row.unitRate) > cap) {
        line.issue =
            '${candidate.executionSegmentCode ?? '这个上层工单'} 最多还能收 '
            '${outputAllocationQuantityText(_value(cap < 0 ? 0 : cap))}'
            '${candidate.unitName == null ? '' : ' ${candidate.unitName}'}';
      }
    }
    plans.add(
      OutputAllocationRowPlan(
        lines: [
          for (final line in lines[r])
            OutputAllocationLine(
              demandId: line.demandId,
              qty: _value(line.ticks),
              fixed: line.fixed,
              requested: line.fixed ? _value(line.requestedTicks) : null,
              slotIndex: line.slotIndex,
              issue: line.issue,
            ),
        ],
        roomBase: room,
      ),
    );
  }
  return plans;
}

/// 改成转给某个上层工单时本条最多保留多少(报工单位)：原数量与它还能收的量取小。
double outputAllocationWithinRoom(
  double current,
  double roomBase,
  double rate,
) {
  final room = _reportTicksWithin(_ticks(roomBase), rate);
  final ticks = _ticks(current);
  return _value(ticks < room ? ticks : room);
}
