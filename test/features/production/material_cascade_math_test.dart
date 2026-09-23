// 「父改子跟」六条口径的单测：不启页面、不跑 widget，只钉算法本身。
//
// 这六条以前只被两张整页 widget 测试间接覆盖，而那两张测试各自的假后端口径还不
// 一样——2026-09-22 的对抗复查里，正是假后端把「孙层按 批量 × 单耗 展开、忽略中间层
// 覆盖」当成事实，差点把「子层跟净产出还是跟毛需求」这条判反。算法层的断言不依赖
// 任何假后端，口径写在哪就是哪。
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/features/production/models/material_cascade_math.dart';

CascadeServerQty _qty(double required, double residual, {double? suggested}) =>
    (required: required, residual: residual, suggested: suggested ?? residual);

CascadeScaleInput _row(
  String key,
  int depth,
  CascadeServerQty server, {
  bool ownsInput = true,
  double? userTyped,
  double? baselineOutput,
  double committed = 0,
}) => (
  key: key,
  depth: depth,
  ownsInput: ownsInput,
  server: server,
  userTyped: userTyped,
  // 分母默认取「这一行在当前快照里按的产出量」——与页面播种 _snapshotOutput
  // 的口径一致(手工填过的行按他填的数，没填过的按系统建议量)，已下达的量算在内。
  baselineOutput:
      baselineOutput ??
      cascadePlannedOutput(
        committedOutput: committed,
        server: server,
        userTyped: userTyped,
      ),
);

