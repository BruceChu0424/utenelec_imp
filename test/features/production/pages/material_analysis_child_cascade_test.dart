// 「父件 + 下层一起下单」整页（ADR-081 整页前置；2026-09-21 ADR-099 改为
// **服务端算量**：车间通道先向服务端要一份「下达预览」——服务端真实跑一遍
// issue-plans 再整体回滚——下层的需求 / 还需安排全部读那份快照，浏览器不再
// 按单耗自行相乘）。
//
// 场景：成品A 本批需求 10，计划员按 20 下达（超产 10）。它的 BOM 是
//   成品A ─┬─ 外购件B  单件用 2（采购）
//          └─ 半成品C  单件用 1（自制）
//                └─ 外购件D  单件用 3（采购，孙层）
// 假后端对 /issue-plans/preview 按请求里的本批数量把下层需求放大（B=40、C=20、
// D=60），与真实服务端「按计划产出量展开」同一口径。
// 断言：
//  1. 点「创建生产计划」→ 只发一次 preview（零真实写）→ 直接进整页，树顶是本次
//     要下达的件，下层数量就是预览快照给的 40 / 20 / 60；
//  2. 一键下单按序提交：父件 issue-plans → 采购 notify BUY（总量口径，不再拆
//     publicExtraQty）→ 自制 issue-plans；
//  3. 树顶数量改了会再要一份预览，下层随之变；清空树顶数量当场拦下；
//  4. 折叠分支撤掉的勾选在展开时原样恢复；树顶行不画多选框；
//  5. 列集合守在定稿那一组；
//  6. 单一叶子子件的委外件：父件走 notify、不请求预览、子件仍进一起办；
//  7. 有自制子层的顶层委外件：从委外桶进来走 issue-plans，车间由学习默认补上；
//  8. 父件尚未提交时退出必须确认，确认后一个写请求都不发；
//  9. 下层都已下过单时仍进页（父层级可追加），一行不勾直接只下达父件；
// 10. 已下过单的子件行仍可追加：追加量默认就写 0，勾着留 0 的本次不下也不报错，
//     填了正数的才下（用户口径 2026-09-21 第二、四轮）；
// 11. 下达车间已下达段：需求已全部转入计划的顶层仍可追加一批公共备货产出
//     （publicSurplusOnly 显式声明，进整页填车间后提交）；
// 12. 有自制子层的委外件已下达后，父层级这页仍能给它追加——按候选行走 ARRANGE
//     （委外台账才跟得上量），并声明 publicSurplusOnly。
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/features/department/models/department_node.dart';
import 'package:uten_imp/features/department/repositories/department_repository.dart';
import 'package:uten_imp/features/production/models/production_material_analysis.dart';
import 'package:uten_imp/features/production/pages/production_material_analysis_page.dart';
import 'package:uten_imp/features/production/providers/material_analysis_warehouse_prefs_provider.dart';
import 'package:uten_imp/features/production/repositories/production_repository.dart';
import 'package:uten_imp/features/purchase/repositories/purchase_repository.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/providers/master_name_provider.dart';
import 'package:uten_imp/components/layout/uten_table_column_kit.dart';

