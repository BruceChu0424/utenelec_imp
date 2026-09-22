/// 「父改子跟」的换算与判断：物料分析里唯一一份数量联动算法。
///
/// 这份文件**不依赖 Flutter、不认识任何页面的行对象**，只认「服务端给的三个数 +
/// 用户亲手填的那个数」。级联页(父件 + 下层一起下单)与物料分析主表用的是同一份，
/// 避免两边各写一套再各踩一遍坑——2026-09-21/22 那一轮里，同一条规则在两个页面
/// 写了两遍，结果一个页面修好了另一个还错着。
///
/// 六条口径(用户 2026-09-21 第九轮原话)：
/// 1. 父行改大，没手工改过的子层跟着变大；
/// 2. 同一次编辑里改回去(还没下单)，子层原路回落——包括用退格一位一位改数；
/// 3. 手工改过的行不跟父行走，它下面那一支也跟着它不动；
/// 4. 只要没亲手填过就永远保持跟随；清空输入框 = 交还系统算(误触可复位)；
/// 5. 子件已下单的量要抵扣(这一条由服务端的「还需安排」给出，本文件只负责传导)；
/// 6. 追加(还需安排为 0 那种)填在中间层同样要带动它的子层。
library;

/// 服务端那份快照里，这一行的三个数。
typedef CascadeServerQty = ({
  /// 本批需求(毛量)。
  double required,

  /// 还需安排 = 本批缺口 − 有效在途覆盖。子层跟的是这个**净产出**，不是毛需求：
  /// 服务端 `parentPlannedOutput` 从 `shortageQty`(需求扣已分配现货)起算再扣在途，
  /// 这一行有现货覆盖时两者差着一个覆盖量。
  double residual,

  /// 建议下单量：还需安排量，采购行再按起订量 / 订货倍数向上抬过一次。
  double suggested,
});

/// 换算一行时的输入。
typedef CascadeScaleInput = ({
  /// 提交单元键(同一操作组在树里可能出现多行，只有第一行持有输入框)。
  String key,

  /// 相对树顶的层级，**必须是未经投影的全量前序**：屏幕上相邻不等于树上父子。
  int depth,

  /// 这一行有没有输入框(没有的行只作层级上下文，把父行的比例原样传下去)。
  bool ownsInput,

  /// 服务端那份快照给的三个数。
  CascadeServerQty server,

  /// 用户**亲手填**的那个数；null = 从没填过(或已清空 = 交还系统算)。
  double? userTyped,

  /// 这一行在当前这份服务端快照里按的产出量：换算它下面那一层时当分母。
  /// null = 算不出比例(快照里它是 0)，那一支整个交给服务端。
  double? baselineOutput,
});

/// 换算一行的结果。
typedef CascadeScaleResult = ({
  /// 这一行在传进来的前序列表里的下标：调用方按它把结果写回自己的行对象，
  /// 不要按 key 匹配——同一提交单元在树里可能出现多行。
  int index,
  String key,

  /// 换算后本行该显示的需求量与还需安排量。
  CascadeServerQty scaled,

  /// 换算后输入框里该写的数(没有输入框的行为 null)。
  double? displayQty,
});

/// 本行此刻该显示的下单量。
///
/// 没亲手填过就跟服务端(或换算出来)的建议量走；填过的取「用户填的数」与
/// 「还需安排」的大者——父行的需求涨过它时抬上去，父行再改小又退回用户自己填的
/// 那个数，不会停在替他抬上去的值上。
double cascadeFollowUpQty({
  required CascadeServerQty server,
  required double? userTyped,
}) {
  if (userTyped == null) return server.suggested;
  return userTyped > server.residual ? userTyped : server.residual;
}

/// 这一行在**当前这份服务端快照**里按的产出量：换算它下面那一层时当分母。
///
/// 就是它此刻显示的下单量——手工填过的行按他填的数产出，没填过的按系统建议量
/// 产出。用 `server.residual` 当分母是错的：手工填过 3000 的行，它的子树是按
/// 3000 铺开的，拿 1000 当分母会让子树跟着父行多涨两倍。
double cascadeBaselineOf({
  required CascadeServerQty server,
  required double? userTyped,
}) => cascadeFollowUpQty(server: server, userTyped: userTyped);

/// 这一行的计划产出量 = 已下达的 + 本次框里该显示的数。
///
/// 服务端同款：「已下达计划量 + 本次填的量，再与需求取大」——需求那一项在
/// [CascadeServerQty.residual] 里已经扣掉了已下达覆盖的部分，所以
/// `committed + max(typed, residual)` 与它逐字相等。用此刻填的数算是分子，
/// 用快照当时填的数算就是分母([CascadeScaleInput.baselineOutput])。
double cascadePlannedOutput({
  required double committedOutput,
  required CascadeServerQty server,
  required double? userTyped,
}) =>
    committedOutput + cascadeFollowUpQty(server: server, userTyped: userTyped);