void main() {
  group('显示值', () {
    test('没亲手填过就跟系统建议量走', () {
      expect(
        cascadeFollowUpQty(
          server: _qty(1000, 600, suggested: 650),
          userTyped: null,
        ),
        650,
      );
    });

    test('亲手填过的取「填的数」与「还需安排」的大者', () {
      final server = _qty(1000, 600);
      // 填得比需求多：原样留着(口径三)。
      expect(cascadeFollowUpQty(server: server, userTyped: 3000), 3000);
      // 父件涨过它：抬到新的还需安排量。
      expect(
        cascadeFollowUpQty(server: _qty(5000, 4000), userTyped: 3000),
        4000,
      );
      // 父件又改小：退回用户自己填的那个数，不停在替他抬上去的值上。
      expect(cascadeFollowUpQty(server: server, userTyped: 3000), 3000);
    });

    test('填 0 是一个明确决定(追加行本次不下它)，与没填过不是一回事', () {
      final server = _qty(1000, 0, suggested: 0);
      expect(cascadeFollowUpQty(server: server, userTyped: 0), 0);
      expect(cascadeFollowUpQty(server: _qty(1000, 600), userTyped: 0), 600);
    });
  });

  group('换算一行', () {
    test('覆盖量是不变量，只有需求等比例变', () {
      // 需求 1000、已覆盖 400(还需安排 600)：父件翻倍 → 需求 2000、还需安排 1600。
      final scaled = cascadeScaleOne(_qty(1000, 600), 2);
      expect(scaled.required, 2000);
      expect(scaled.residual, 1600);
    });

    test('缩到覆盖量以下时还需安排落到 0，不会变成负数', () {
      final scaled = cascadeScaleOne(_qty(1000, 600), 0.2);
      expect(scaled.required, 200);
      expect(scaled.residual, 0);
    });

    test('从服务端值重算是幂等的：怎么来回改，同一个比例给同一个结果', () {
      final server = _qty(1000, 600);
      expect(cascadeScaleOne(server, 2).residual, 1600);
      // 退格经过空框、又敲回来——中间怎么走都不影响，因为分母是快照不是上一拍。
      expect(cascadeScaleOne(server, 0.5).residual, 100);
      expect(cascadeScaleOne(server, 2).residual, 1600);
    });

    test('多下过的子件按不封顶的覆盖量算：父件追加时它一颗都不缺', () {
      // 需求 1000、还需安排 0(服务端封顶)。父件抬到 1.2 倍 → 需求 1200。
      final server = _qty(1000, 0);
      // 只看封顶值：以为覆盖 1000，会错报还缺 200。
      expect(cascadeScaleOne(server, 1.2).residual, 200);
      // 实际已下 2000：仍被盖住，还需安排 0(用户口径「之前已经下单了 2000 就不用追加」)。
      expect(cascadeScaleOne(server, 1.2, coveredFloor: 2000).residual, 0);
      // 刚好下够 1000：父件追加 200 就缺 200(「父组件追加 200, 子组件也自动追加 200」)。
      expect(cascadeScaleOne(server, 1.2, coveredFloor: 1000).residual, 200);
      // 多下了一点(1100)：只缺 100。
      expect(cascadeScaleOne(server, 1.2, coveredFloor: 1100).residual, 100);
      // 不封顶值比服务端封顶值小(调用方漏算的覆盖来源)：仍按封顶值兜底。
      expect(
        cascadeScaleOne(_qty(1000, 600), 2, coveredFloor: 100).residual,
        1600,
      );
    });
  });

  group('比例', () {
    test('分母是服务端快照当时的数；算不出就返回 null 交给服务端', () {
      expect(cascadeFactor(baselineOutput: 500, output: 1000), 2);
      expect(cascadeFactor(baselineOutput: 0, output: 1000), isNull);
      expect(cascadeFactor(baselineOutput: null, output: 1000), isNull);
      expect(cascadeFactor(baselineOutput: 500, output: -1), isNull);
      // 填 0 = 这一批不做它，是合法比例。
      expect(cascadeFactor(baselineOutput: 500, output: 0), 0);
    });
  });

  group('整支子树', () {
    // 树：父 P(需求 1000/还需 1000) → 子 C(需求 1000/还需 1000) → 孙 G(需求 3000/还需 3000)
    List<CascadeScaleInput> tree({double? cTyped}) => [
      _row('P', 0, _qty(1000, 1000)),
      _row('C', 1, _qty(1000, 1000), userTyped: cTyped),
      _row('G', 2, _qty(3000, 3000)),
    ];

    test('口径一/二：没手工改过的子层跟着父行双向走', () {
      final up = cascadeScaleSubtree(
        preorder: tree(),
        rootIndex: 0,
        rootFactor: 2,
      );
      expect(up.map((r) => r.key), ['C', 'G']);
      expect(up[0].displayQty, 2000);
      expect(up[1].displayQty, 6000);

      final back = cascadeScaleSubtree(
        preorder: tree(),
        rootIndex: 0,
        rootFactor: 1,
      );
      expect(back[0].displayQty, 1000);
      expect(back[1].displayQty, 3000);
    });

    test('口径三：手工改过的那一行不跟父行，它下面那一支也跟着它不动', () {
      final rows = cascadeScaleSubtree(
        preorder: tree(cTyped: 3000),
        rootIndex: 0,
        rootFactor: 2,
      );
      // C 的需求跟着父件涨到 2000，但填的 3000 更大，显示值仍是 3000。
      expect(rows[0].scaled.required, 2000);
      expect(rows[0].displayQty, 3000);
      // C 的产出量没变(还是 3000)，所以孙层一动不动。
      expect(rows[1].displayQty, 3000);
    });

    test('口径三续：父件涨过手填值时，这一行与它的子树一起抬上去', () {
      final rows = cascadeScaleSubtree(
        preorder: tree(cTyped: 3000),
        rootIndex: 0,
        rootFactor: 4,
      );
      expect(rows[0].displayQty, 4000);
      // C 从 3000 抬到 4000，孙层按 4000/3000 跟上去。
      expect(rows[1].displayQty, closeTo(4000, 0.0001));
    });

    test('中间层有现货覆盖时，传给孙层的是净产出的比例而不是毛需求的比例', () {
      // C 需求 10、覆盖 9 → 还需安排 1；孙层 G 需求 3。
      final rows = cascadeScaleSubtree(
        preorder: [
          _row('P', 0, _qty(10, 10)),
          _row('C', 1, _qty(10, 1)),
          _row('G', 2, _qty(3, 3)),
        ],
        rootIndex: 0,
        rootFactor: 2,
      );
      // C: 需求 20、覆盖 9 不变 → 还需安排 11。
      expect(rows[0].scaled.required, 20);
      expect(rows[0].displayQty, 11);
      // 服务端子层跟的是 C 的净产出(1 → 11)，所以 G 是 3 × 11 = 33，
      // 不是按毛需求翻倍的 6。
      expect(rows[1].displayQty, closeTo(33, 0.0001));
    });

    test('某一层算不出比例时，那一支整个交给服务端，不拿父行比例硬乘', () {
      final rows = cascadeScaleSubtree(
        preorder: [
          _row('P', 0, _qty(1000, 1000)),
          // 快照里这一行的产出量是 0(追加行从 0 开始填)。
          _row('C', 1, _qty(0, 0), baselineOutput: 0),
          _row('G', 2, _qty(3000, 3000)),
        ],
        rootIndex: 0,
        rootFactor: 2,
      );
      expect(rows.firstWhere((r) => r.key == 'C').displayQty, 0);
      // G 没有被换算(比例算不出)。
      expect(rows.where((r) => r.key == 'G'), isEmpty);
    });

    test('已下过单的中间层再追加：它下面那一层按「已下达 + 追加」展开，不是只按追加量', () {
      // C 已下达 1000(还需安排 0)，孙层 G 是按那 1000 铺开的(需求 1000、已覆盖 400)。
      // 在 C 的追加格填 1500：C 的产出量从 1000 变成 2500，G 的需求跟到 2500、
      // 还需安排 2100；不算已下达量的话分母是 0，这一支只能干等服务端。
      final rows = cascadeScaleSubtree(
        preorder: [
          _row('P', 0, _qty(1000, 1000)),
          // 快照当时追加格还是空的：分母 = 已下达 1000 + 还需安排 0。
          _row(
            'C',
            1,
            _qty(1000, 0),
            userTyped: 1500,
            committed: 1000,
            baselineOutput: 1000,
          ),
          _row('G', 2, _qty(1000, 600)),
        ],
        rootIndex: 0,
        rootFactor: 1,
        committedOutput: const {'C': 1000},
      );
      expect(rows[0].displayQty, 1500);
      expect(rows[1].scaled.required, closeTo(2500, 0.0001));
      expect(rows[1].displayQty, closeTo(2100, 0.0001));
      expect(
        cascadePlannedOutput(
          committedOutput: 1000,
          server: _qty(1000, 0),
          userTyped: null,
        ),
        1000,
      );
    });

    test('父件追加时子件按不封顶的覆盖量算：刚好下够的缺多少填多少，多下过的一颗都不缺', () {
      // P 已下达 1000(还需安排 0)再追加 200 → 产出 1200 = 1.2 倍。
      // C1 刚好下够(需求 1000/已下 1000)，C2 多下了(需求 1000/已下 2000)——快照里两行
      // 的还需安排都是 0，只看封顶值分不出谁多下了。
      final rows = cascadeScaleSubtree(
        preorder: [
          _row(
            'P',
            0,
            _qty(1000, 0),
            userTyped: 200,
            committed: 1000,
            baselineOutput: 1000,
          ),
          _row('C1', 1, _qty(1000, 0), committed: 1000),
          _row('C2', 1, _qty(1000, 0), committed: 2000),
        ],
        rootIndex: 0,
        rootFactor: 1.2,
        committedOutput: const {'P': 1000, 'C1': 1000, 'C2': 2000},
        coveredOutput: const {'C1': 1000, 'C2': 2000},
      );
      expect(rows.map((r) => r.key), ['C1', 'C2']);
      expect(rows[0].scaled.required, closeTo(1200, 0.0001));
      expect(rows[0].displayQty, closeTo(200, 0.0001));
      expect(rows[1].scaled.required, closeTo(1200, 0.0001));
      expect(rows[1].displayQty, 0);
    });

    test('没有输入框的上下文行把父行的比例原样传下去', () {
      final rows = cascadeScaleSubtree(
        preorder: [
          _row('P', 0, _qty(1000, 1000)),
          _row('DUP', 1, _qty(1000, 1000), ownsInput: false),
          _row('G', 2, _qty(3000, 3000)),
        ],
        rootIndex: 0,
        rootFactor: 2,
      );
      expect(rows[0].displayQty, isNull);
      expect(rows[1].displayQty, 6000);
    });
  });

  group('送给服务端的数量', () {
    CascadeTypedInput row(
      String id, {
      double? userTyped,
      bool ownsInput = true,
      bool blocked = false,
      bool hasChildren = true,
      bool willIssue = true,
    }) => (
      payloadId: id,
      userTyped: userTyped,
      ownsInput: ownsInput,
      blocked: blocked,
      hasChildren: hasChildren,
      willIssue: willIssue,
    );

    test('只送用户亲手填过、带下层、能下达、本次会下的行', () {
      expect(
        cascadeTypedOutputs([
          row('typed', userTyped: 1500),
          // 没填过：它的数只是父行的回声，送回去会把子树钉在旧值上。
          row('echo'),
          // 叶子行改量不影响任何人。
          row('leaf', userTyped: 200, hasChildren: false),
          // 没勾 = 本次不下它，也就不该带动它的子层。
          row('unchecked', userTyped: 300, willIssue: false),
          row('blocked', userTyped: 400, blocked: true),
          row('context', userTyped: 500, ownsInput: false),
          // 填 0 = 本次不下它，不改变任何东西。
          row('zero', userTyped: 0),
        ]),
        {'typed': 1500.0},
      );
    });
  });
}