void main() {
  testWidgets('点创建生产计划先请求下达预览再进整页，一键下单按序提交父件与下层', (tester) async {
    final harness = await _pump(tester);
    // 本批数量在页里改成 20(需求 10)——超产 10。
    await _enterCascadeFromWorkshopBucket(tester, '20');

    // 进页一次预览(按默认 10)、改成 20 再一次预览(都不落库)，零真实下达。
    expect(find.text('父件 + 下层一起下单'), findsOneWidget);
    final previews = harness.writes
        .where((r) => r.path.endsWith('/issue-plans/preview'))
        .toList();
    expect(previews, hasLength(2));
    final previewLines =
        (previews.last.data as Map<String, dynamic>)['lines'] as List;
    expect((previewLines.single as Map<String, dynamic>)['qty'], 20.0);
    expect(
      harness.writes.where((r) => r.path.endsWith('/issue-plans')),
      isEmpty,
    );

    Finder rate(String id) => find.descendant(
      of: find.byKey(ValueKey('material-analysis-child-cascade-rate-$id')),
      matching: find.byType(TextField),
    );
    expect(tester.widget<TextField>(rate('root-1')).controller!.text, '0');
    expect(tester.widget<TextField>(rate('m-c')).controller!.text, '10');
    expect(rate('m-b'), findsNothing);
    expect(rate('m-d'), findsNothing);
    await tester.enterText(rate('root-1'), '15');
    await tester.enterText(rate('m-c'), '25');
    await _setSeedQty(tester, '30');
    await _setSeedQty(tester, '20');
    // The latest async preview must preserve independent root/child inputs.
    expect(tester.widget<TextField>(rate('root-1')).controller!.text, '15');
    expect(tester.widget<TextField>(rate('m-c')).controller!.text, '25');
    final ratePreview = harness.writes.lastWhere(
      (r) => r.path.endsWith('/issue-plans/preview'),
    );
    expect(
      (((ratePreview.data as Map)['lines'] as List).single
          as Map)['allowedOverproductionRate'],
      0.15,
    );

    // 树顶是本次要下达的件本身，下面才是子层 / 孙层。
    expect(find.textContaining('本次将下达 20'), findsOneWidget);
    expect(_inDialog('成品A'), findsOneWidget);
    expect(_inDialog('外购件B'), findsOneWidget);
    expect(_inDialog('半成品C'), findsOneWidget);
    expect(_inDialog('外购件D'), findsOneWidget);
    // 折叠「半成品C」分支：孙层外购件D 隐藏、勾选随之撤掉；再展开原样恢复。
    // Return the horizontally scrolled tree column beyond the frozen checkbox.
    for (final scrollable in tester.stateList<ScrollableState>(
      find.ancestor(
        of: find.byKey(const Key('cascade-toggle-m-c')),
        matching: find.byType(Scrollable),
      ),
    )) {
      if (axisDirectionToAxis(scrollable.position.axisDirection) ==
          Axis.horizontal) {
        scrollable.position.jumpTo(0);
      }
    }
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('cascade-toggle-m-c')));
    await tester.pumpAndSettle();
    expect(_inDialog('外购件D'), findsNothing);
    await tester.tap(find.byKey(const Key('cascade-toggle-m-c')));
    await tester.pumpAndSettle();
    expect(_inDialog('外购件D'), findsOneWidget);

    // 数量就是预览快照里服务端算好的：B=40、C=20、D=60。
    expect(_qtyOf(tester, 'm-b'), '40');
    expect(_qtyOf(tester, 'm-c'), '20');
    expect(_qtyOf(tester, 'm-d'), '60');

    // 树顶在本页改大过：一键下单先过超量确认，再到确认弹窗。
    await _tapSubmitThroughOverQty(tester);
    await tester.tap(find.text('一键下单'));
    await tester.pumpAndSettle();

    // 一键下单之后才有真实提交：父件 issue-plans → 采购 notify → 下层自制 issue-plans。
    final issue = harness.writes
        .where((request) => request.path.endsWith('/issue-plans'))
        .toList();
    expect(issue, hasLength(2));
    final parentLines =
        (issue.first.data as Map<String, dynamic>)['lines'] as List;
    expect(
      (parentLines.single as Map<String, dynamic>)['analysisLineId'],
      'p1',
    );
    expect((parentLines.single as Map<String, dynamic>)['qty'], 20.0);
    expect(
      (parentLines.single as Map<String, dynamic>)['allowedOverproductionRate'],
      0.15,
    );
    final cascadeLines =
        (issue.last.data as Map<String, dynamic>)['lines'] as List;
    expect(cascadeLines, hasLength(1));
    final line = cascadeLines.single as Map<String, dynamic>;
    expect(line['materialLineId'], 'm-c');
    expect(line['qty'], 20.0);
    expect(line['departmentId'], 'dept-1');
    expect(line['allowedOverproductionRate'], 0.25);

    // 采购两行合并成一次 notify；数量是总量口径（服务端自己分账）。
    final notify = harness.writes
        .where((request) => request.path.endsWith('/notify'))
        .toList();
    expect(notify, hasLength(1));
    final notifyBody = notify.single.data as Map<String, dynamic>;
    expect(notifyBody['target'], 'BUY');
    final quantities = (notifyBody['quantities'] as List)
        .cast<Map<String, dynamic>>();
    expect(
      quantities.map((row) => '${row['actionGroupKey']}=${row['qty']}').toSet(),
      {'ag-b=40.0', 'ag-d=60.0'},
    );
    expect(quantities.any((row) => row.containsKey('publicExtraQty')), isFalse);
  });

  testWidgets('非法子件比例挡住整批下达，不先写入父件也不清空输入', (tester) async {
    final harness = await _pump(tester);
    await _enterCascadeFromWorkshopBucket(tester, '10');
    final field = find.descendant(
      of: find.byKey(
        const ValueKey('material-analysis-child-cascade-rate-m-c'),
      ),
      matching: find.byType(TextField),
    );
    await tester.enterText(field, '-2');
    await tester.pumpAndSettle();
    await _tapSubmitThroughOverQty(tester);
    expect(
      harness.writes.where((r) => !r.path.endsWith('/issue-plans/preview')),
      isEmpty,
    );
    expect(tester.widget<TextField>(field).controller!.text, '-2');
    expect(tester.takeException(), isNull);
  });

  testWidgets('树顶父件行没有多选框，改它的数量会再要一份预览、下层跟着变', (tester) async {
    final harness = await _pump(tester);
    await _enterCascadeFromWorkshopBucket(tester, '20');
    expect(_qtyOf(tester, 'm-b'), '40');

    // 树顶行没有勾选框：勾选框只出现在表头全选 + 下层可下单行上（B、C、D 三行）。
    final dialog = find.byKey(
      const Key('material-analysis-child-cascade-dialog'),
    );
    expect(
      find.descendant(of: dialog, matching: find.byType(Checkbox)),
      findsNWidgets(4),
    );

    // 改树顶数量为 30：去抖后再发一次预览，下层按预览快照变成 B=60。
    final previewsBefore = harness.writes
        .where((r) => r.path.endsWith('/issue-plans/preview'))
        .length;
    await tester.enterText(
      find.byKey(const ValueKey('material-analysis-child-cascade-qty-root-1')),
      '30',
    );
    await tester.pump(const Duration(milliseconds: 700));
    await tester.pumpAndSettle();
    final previewsAfter = harness.writes
        .where((r) => r.path.endsWith('/issue-plans/preview'))
        .toList();
    expect(previewsAfter.length, previewsBefore + 1);
    final lines =
        (previewsAfter.last.data as Map<String, dynamic>)['lines'] as List;
    expect((lines.single as Map<String, dynamic>)['qty'], 30.0);
    expect(_qtyOf(tester, 'm-b'), '60');
    expect(_qtyOf(tester, 'm-d'), '90');
    // 零真实下达。
    expect(
      harness.writes.where((r) => r.path.endsWith('/issue-plans')),
      isEmpty,
    );
  });

  testWidgets('改中间层父件的数量，它的孙层跟着变；它自己和兄弟行不受影响', (tester) async {
    final harness = await _pump(tester);
    await _enterCascadeFromWorkshopBucket(tester, '20');
    expect(_qtyOf(tester, 'm-c'), '20');
    expect(_qtyOf(tester, 'm-d'), '60');

    // 半成品C 是自制件、下面还带着孙层：改它的数量要再要一份重算。
    final before = harness.writes
        .where((r) => r.path.endsWith('/issue-plans/preview'))
        .length;
    await tester.enterText(
      find.byKey(const ValueKey('material-analysis-child-cascade-qty-m-c')),
      '30',
    );
    await tester.pump(const Duration(milliseconds: 700));
    await tester.pumpAndSettle();
    final previews = harness.writes
        .where((r) => r.path.endsWith('/issue-plans/preview'))
        .toList();
    expect(previews.length, before + 1);
    final body = previews.last.data as Map<String, dynamic>;
    // 树顶照旧真实模拟一遍下达；中间层的数量走 typedOutputs。
    expect(((body['lines'] as List).single as Map)['qty'], 20.0);
    expect(body['typedOutputs'], [
      {'materialLineId': 'm-c', 'qty': 30.0},
    ]);
    // 孙层跟着中间层走(D 单件用 3)；中间层自己填的数不被自己带跑，兄弟行不动。
    expect(_qtyOf(tester, 'm-d'), '90');
    expect(_qtyOf(tester, 'm-c'), '30');
    expect(_qtyOf(tester, 'm-b'), '40');
    // 叶子行改量不值得回服务端：改采购件 B 不再发预览。
    await tester.enterText(
      find.byKey(const ValueKey('material-analysis-child-cascade-qty-m-b')),
      '45',
    );
    await tester.pump(const Duration(milliseconds: 700));
    await tester.pumpAndSettle();
    expect(
      harness.writes.where((r) => r.path.endsWith('/issue-plans/preview')),
      hasLength(previews.length),
    );
    // 零真实下达。
    expect(
      harness.writes.where((r) => r.path.endsWith('/issue-plans')),
      isEmpty,
    );
  });

  testWidgets('父件数量一改，子层当场就跟着变——不等服务端那份重算回来', (tester) async {
    final harness = await _pump(tester);
    await _enterCascadeFromWorkshopBucket(tester, '20');
    expect(_qtyOf(tester, 'm-b'), '40');
    expect(_qtyOf(tester, 'm-d'), '60');
    final before = harness.writes
        .where((r) => r.path.endsWith('/issue-plans/preview'))
        .length;

    // 敲完就过一帧：去抖还没到，服务端一个字都还没问，屏幕上的子层已经变了。
    await tester.enterText(
      find.byKey(const ValueKey('material-analysis-child-cascade-qty-root-1')),
      '40',
    );
    await tester.pump();
    expect(
      harness.writes.where((r) => r.path.endsWith('/issue-plans/preview')),
      hasLength(before),
    );
    expect(_qtyOf(tester, 'm-b'), '80');
    expect(_qtyOf(tester, 'm-d'), '120');

    // 去抖到了才问服务端，回来换成权威值(这里两者一致)。
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();
    expect(
      harness.writes.where((r) => r.path.endsWith('/issue-plans/preview')),
      hasLength(before + 1),
    );
    expect(_qtyOf(tester, 'm-b'), '80');
    expect(_qtyOf(tester, 'm-d'), '120');
  });

  testWidgets('父件改大又立刻改回：没手工改过的子层原路跟着回落，手工改过的那一支不跟', (tester) async {
    final harness = await _pump(tester);
    await _enterCascadeFromWorkshopBucket(tester, '20');
    expect(_qtyOf(tester, 'm-b'), '40');
    expect(_qtyOf(tester, 'm-c'), '20');
    expect(_qtyOf(tester, 'm-d'), '60');

    // 父件 20 → 40：子层、孙层跟着翻倍。
    await _setSeedQty(tester, '40');
    expect(_qtyOf(tester, 'm-b'), '80');
    expect(_qtyOf(tester, 'm-c'), '40');
    expect(_qtyOf(tester, 'm-d'), '120');

    // 还没下单就立刻改回 20：刚刚因父件变大的那些数原路回落(用户口径
    // 2026-09-21 第九轮：先操作变数、然后立马又变，就跟着父件一起变)。
    await _setSeedQty(tester, '20');
    expect(_qtyOf(tester, 'm-b'), '40');
    expect(_qtyOf(tester, 'm-c'), '20');
    expect(_qtyOf(tester, 'm-d'), '60');
    // 没手工改过的行不会被送回服务端当输入——送了就会把孙层钉在旧值上。
    final lastPreview =
        harness.writes
                .where((r) => r.path.endsWith('/issue-plans/preview'))
                .last
                .data
            as Map<String, dynamic>;
    expect(lastPreview['typedOutputs'], isEmpty);

    // 手工把半成品C 改成 100：它的孙层跟它走(100 × 3)。
    await tester.enterText(
      find.byKey(const ValueKey('material-analysis-child-cascade-qty-m-c')),
      '100',
    );
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();
    expect(_qtyOf(tester, 'm-c'), '100');
    expect(_qtyOf(tester, 'm-d'), '300');

    // 父件再怎么变，手工改过的那一支都不跟：C 停在 100、D 停在 300；
    // 没手工改过的兄弟行 B 照样跟着父件走。
    await _setSeedQty(tester, '40');
    expect(_qtyOf(tester, 'm-c'), '100');
    expect(_qtyOf(tester, 'm-d'), '300');
    expect(_qtyOf(tester, 'm-b'), '80');
    await _setSeedQty(tester, '10');
    expect(_qtyOf(tester, 'm-c'), '100');
    expect(_qtyOf(tester, 'm-d'), '300');
    expect(_qtyOf(tester, 'm-b'), '20');

    // 只有父件的需求涨过用户填的那个数时才抬上去，孙层跟着抬。
    await _setSeedQty(tester, '400');
    expect(_qtyOf(tester, 'm-c'), '400');
    expect(_qtyOf(tester, 'm-d'), '1200');
  });

  testWidgets('手工把中间层改大后一键下单：孙层按屏幕上确认过的数下，不被悄悄调小', (tester) async {
    final harness = await _pump(tester);
    await _enterCascadeFromWorkshopBucket(tester, '20');
    // 半成品C 手工改成 50：孙层 外购件D 跟到 150(服务端重算给的数)。
    await tester.enterText(
      find.byKey(const ValueKey('material-analysis-child-cascade-qty-m-c')),
      '50',
    );
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();
    expect(_qtyOf(tester, 'm-c'), '50');
    expect(_qtyOf(tester, 'm-d'), '150');

    await _tapSubmitThroughOverQty(tester);
    await tester.tap(find.text('一键下单'));
    await tester.pumpAndSettle();

    // 父件段落地时，半成品C 自己的计划还没下达，服务端那份快照算出来的 D 还是
    // 旧数(60)。屏幕上刚刚确认过的是 150，下出去的就必须是 150。
    final notify = harness.writes
        .where((request) => request.path.endsWith('/notify'))
        .toList();
    expect(notify, isNotEmpty);
    final quantities =
        ((notify.last.data as Map<String, dynamic>)['quantities'] as List)
            .cast<Map<String, dynamic>>();
    expect(
      quantities.firstWhere((row) => row['actionGroupKey'] == 'ag-d')['qty'],
      150.0,
    );
  });

  testWidgets('退格一位一位改数：中途空框既不发请求，也不会把子层甩在旧倍数上', (tester) async {
    final harness = await _pump(tester);
    await _enterCascadeFromWorkshopBucket(tester, '20');
    expect(_qtyOf(tester, 'm-b'), '40');
    final seedBox = find.byKey(
      const ValueKey('material-analysis-child-cascade-qty-root-1'),
    );

    // 先改到 40，再用退格一位一位退回 20(真人改数就是这么改的)：
    // 40 → 4 → 空 → 2 → 20。中间那一拍空框没有数可算，不能把换算基准吃掉，
    // 否则后面每补一位都在错的基准上 ×10，父件回到 20 了子层还停在 2000 档。
    await _setSeedQty(tester, '40');
    expect(_qtyOf(tester, 'm-b'), '80');
    await tester.enterText(seedBox, '4');
    await tester.pump();
    expect(_qtyOf(tester, 'm-b'), '8');

    final beforeBlank = harness.writes
        .where((r) => r.path.endsWith('/issue-plans/preview'))
        .length;
    await tester.enterText(seedBox, '');
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pumpAndSettle();
    // 树顶还空着：这一拍不发重算请求(发了只会拿到一份「什么都不下达」的快照，
    // 把基准换掉)。
    expect(
      harness.writes.where((r) => r.path.endsWith('/issue-plans/preview')),
      hasLength(beforeBlank),
    );

    await tester.enterText(seedBox, '2');
    await tester.pump();
    expect(_qtyOf(tester, 'm-b'), '4');
    await _setSeedQty(tester, '20');

    // 退格改回来的结果，与一开始直接填 20 逐字一致。
    expect(_qtyOf(tester, 'm-b'), '40');
    expect(_qtyOf(tester, 'm-c'), '20');
    expect(_qtyOf(tester, 'm-d'), '60');
  });

  testWidgets('手滑敲一下又删掉不算「改过」：这一行照旧跟着父件走', (tester) async {
    await _pump(tester);
    await _enterCascadeFromWorkshopBucket(tester, '20');
    final childBox = find.byKey(
      const ValueKey('material-analysis-child-cascade-qty-m-b'),
    );
    await tester.enterText(childBox, '7');
    await tester.pump();
    await tester.enterText(childBox, '');
    await tester.pump();

    // 清空 = 把这一行交还给系统算：父件一改它照样跟着走(没有这条的话，
    // 误触一下就永久脱离跟随，而且界面上没有任何退回去的入口)。
    await _setSeedQty(tester, '40');
    expect(_qtyOf(tester, 'm-b'), '80');
    await _setSeedQty(tester, '20');
    expect(_qtyOf(tester, 'm-b'), '40');
  });

  testWidgets('先把子层改大再改父件：填得比新需求多就原样留着，比新需求少就跟着抬上去', (tester) async {
    await _pump(tester);
    await _enterCascadeFromWorkshopBucket(tester, '20');
    // 子层手工改成 100(远高于按 20 算出来的 40)。
    await tester.enterText(
      find.byKey(const ValueKey('material-analysis-child-cascade-qty-m-b')),
      '100',
    );
    await tester.pumpAndSettle();

    // 父件改小到 10：新需求 20 < 手填的 100，子层原样不动。
    await tester.enterText(
      find.byKey(const ValueKey('material-analysis-child-cascade-qty-root-1')),
      '10',
    );
    await tester.pump(const Duration(milliseconds: 700));
    await tester.pumpAndSettle();
    expect(_qtyOf(tester, 'm-b'), '100');

    // 父件改大到 60：新需求 120 > 手填的 100，子层跟着抬到 120(否则父件缺料)。
    await tester.enterText(
      find.byKey(const ValueKey('material-analysis-child-cascade-qty-root-1')),
      '60',
    );
    await tester.pump(const Duration(milliseconds: 700));
    await tester.pumpAndSettle();
    expect(_qtyOf(tester, 'm-b'), '120');
  });

  testWidgets('树顶数量被清空时不按旧数量提交，而是当场拦下', (tester) async {
    final harness = await _pump(tester);
    await _enterCascadeFromWorkshopBucket(tester, '20');
    await tester.enterText(
      find.byKey(const ValueKey('material-analysis-child-cascade-qty-root-1')),
      '',
    );
    await tester.pump(const Duration(milliseconds: 700));
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const Key('material-analysis-child-cascade-submit')),
    );
    await tester.pumpAndSettle();
    // 一行都不许提交，页面也不许关（错误提示走全局顶部通知 provider，不在本页
    // 组件树里，故只断事实）。
    expect(
      harness.writes.where((r) => r.path.endsWith('/issue-plans')),
      isEmpty,
    );
    expect(harness.writes.where((r) => r.path.endsWith('/notify')), isEmpty);
    expect(
      find.byKey(const Key('material-analysis-child-cascade-dialog')),
      findsOneWidget,
    );
  });

  testWidgets('级联页列 = 身份与下单列 + 从外层桶表搬进来的信息列', (tester) async {
    await _pump(tester);
    await _enterCascadeFromWorkshopBucket(tester, '20');
    final dialog = find.byKey(
      const Key('material-analysis-child-cascade-dialog'),
    );
    // 2026-09-22：外层桶表只留身份四列 + 供应方式 / 需求量 / 缺口 / 进度，其余
    // (归属车间 / BOM 路径 / 仓库余量 / 缺口)搬进这一页。
    for (final label in const [
      '物料名称',
      '编号',
      '颜色',
      '单位',
      '供料路线',
      '所属仓库',
      '归属车间',
      'BOM 路径',
      '下达去向',
      '本批备料需求',
      '还需安排',
      '仓库余量',
      '缺口',
      '下单数量',
      '允许超产比例',
      '生产车间',
      '负责人',
      '状态',
    ]) {
      // 必填列的表头带「 *」后缀，按包含匹配。
      expect(
        find.descendant(of: dialog, matching: find.textContaining(label)),
        findsWidgets,
        reason: '缺列 $label',
      );
    }
    for (final retired in const ['本批要用', '还缺数量', '建议下单', '超产多需']) {
      expect(
        find.descendant(of: dialog, matching: find.text(retired)),
        findsNothing,
        reason: '不该有列 $retired',
      );
    }
  });

  testWidgets('下层都已下过单时仍进页（可追加），一行不勾直接只下达父件', (tester) async {
    final harness = await _pump(tester, childrenAlreadyOrdered: true);
    await _openWorkshopBucket(tester);
    await _tapRowCheckbox(tester, '成品A');
    await tester.tap(
      find.byKey(const Key('material-analysis-bucket-action-ready')),
    );
    await tester.pumpAndSettle();
    expect(
      find.byKey(const Key('material-analysis-child-cascade-dialog')),
      findsOneWidget,
    );
    // 已覆盖的采购行仍有输入框（追加用），默认写 0：
    // 勾着不动 = 本次不下它。
    expect(_qtyOf(tester, 'm-b'), '0');
    expect(find.textContaining('本批需求已覆盖，填的数量即额外追加'), findsWidgets);
    await tester.tap(
      find.byKey(const Key('material-analysis-child-cascade-submit')),
    );
    await tester.pumpAndSettle();
    // 没有一行还有缺口：不再问「只下达父件？」，直接提交父件；零采购请求。
    expect(
      harness.writes.where((r) => r.path.endsWith('/issue-plans')).length,
      1,
    );
    expect(harness.writes.where((r) => r.path.endsWith('/notify')), isEmpty);
    expect(
      find.byKey(const Key('material-analysis-child-cascade-dialog')),
      findsNothing,
    );
  });

  testWidgets('已下过单的子件行仍可追加：填正数的才下，勾着留 0 的本次不下也不报错', (tester) async {
    final harness = await _pump(
      tester,
      childrenAlreadyOrdered: true,
      previousOrders: true,
    );
    await _openWorkshopBucket(tester);
    await _tapRowCheckbox(tester, '成品A');
    await tester.tap(
      find.byKey(const Key('material-analysis-bucket-action-ready')),
    );
    await tester.pumpAndSettle();
    expect(
      find.byKey(const Key('material-analysis-child-cascade-dialog')),
      findsOneWidget,
    );
    // B 的采购申请还没被采购处理（服务端 growableLineQty）：追加直接改原申请；
    // D 已在处理：追加另立新申请。两行都能填，默认都不勾。
    expect(find.textContaining('PR-0001 20（采购 / 委外还没处理'), findsOneWidget);
    expect(find.textContaining('PR-0002 30（已在处理'), findsOneWidget);
    await tester.enterText(
      find.byKey(const ValueKey('material-analysis-child-cascade-qty-m-b')),
      '10',
    );
    await tester.pumpAndSettle();
    // D 保持默认的 0：两行都勾上也不该报错，0 那行本次直接不下。
    expect(_qtyOf(tester, 'm-d'), '0');
    await _tapDialogRowCheckbox(tester, '外购件B');
    await _tapDialogRowCheckbox(tester, '外购件D');
    await tester.tap(
      find.byKey(const Key('material-analysis-child-cascade-submit')),
    );
    await tester.pumpAndSettle();
    expect(find.textContaining('超出部分属主动追加'), findsOneWidget);
    expect(find.textContaining('另有 1 行追加量填的是 0'), findsOneWidget);
    await tester.tap(find.text('一键下单'));
    await tester.pumpAndSettle();
    // 父件 issue-plans 之后，只有填了正数的那行送采购通知（服务端按超量分账）。
    expect(
      harness.writes.where((r) => r.path.endsWith('/issue-plans')).length,
      1,
    );
    final notify = harness.writes
        .where((request) => request.path.endsWith('/notify'))
        .toList();
    expect(notify, hasLength(1));
    final quantities =
        ((notify.single.data as Map<String, dynamic>)['quantities'] as List)
            .cast<Map<String, dynamic>>();
    expect(
      quantities.map((row) => '${row['actionGroupKey']}=${row['qty']}').toSet(),
      {'ag-b=10.0'},
    );
  });

  testWidgets('单一叶子子件的委外件：父件走下达委外，子件按它填的量重算后一起办', (tester) async {
    final harness = await _pump(tester, soleComponentSubcontract: true);
    await tester.tap(
      find.byKey(const Key('material-analysis-entry-subcontract')),
    );
    await tester.pumpAndSettle();
    await _tapRowCheckbox(tester, '成品A');
    await tester.tap(
      find.byKey(const Key('material-analysis-bucket-action-subcontract')),
    );
    await tester.pumpAndSettle();
    expect(
      find.byKey(const Key('material-analysis-child-cascade-dialog')),
      findsOneWidget,
    );
    // 直接外发的委外通道不模拟下达(它不建计划)，但它填的量要按计划产出量
    // 补给服务端——我方供料的那颗子件得按这个量备(2026-09-21 用户口径：
    // 委外也能超量，多下的量要带大子件需求)。
    final previews = harness.writes
        .where((r) => r.path.endsWith('/issue-plans/preview'))
        .toList();
    expect(previews, hasLength(1));
    final previewBody = previews.single.data as Map<String, dynamic>;
    expect(previewBody['lines'], isEmpty);
    expect(previewBody['typedOutputs'], [
      {'materialLineId': 'root-1', 'qty': 10.0},
    ]);
    expect(_inDialog('外购件B'), findsOneWidget);
    expect(_qtyOf(tester, 'm-b'), '20');
    await tester.tap(
      find.byKey(const Key('material-analysis-child-cascade-submit')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('一键下单'));
    await tester.pumpAndSettle();
    final notify = harness.writes
        .where((request) => request.path.endsWith('/notify'))
        .toList();
    expect(notify, hasLength(2));
    expect(
      (notify.first.data as Map<String, dynamic>)['target'],
      'SUBCONTRACT',
    );
    expect((notify.last.data as Map<String, dynamic>)['target'], 'BUY');
    expect(
      harness.writes.where((r) => r.path.endsWith('/issue-plans')),
      isEmpty,
    );
  });

  testWidgets('有自制子层的顶层委外件：从委外桶进来走 issue-plans，车间由学习默认补上', (tester) async {
    final harness = await _pump(tester, makeFirstSubcontract: true);
    await tester.tap(
      find.byKey(const Key('material-analysis-entry-subcontract')),
    );
    await tester.pumpAndSettle();
    await _tapRowCheckbox(tester, '成品A');
    await tester.tap(
      find.byKey(const Key('material-analysis-bucket-action-subcontract')),
    );
    await tester.pumpAndSettle();
    expect(
      find.byKey(const Key('material-analysis-child-cascade-dialog')),
      findsOneWidget,
    );
    // 预览请求带的是候选物料行 + 学习默认车间。
    final previews = harness.writes
        .where((r) => r.path.endsWith('/issue-plans/preview'))
        .toList();
    expect(previews, hasLength(1));
    final previewLine =
        ((previews.single.data as Map<String, dynamic>)['lines'] as List).single
            as Map<String, dynamic>;
    expect(previewLine['materialLineId'], 'root-1');
    expect(previewLine['departmentId'], 'dept-1');
    expect(_inDialog('外购件B'), findsOneWidget);
    await tester.tap(
      find.byKey(const Key('material-analysis-child-cascade-submit')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('一键下单'));
    await tester.pumpAndSettle();
    final issue = harness.writes
        .where((r) => r.path.endsWith('/issue-plans'))
        .toList();
    expect(issue, hasLength(1));
    final parentLine =
        ((issue.single.data as Map<String, dynamic>)['lines'] as List).single
            as Map<String, dynamic>;
    expect(parentLine['materialLineId'], 'root-1');
    expect(parentLine['departmentId'], 'dept-1');
    expect(parentLine['workerId'], 'emp-1');
    final notify = harness.writes
        .where((r) => r.path.endsWith('/notify'))
        .toList();
    expect(notify, hasLength(1));
    expect((notify.single.data as Map<String, dynamic>)['target'], 'BUY');
  });

  testWidgets('下达车间已下达段：需求已全部转入计划的顶层仍可追加一批公共备货产出', (tester) async {
    final harness = await _pump(
      tester,
      childrenAlreadyOrdered: true,
      topLevelIssued: true,
    );
    await _openWorkshopBucket(tester);
    await _selectSegment(tester, '已下达 (1)');
    // 已下达段的顶层行：桶表只读，「下达数量」列显示已下达的计划量；追加量进页填。
    expect(find.byType(TextField), findsNothing);
    expect(find.text('下达数量'), findsOneWidget);
    await _tapRowCheckbox(tester, '成品A');
    await tester.tap(find.text('追加生产计划(1)…'));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const Key('material-analysis-child-cascade-dialog')),
      findsOneWidget,
    );
    // 追加量默认 0(本次不追加)，在页里改成 5；预览按「纯公共备货产出」显式声明。
    expect(_qtyOf(tester, 'root-1'), '0');
    await _setSeedQty(tester, '5');
    final previews = harness.writes
        .where((r) => r.path.endsWith('/issue-plans/preview'))
        .toList();
    expect(previews, hasLength(1));
    final previewLine =
        ((previews.single.data as Map<String, dynamic>)['lines'] as List).single
            as Map<String, dynamic>;
    expect(previewLine['analysisLineId'], 'p1');
    expect(previewLine['qty'], 5.0);
    expect(previewLine['publicSurplusOnly'], true);
    // 一键下单：上限 0 的树顶先过超量确认；下层都已覆盖 → 直接只提交父件。
    await tester.tap(
      find.byKey(const Key('material-analysis-child-cascade-submit')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('确认超量下达'));
    await tester.pumpAndSettle();
    final issue = harness.writes
        .where((r) => r.path.endsWith('/issue-plans'))
        .toList();
    expect(issue, hasLength(1));
    final line =
        ((issue.single.data as Map<String, dynamic>)['lines'] as List).single
            as Map<String, dynamic>;
    expect(line['analysisLineId'], 'p1');
    expect(line['qty'], 5.0);
    expect(line['publicSurplusOnly'], true);
    expect(line['departmentId'], 'dept-1');
    expect(harness.writes.where((r) => r.path.endsWith('/notify')), isEmpty);
  });

  testWidgets('有自制子层的委外件已下达后仍可在父层级追加：走候选行 ARRANGE 并声明公共备货产出', (tester) async {
    final harness = await _pump(
      tester,
      childrenAlreadyOrdered: true,
      subcontractChildIssued: true,
    );
    await _openWorkshopBucket(tester);
    await _tapRowCheckbox(tester, '成品A');
    await tester.tap(
      find.byKey(const Key('material-analysis-bucket-action-ready')),
    );
    await tester.pumpAndSettle();
    // 委外行不再是「—」：前置自制锚点还能再下一批公共备货产出，所以给输入框，
    // 默认 0。
    expect(_qtyOf(tester, 'm-s'), '0');
    await tester.enterText(
      find.byKey(const ValueKey('material-analysis-child-cascade-qty-m-s')),
      '3',
    );
    await tester.pumpAndSettle();
    await _tapDialogRowCheckbox(tester, '委外件S');
    await tester.tap(
      find.byKey(const Key('material-analysis-child-cascade-submit')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('一键下单'));
    await tester.pumpAndSettle();
    final issue = harness.writes
        .where((r) => r.path.endsWith('/issue-plans'))
        .toList();
    expect(issue, hasLength(2));
    // 下层那一张按**候选行**提交（materialLineId，走 ARRANGE 让委外台账跟量），
    // 并显式声明本次全是追加的公共备货产出。
    final line =
        ((issue.last.data as Map<String, dynamic>)['lines'] as List).single
            as Map<String, dynamic>;
    expect(line['materialLineId'], 'm-s');
    expect(line['analysisLineId'], isNull);
    expect(line['qty'], 3.0);
    expect(line['publicSurplusOnly'], true);
    expect(line['departmentId'], 'dept-1');
  });

  testWidgets('父件尚未提交时退出必须确认，确认后一个写请求都不发', (tester) async {
    final harness = await _pump(tester);
    await _enterCascadeFromWorkshopBucket(tester, '20');
    await tester.tap(
      find.byKey(const Key('material-analysis-child-cascade-discard')),
    );
    await tester.pumpAndSettle();
    expect(find.text('放弃本次下达？'), findsOneWidget);
    await tester.tap(find.text('放弃本次下达').last);
    await tester.pumpAndSettle();
    expect(
      find.byKey(const Key('material-analysis-child-cascade-dialog')),
      findsNothing,
    );
    expect(
      harness.writes.where((r) => !r.path.endsWith('/issue-plans/preview')),
      isEmpty,
    );
  });
}

Finder _inDialog(String text) => find.descendant(
  of: find.byKey(const Key('material-analysis-child-cascade-dialog')),
  matching: find.text(text),
);

/// 改树顶数量并等那份服务端重算回来(去抖 300ms)。
Future<void> _setSeedQty(WidgetTester tester, String qty) async {
  await tester.enterText(
    find.byKey(const ValueKey('material-analysis-child-cascade-qty-root-1')),
    qty,
  );
  await tester.pump(const Duration(milliseconds: 400));
  await tester.pumpAndSettle();
}

/// 下达车间桶 → 勾选成品A → 进「父件 + 下层一起下单」整页 → 在树顶把本批数量
/// 改成 [batchQty](2026-09-22 起外层桶表只读，数量只在页里填；改完等 300ms 去抖
/// 的服务端重算回来)。超量确认改在页里点「一键下单」时才问。
Future<void> _enterCascadeFromWorkshopBucket(
  WidgetTester tester,
  String batchQty,
) async {
  await _openWorkshopBucket(tester);
  await _tapRowCheckbox(tester, '成品A');
  await tester.tap(
    find.byKey(const Key('material-analysis-bucket-action-ready')),
  );
  await tester.pumpAndSettle();
  expect(
    find.byKey(const Key('material-analysis-child-cascade-dialog')),
    findsOneWidget,
  );
  if (batchQty != '10') await _setSeedQty(tester, batchQty);
}

/// 页里点「一键下单」：树顶在本页被改大过就先过一次超量确认，再到确认弹窗。
Future<void> _tapSubmitThroughOverQty(WidgetTester tester) async {
  await tester.tap(
    find.byKey(const Key('material-analysis-child-cascade-submit')),
  );
  await tester.pumpAndSettle();
  if (find.text('确认超量下达').evaluate().isNotEmpty) {
    await tester.tap(find.text('确认超量下达'));
    await tester.pumpAndSettle();
  }
}

/// 按行内文本定位整行（横滚时首列勾选框在冻结包裹层里）并点它的勾选框。
Future<void> _tapRowCheckbox(WidgetTester tester, String text) async {
  final frozen = find.ancestor(
    of: find.text(text).first,
    matching: find.byType(UtenFrozenLeadingColumn),
  );
  final row = frozen.evaluate().isNotEmpty
      ? frozen.first
      : find
            .ancestor(of: find.text(text).first, matching: find.byType(Row))
            .first;
  final checkbox = find
      .descendant(of: row, matching: find.byType(Checkbox))
      .first;
  await tester.ensureVisible(checkbox);
  await tester.pumpAndSettle();
  await tester.tap(checkbox);
  await tester.pumpAndSettle();
}

/// 级联页里按行内文本定位整行并点它的勾选框（页面压在分桶页上，同名文本
/// 只认对话框里的那份）。
Future<void> _tapDialogRowCheckbox(WidgetTester tester, String text) async {
  final row = find
      .ancestor(
        of: _inDialog(text).first,
        matching: find.byType(UtenFrozenLeadingColumn),
      )
      .first;
  final checkbox = find
      .descendant(of: row, matching: find.byType(Checkbox))
      .first;
  await tester.ensureVisible(checkbox);
  await tester.pumpAndSettle();
  await tester.tap(checkbox);
  await tester.pumpAndSettle();
}

String _qtyOf(WidgetTester tester, String materialLineId) => tester
    .widget<TextField>(
      find.byKey(
        ValueKey('material-analysis-child-cascade-qty-$materialLineId'),
      ),
    )
    .controller!
    .text;

/// 分桶页顶部分段（等待下达 / 已下达 / 待处理）。
Future<void> _selectSegment(WidgetTester tester, String label) async {
  final segment = find.descendant(
    of: find.byKey(const Key('material-analysis-task-state')),
    matching: find.text(label),
  );
  await tester.ensureVisible(segment);
  await tester.tap(segment);
  await tester.pumpAndSettle();
}

Future<void> _openWorkshopBucket(WidgetTester tester) async {
  final entry = find.byKey(const Key('material-analysis-entry-workshop'));
  await tester.ensureVisible(entry);
  await tester.pumpAndSettle();
  await tester.tap(entry);
  await tester.pumpAndSettle();
}

/// 写请求之后把快照版本推进一版。
Object? _bumpVersion(Object? data, int writes) {
  if (writes <= 0) return data;
  if (data is Map<String, dynamic> && data['version'] is int) {
    return {
      ...data,
      'version': (data['version'] as int) + writes,
      'fingerprint': 'a' * 63 + '$writes',
    };
  }
  if (data is Map<String, dynamic> && data['analysis'] is Map) {
    return {
      ...data,
      'analysis': _bumpVersion(
        (data['analysis'] as Map).cast<String, dynamic>(),
        writes,
      ),
    };
  }
  return data;
}

class _Harness {
  final List<RequestOptions> writes = [];
}

/// 假后端的「下达预览 / 真实下达之后」快照：按请求里 p1 的本批数量把下层需求
/// 与还需安排量放大（与真实服务端「子件按父件计划产出量展开」同一口径）。
Map<String, dynamic> _scaledAnalysis(
  Map<String, dynamic> analysis,
  RequestOptions request,
) {
  final body = request.data;
  if (body is! Map<String, dynamic>) return analysis;
  final lines = (body['lines'] as List?)?.cast<Map<String, dynamic>>();
  final top = (lines ?? const <Map<String, dynamic>>[]).firstWhere(
    (line) => line['analysisLineId'] == 'p1',
    orElse: () => const <String, dynamic>{},
  );
  final batch = (top['qty'] as num?)?.toDouble();
  // 2026-09-21：层级表上每一行填的数量。服务端按它补齐该节点的计划产出量，
  // 于是中间层改量同样带得动它的子层——本假后端照同一口径算：半成品C 的孙层
  // 外购件D 单件用 3(相对 C)，C 填了多少，D 就是多少 × 3。
  final typed = <String, double>{
    for (final raw in (body['typedOutputs'] as List? ?? const []))
      (raw as Map)['materialLineId'] as String: (raw['qty'] as num).toDouble(),
  };
  if (batch == null && typed.isEmpty) return analysis;
  return {
    ...analysis,
    'flatMaterials': [
      for (final raw in (analysis['flatMaterials'] as List))
        () {
          final material = Map<String, dynamic>.from(raw as Map);
          if (material['nodeRole'] == 'ROOT_SUPPLY') return material;
          final perProduct = (material['perProductQty'] as num).toDouble();
          final baseRequired = (material['requiredQty'] as num).toDouble();
          final baseResidual =
              (material['additionalSupplyRecommendedQty'] as num).toDouble();
          // 已有覆盖（现货 / 在途 / 已下达）原样保留，只有需求随本批数量放大。
          final covered = baseRequired - baseResidual;
          final fromTop = batch == null ? baseRequired : batch * perProduct;
          // 与服务端 parentPlannedOutput 同口径：父件的计划产出量是「祖先算出来
          // 的净需求」与「这一层自己填的数量」取大，所以 typedOutputs 只会把
          // 子层带大，不会把它按过期的旧值压小。
          final parentTyped = material['materialLineId'] == 'm-d'
              ? typed['m-c']
              : null;
          final required = parentTyped != null && parentTyped * 3 > fromTop
              ? parentTyped * 3
              : fromTop;
          final residual = (required - covered).clamp(0.0, double.infinity);
          return material
            ..['requiredQty'] = required
            ..['shortageQty'] = residual
            ..['demandSupplyGapQty'] = residual
            ..['additionalSupplyRecommendedQty'] = residual;
        }(),
    ],
  };
}

Future<_Harness> _pump(
  WidgetTester tester, {
  bool childrenAlreadyOrdered = false,
  bool previousOrders = false,
  bool topLevelIssued = false,
  bool subcontractChildIssued = false,
  bool soleComponentSubcontract = false,
  bool makeFirstSubcontract = false,
}) async {
  tester.view.physicalSize = const Size(1800, 1400);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final harness = _Harness();
  final dio = Dio(BaseOptions(baseUrl: 'http://localhost:8080/api'));
  dio.interceptors.add(
    InterceptorsWrapper(
      onRequest: (request, handler) async {
        if (request.method != 'GET') harness.writes.add(request);
        final base = makeFirstSubcontract
            ? _makeFirstSubcontractAnalysis()
            : soleComponentSubcontract
            ? _soleComponentSubcontractAnalysis()
            : _analysis(
                childrenAlreadyOrdered: childrenAlreadyOrdered,
                previousOrders: previousOrders,
                topLevelIssued: topLevelIssued,
                subcontractChildIssued: subcontractChildIssued,
              );
        final data = switch (request.path) {
          '/master/warehouses/dict' => [
            {'id': 'warehouse-1', 'name': '主仓'},
          ],
          '/production/material-analyses/default-workshops' => [
            for (final goods in ['g-a', 'g-c', 'g-s'])
              {
                'goodsId': goods,
                'departmentId': 'dept-1',
                'departmentName': '一车间',
                'responsibleEmployeeId': 'emp-1',
                'responsibleEmployeeName': '张三',
              },
          ],
          '/production/material-analyses/sales-candidates' => {
            'items': <Object>[],
            'page': 1,
            'size': 20,
            'total': 0,
            'totalPages': 1,
          },
          '/production/material-analyses/analysis-1' => base,
          '/production/material-analyses/analysis-1/notify' => base,
          // 下达预览：真实服务端按同一套代码跑一遍再回滚，返回「下达之后」快照。
          '/production/material-analyses/analysis-1/issue-plans/preview' =>
            _scaledAnalysis(base, request),
          '/production/material-analyses/analysis-1/issue-plans' => {
            'analysis': _scaledAnalysis(base, request),
            'plans': [
              {'planId': 'plan-1', 'planNo': 'PP-1', 'status': 'DRAFT'},
            ],
          },
          _ => <Object>[],
        };
        // 真实服务端只有真的写了东西才会重建快照；预览不算写、不换版本。
        final realWrites = harness.writes
            .where((r) => !r.path.endsWith('/issue-plans/preview'))
            .length;
        handler.resolve(
          Response<dynamic>(
            requestOptions: request,
            statusCode: 200,
            data: _bumpVersion(data, realWrites),
          ),
        );
      },
    ),
  );
  final api = ApiClient(dio);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        productionPlanRepositoryProvider.overrideWithValue(
          ProductionPlanRepository(api),
        ),
        purchaseRepositoryProvider.overrideWith(
          (ref, type) => PurchaseRepository(api, type),
        ),
        masterNameServiceProvider.overrideWithValue(MasterNameService(api)),
        departmentRepositoryProvider.overrideWithValue(_DepartmentRepository()),
        materialAnalysisWarehousePrefsProvider.overrideWith(
          _WarehousePrefs.new,
        ),
        currentPermissionsProvider.overrideWithValue({
          Perm.productionMaterialAnalysisView,
          Perm.productionMaterialAnalysisRoute,
          Perm.productionMaterialAnalysisNotify,
          Perm.productionMaterialAnalysisGenerate,
          Perm.productionMaterialAnalysisOverSupply,
        }),
      ],
      child: const MaterialApp(
        locale: Locale('zh'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: ProductionMaterialAnalysisPage(
          seed: ProductionMaterialAnalysisSeed(
            analysisId: 'analysis-1',
            warehouseId: 'warehouse-1',
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  expect(tester.takeException(), isNull);
  harness.writes.clear();
  return harness;
}

class _DepartmentRepository implements DepartmentRepository {
  @override
  Future<List<DepartmentNode>> tree() async => const [];
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _WarehousePrefs extends MaterialAnalysisWarehousePrefsNotifier {
  @override
  MaterialAnalysisWarehousePrefs build() =>
      const MaterialAnalysisWarehousePrefs();
  @override
  Future<void> syncNow() async {}
  @override
  void update(MaterialAnalysisWarehousePrefs value) {
    state = value.normalized();
  }
}

/// V581 变体：成品A 改成「只有一个叶子子件」的委外件——树顶走委外下达
/// （notify SUBCONTRACT），那颗子件仍要我方采购出来，所以仍进「跟父件一起办」。
Map<String, dynamic> _soleComponentSubcontractAnalysis() {
  final analysis = Map<String, dynamic>.from(
    _analysis(childrenAlreadyOrdered: false),
  );
  analysis['products'] = [
    {
      ...(analysis['products'] as List).first as Map<String, dynamic>,
      'canSchedule': false,
    },
  ];
  analysis['flatMaterials'] = [
    _material(
      id: 'root-1',
      name: '成品A',
      goodsId: 'g-a',
      level: 0,
      nodeKey: 'root',
      perProductQty: 1,
      requiredQty: 10,
      route: 'SUBCONTRACT',
      nodeRole: 'ROOT_SUPPLY',
      actionGroupKey: 'ag-root',
      subcontractOutboundForm: 'COMPONENT_OUTBOUND',
      actionable: true,
    ),
    _material(
      id: 'm-b',
      name: '外购件B',
      goodsId: 'g-b',
      level: 1,
      nodeKey: 'nb',
      perProductQty: 2,
      requiredQty: 20,
      route: 'BUY',
      actionGroupKey: 'ag-b',
    ),
  ];
  return analysis;
}

/// 有自制子层的顶层委外件（ADR-062 先自制后通知）：成品A 路线为委外，BOM 上
/// 还有我方要备的外购件B。ADR-099 起这类行（含顶层供给行）直接走 issue-plans
/// 的 ARRANGE 段，不再走「整量接管的通知通道」。
Map<String, dynamic> _makeFirstSubcontractAnalysis() {
  final analysis = Map<String, dynamic>.from(
    _analysis(childrenAlreadyOrdered: false),
  );
  analysis['products'] = [
    {
      ...(analysis['products'] as List).first as Map<String, dynamic>,
      'canSchedule': false,
    },
  ];
  analysis['flatMaterials'] = [
    _material(
      id: 'root-1',
      name: '成品A',
      goodsId: 'g-a',
      level: 0,
      nodeKey: 'root',
      perProductQty: 1,
      requiredQty: 10,
      route: 'SUBCONTRACT',
      nodeRole: 'ROOT_SUPPLY',
      actionGroupKey: 'ag-root',
      actionable: true,
    ),
    _material(
      id: 'm-b',
      name: '外购件B',
      goodsId: 'g-b',
      level: 1,
      nodeKey: 'nb',
      perProductQty: 2,
      requiredQty: 20,
      route: 'BUY',
      actionGroupKey: 'ag-b',
    ),
    _material(
      id: 'm-e',
      name: '外购件E',
      goodsId: 'g-e',
      level: 1,
      nodeKey: 'ne',
      perProductQty: 1,
      requiredQty: 10,
      route: 'BUY',
      actionGroupKey: 'ag-e',
    ),
  ];
  return analysis;
}

/// [previousOrders]：B 已下采购申请 PR-0001（采购还没处理，服务端给
/// growableLineQty）、D 已下 PR-0002 且已在处理（无 growableLineQty）。
/// [topLevelIssued]：成品A 的需求已全部转入计划（剩余 0、不可再按需求排产），
/// 但服务端允许再追加一批纯公共备货产出（canIssueSurplus）。
/// [subcontractChildIssued]：再挂一个「有自制子层的委外件 S」，它已经建过前置
/// 自制任务（锚点 sub-anchor 剩余 0、仍可再下一批公共备货产出）。
Map<String, dynamic> _analysis({
  required bool childrenAlreadyOrdered,
  bool previousOrders = false,
  bool topLevelIssued = false,
  bool subcontractChildIssued = false,
}) => {
  'overproductionDefaults': {'g-a': 0, 'g-c': 0.1, 'g-s': 0},
  'analysisId': 'analysis-1',
  'status': 'ACTIVE',
  'version': 3,
  'fingerprint': 'a' * 64,
  'warehouseId': 'warehouse-1',
  'warehouseIds': ['warehouse-1'],
  'allowedActions': [
    'VIEW',
    'CONFIRM_ROUTES',
    'NOTIFY_SUPPLY',
    'GENERATE_PLAN',
    'OVER_SUPPLY',
  ],
  'products': [
    {
      'analysisLineId': 'p1',
      'sourceType': 'STOCK',
      'rootMaterialLineId': 'root-1',
      'salesOrderItemId': 'soi-1',
      'salesOrderNo': 'SO-0001',
      'goodsId': 'g-a',
      'goodsCode': 'A-001',
      'goodsName': '成品A',
      'unitName': '件',
      'requestedQty': 10,
      'remainingQty': topLevelIssued ? 0 : 10,
      'readyNowQty': 0,
      'canSchedule': !topLevelIssued,
      'maxSchedulableQty': topLevelIssued ? 0 : 10,
      'hasProductionMaterialChildren': true,
      if (topLevelIssued) ...{
        'submittedQty': 10,
        'approvedQty': 10,
        'issuedPlanQty': 10,
        'canIssueSurplus': true,
        'scheduleBlockedReason': '当前分析需求已全部转入生产计划',
        'planExecutionStatus': 'IN_PROGRESS',
        'latestPlanId': 'plan-1',
        'latestPlanNo': 'PP-1',
        'planExecutionPlannedQty': 10,
        'planExecutionInboundQty': 0,
      },
    },
    if (subcontractChildIssued)
      {
        'analysisLineId': 'sub-anchor',
        'sourceType': 'SUBCONTRACT_MAKE',
        'parentAnalysisLineId': 'p1',
        'goodsId': 'g-s',
        'goodsCode': 'g-s-code',
        'goodsName': '委外件S',
        'unitName': '个',
        'requestedQty': 10,
        'submittedQty': 10,
        'approvedQty': 10,
        'remainingQty': 0,
        'issuedPlanQty': 10,
        'canIssueSurplus': true,
        'canSchedule': false,
        'maxSchedulableQty': 0,
        'scheduleBlockedReason': '当前分析需求已全部转入生产计划',
        'readyNowQty': 0,
        'planExecutionStatus': 'WAITING',
        'latestPlanId': 'plan-s',
        'planExecutionPlannedQty': 10,
      },
  ],
  'flatMaterials': [
    _material(
      id: 'root-1',
      name: '成品A',
      goodsId: 'g-a',
      level: 0,
      nodeKey: 'root',
      perProductQty: 1,
      requiredQty: 10,
      route: 'MAKE',
      nodeRole: 'ROOT_SUPPLY',
      actionGroupKey: 'ag-root',
    ),
    _material(
      id: 'm-b',
      name: '外购件B',
      goodsId: 'g-b',
      level: 1,
      nodeKey: 'nb',
      perProductQty: 2,
      requiredQty: 20,
      route: 'BUY',
      actionGroupKey: 'ag-b',
      covered: childrenAlreadyOrdered,
      previousOrder: previousOrders
          ? (documentNo: 'PR-0001', qty: 20.0, growable: true)
          : null,
    ),
    _material(
      id: 'm-c',
      name: '半成品C',
      goodsId: 'g-c',
      level: 1,
      nodeKey: 'nc',
      perProductQty: 1,
      requiredQty: 10,
      route: 'MAKE',
      actionGroupKey: 'ag-c',
      covered: childrenAlreadyOrdered,
    ),
    _material(
      id: 'm-d',
      name: '外购件D',
      goodsId: 'g-d',
      level: 2,
      nodeKey: 'nc/nd',
      parentNodeKey: 'nc',
      perProductQty: 3,
      requiredQty: 30,
      route: 'BUY',
      actionGroupKey: 'ag-d',
      covered: childrenAlreadyOrdered,
      previousOrder: previousOrders
          ? (documentNo: 'PR-0002', qty: 30.0, growable: false)
          : null,
    ),
    if (subcontractChildIssued) ...[
      _material(
        id: 'm-s',
        name: '委外件S',
        goodsId: 'g-s',
        level: 1,
        nodeKey: 'ns',
        perProductQty: 1,
        requiredQty: 10,
        route: 'SUBCONTRACT',
        actionGroupKey: 'ag-s',
        covered: true,
        planAnchorAnalysisLineId: 'sub-anchor',
      ),
      // S 的子层：有它 S 才算「要先自制目标件再发外」。
      _material(
        id: 'm-s-child',
        name: '委外子件SC',
        goodsId: 'g-sc',
        level: 2,
        nodeKey: 'ns/nsc',
        parentNodeKey: 'ns',
        perProductQty: 1,
        requiredQty: 10,
        route: 'BUY',
        actionGroupKey: 'ag-sc',
        covered: true,
      ),
    ],
  ],
  'warehouses': [
    {'warehouseId': 'warehouse-1', 'warehouseName': '主仓'},
  ],
};

Map<String, dynamic> _material({
  required String id,
  required String name,
  required String goodsId,
  required int level,
  required String nodeKey,
  required double perProductQty,
  required double requiredQty,
  required String route,
  required String actionGroupKey,
  String? parentNodeKey,
  String nodeRole = 'BOM_COMPONENT',
  bool covered = false,
  String? subcontractOutboundForm,
  bool? actionable,
  ({String documentNo, double qty, bool growable})? previousOrder,
  String? planAnchorAnalysisLineId,
}) => {
  'subcontractOutboundForm': subcontractOutboundForm,
  'planAnchorAnalysisLineId': ?planAnchorAnalysisLineId,
  if (previousOrder != null)
    'notifiedTargets': [
      {
        'target': route,
        'actionId': 'act-$id',
        'documentType': 'PURCHASE_REQUEST',
        'documentId': 'doc-$id',
        'documentNo': previousOrder.documentNo,
        'status': 'CREATED',
        'allocatedQty': previousOrder.qty,
        if (previousOrder.growable) 'growableLineQty': previousOrder.qty,
      },
    ],
  'materialLineId': id,
  'analysisLineId': 'p1',
  'nodeRole': nodeRole,
  'nodeKey': nodeKey,
  'parentNodeKey': parentNodeKey,
  'goodsId': goodsId,
  'goodsCode': '$goodsId-code',
  'goodsName': name,
  'unitName': '件',
  'level': level,
  'actionable': actionable ?? level > 0,
  'actionGroupKey': actionGroupKey,
  'materialKey': goodsId,
  'perProductQty': perProductQty,
  'requiredQty': requiredQty,
  'availableQty': covered ? requiredQty : 0,
  'allocatedAvailableQty': covered ? requiredQty : 0,
  'shortageQty': covered ? 0 : requiredQty,
  'demandSupplyGapQty': covered ? 0 : requiredQty,
  'additionalSupplyRecommendedQty': covered ? 0 : requiredQty,
  'sourceSuggestion': route,
  'sourceConfirmed': route,
  'routeConfirmed': true,
  'warehouseBreakdown': <Object>[],
};