/// 按父行的新产出量换算本行：[factor] = 父行现在的产出量 ÷ 服务端那份快照当时的。
///
/// **一律从服务端值重算，不在上一次换算结果上再乘**：用户是一位一位退格改数的
/// (2000 → 200 → 20 → 2 → 空 → 1 → 10 → 100 → 1000)，逐拍相乘时空框那一拍没有
/// 比例可算，丢掉的那一档再也补不回来，最后父件回到 1000 而子层还停在 2000。
/// 从快照重算是幂等的：中间怎么敲都不影响最终值。
///
/// 已被现货 / 在途 / 已下达覆盖的那部分是不变量，只有需求等比例放大缩小。
CascadeServerQty cascadeScaleOne(CascadeServerQty server, double factor) {
  final covered = server.required - server.residual;
  final required = server.required * factor;
  final rest = required - covered;
  final residual = rest > 0 ? rest : 0.0;
  return (required: required, residual: residual, suggested: residual);
}

/// 算这一层传给下一层的比例。分母恒取**服务端那份快照当时按的数**。
/// 算不出(分母是 0 或本次产出非正)时返回 null —— 那一支交给服务端重算。
double? cascadeFactor({
  required double? baselineOutput,
  required double output,
}) {
  if (baselineOutput == null || baselineOutput <= 0.0001) return null;
  if (!output.isFinite || output < 0) return null;
  return output / baselineOutput;
}

/// 把 [rootIndex] 那一行的变化传导到它下面的每一层。
///
/// 每一层按**它自己那个父行**的变化比例走，不是一路套用树顶的比例：手工改过的行
/// 的下单量不跟父行走(比例恒为 1)，于是它下面那一支天然跟着它不动 —— 这正是口径
/// 第三条。比例算不出的那一支整个跳过，交给服务端。
///
/// [preorder] 必须是未经投影的全量前序列表。返回值只含**真的被换算到**的行。
///
/// [committedOutput]：各行(按 key)**已经下达 / 在途**的产出量。已下过单的父件再追加时，
/// 它下面那一层是按「已下达 + 本次填的」展开的(服务端「已下达计划量 + 本次填的量，
/// 再与需求取大」)，分子要把它算进去、传进来的分母也得含它；不传 = 全按 0 算。
List<CascadeScaleResult> cascadeScaleSubtree({
  required List<CascadeScaleInput> preorder,
  required int rootIndex,
  required double rootFactor,
  Map<String, double> committedOutput = const {},
}) {
  if (rootIndex < 0 || rootIndex >= preorder.length) return const [];
  final rootDepth = preorder[rootIndex].depth;
  final factorByDepth = <int, double?>{rootDepth: rootFactor};
  final results = <CascadeScaleResult>[];
  for (var next = rootIndex + 1; next < preorder.length; next++) {
    final row = preorder[next];
    if (row.depth <= rootDepth) break;
    final factor = factorByDepth[row.depth - 1];
    if (factor == null) {
      factorByDepth[row.depth] = null;
      continue;
    }
    final scaled = cascadeScaleOne(row.server, factor);
    if (!row.ownsInput) {
      factorByDepth[row.depth] = factor;
      results.add((
        index: next,
        key: row.key,
        scaled: scaled,
        displayQty: null,
      ));
      continue;
    }
    final display = cascadeFollowUpQty(
      server: scaled,
      userTyped: row.userTyped,
    );
    // 它下面那一层按「已下达 + 框里显示的数」展开，与分母同一口径。
    factorByDepth[row.depth] = cascadeFactor(
      baselineOutput: row.baselineOutput,
      output: (committedOutput[row.key] ?? 0) + display,
    );
    results.add((
      index: next,
      key: row.key,
      scaled: scaled,
      displayQty: display,
    ));
  }
  return results;
}

/// 要送给服务端重算的一行。
typedef CascadeTypedInput = ({
  /// 送给服务端时用的 id(物料行 id)。
  String payloadId,

  /// 用户亲手填的那个数；null = 没填过。
  double? userTyped,

  /// 有输入框、没有阻断原因、下面确实还带着层级、本次真的会下。
  bool ownsInput,
  bool blocked,
  bool hasChildren,
  bool willIssue,
});

/// 组装 `issue-plans/preview` 的 `typedOutputs`。
///
/// **只送用户亲手填的数**，而且只送那个「他填的数」本身，不是框里显示的数：
/// 显示值可能是按父行比例换算出来的、或按下限替他抬上去的。服务端那一侧是
/// 「加进计划产出量再与物理缺口取大」，是单调向上的——送一个回声值或被放大过的
/// 值上去，它就成了整棵子树的地板，回来又被子层原样采纳，再也降不下来。
/// 地板该是多少，服务端自己会从父行算出来。
Map<String, double> cascadeTypedOutputs(Iterable<CascadeTypedInput> rows) => {
  for (final row in rows)
    if (row.ownsInput &&
        !row.blocked &&
        row.hasChildren &&
        row.willIssue &&
        (row.userTyped ?? 0) > 0.0001)
      row.payloadId: row.userTyped!,
};
