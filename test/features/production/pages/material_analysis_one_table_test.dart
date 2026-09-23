// ADR-102「一张表」：把分桶详情页与「父件 + 下层一起下单」弹窗的能力搬进主
// 物料表之后，这张表上新增的行为由本文件守着。
//
// 守的是**口径**不是像素：哪一行能填数、填的是「下单数量」还是「追加下单」、
// 哪一行的办理按钮该灰、没确认路线时表现成什么样。
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/theme/light_theme.dart';
import 'package:uten_imp/features/production/models/production_material_analysis.dart';
import 'package:uten_imp/features/production/pages/production_material_analysis_page.dart';
import 'package:uten_imp/features/production/providers/material_analysis_warehouse_prefs_provider.dart';
import 'package:uten_imp/features/production/repositories/production_repository.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/providers/master_name_provider.dart';

const _permissions = {
  Perm.productionMaterialAnalysisView,
  Perm.productionMaterialAnalysisRoute,
  Perm.productionMaterialAnalysisNotify,
  Perm.productionMaterialAnalysisCrossReallocate,
};

/// 已下达的行要追加(还需安排为 0 却再下)属超量, 勾选 / 提交都要超量权限
/// (服务端 allowedActions 也要带 OVER_SUPPLY, 见 _pump 的 overSupply)。
const _overSupplyPermissions = {
  ..._permissions,
  Perm.productionMaterialAnalysisOverSupply,
};

/// 提交单元身份：`NODE|<actionGroupKey>|<materialLineId>`。
String _groupKey(String line) => 'NODE|a-$line|$line';

String _qtyText(WidgetTester tester, Finder field) =>
    tester.widget<TextField>(field).controller!.text;

Finder _orderQty(String line) =>
    find.byKey(ValueKey('material-analysis-order-qty-${_groupKey(line)}'));
Finder _appendQty(String line) =>
    find.byKey(ValueKey('material-analysis-append-qty-${_groupKey(line)}'));
Finder _transferButton(String line) => find.byKey(
  ValueKey('material-analysis-handle-transfer-${_groupKey(line)}'),
);
Finder _issueButton(String line) =>
    find.byKey(ValueKey('material-analysis-handle-issue-${_groupKey(line)}'));

bool _enabled(WidgetTester tester, Finder finder) =>
    tester.widget<InkWell>(finder).onTap != null;

/// 这一行的勾选框此刻勾没勾(行必须有勾选框, 没有就直接失败)。
bool _rowChecked(WidgetTester tester, String line) =>
    tester
        .widget<Checkbox>(
          find.descendant(
            of: find.byKey(ValueKey('material-table-row-$line')),
            matching: find.byType(Checkbox),
          ),
        )
        .value ==
    true;

Finder _rowCheckbox(String line) => find.descendant(
  of: find.byKey(ValueKey('material-table-row-$line')),
  matching: find.byType(Checkbox),
);

/// 敲键后停手 200ms 那次整页刷新(勾选框 / 底部按钮 / 底色都在那一拍才变)。
/// pumpAndSettle 只等有帧要画, 不等定时器, 所以要明确推过 200ms; 悬浮的批量
/// 按钮组随后还要一两帧才落位, 再 settle 一次。
Future<void> _settleRebuild(WidgetTester tester) async {
  await tester.pump(const Duration(milliseconds: 250));
  await tester.pumpAndSettle();
}

/// 去抖 300ms 后服务端那趟预览回来并装上(同样是定时器驱动, 要明确推时间)。
Future<void> _settlePreview(WidgetTester tester) async {
  await tester.pump(const Duration(milliseconds: 400));
  await tester.pumpAndSettle();
}

/// 数量框此刻是不是被 RequiredCellFrame 描了红边(它把红边交给最近那层 Theme 的
/// inputDecorationTheme 来画)。
bool _framedRed(WidgetTester tester, Finder field) {
  final theme = tester.widget<Theme>(
    find.ancestor(of: field, matching: find.byType(Theme)).first,
  );
  final border = theme.data.inputDecorationTheme.enabledBorder;
  return border is OutlineInputBorder &&
      border.borderSide.color == theme.data.colorScheme.error;
}

void main() {
  testWidgets('列定稿为 15 列，四列新增列都在表头里', (tester) async {
    await _pump(tester);
    expect(find.text('表头设置 15/15'), findsOneWidget);
    for (final label in const [
      '物料办理',
      '物料名称',
      '编号',
      '颜色',
      '单位',
      '供应方式',
      '需要数量',
      '还缺数量',
      '下单数量',
      '追加下单',
      '所属仓库',
      '归属车间',
      '生产车间',
      '负责人',
      '进度 / 待办',
    ]) {
      expect(find.text(label), findsWidgets, reason: '表头缺少「$label」列');
    }
    // 退役的四列不能再出现。
    for (final retired in const ['可用数量', '在途未到', '公共认领未实收', '在途调拨']) {
      expect(find.text(retired), findsNothing, reason: '「$retired」列应已退役');
    }
  });

  testWidgets('没确认路线的行：供应方式框标红、不给填数、也下不了单', (tester) async {
    await _pump(tester);
    // 红框是这一行唯一的入口提示。
    expect(
      find.byKey(const ValueKey('material-route-pending-m-1')),
      findsOneWidget,
    );
    // 已确认的行不该有红框。
    expect(
      find.byKey(const ValueKey('material-route-pending-m-2')),
      findsNothing,
    );
    // 路线未定 = 两个数量格都不给填。
    expect(_orderQty('m-1'), findsNothing);
    expect(_appendQty('m-1'), findsNothing);
    // 2026-09-22 用户口径「物料办理只要调拨」: 这一列不再有下达按钮, 整表一个都没有。
    expect(_issueButton('m-1'), findsNothing);
    expect(
      find.byKey(const ValueKey('material-analysis-handle-issue-any')),
      findsNothing,
    );
    // 调拨按钮照常在(置灰), 这一列没被整个抹掉。
    expect(_transferButton('m-1'), findsOneWidget);
  });

  testWidgets('确认过路线但没下过单的行：下单数量可填并预填还缺数量，追加下单恒为只读 0', (tester) async {
    await _pump(tester);
    final field = tester.widget<TextField>(_orderQty('m-2'));
    expect(field.enabled, isTrue);
    expect(field.controller!.text, '500');
    // 还没下过单就没有「追加」可言，避免两列都能填造成歧义。
    expect(_appendQty('m-2'), findsNothing);
  });

  testWidgets('已下达的行：下单数量锁死并显示累计已下单量，改填追加下单', (tester) async {
    await _pump(tester);
    // 下单数量格换成只读的累计值，不再是输入框。
    expect(_orderQty('m-3'), findsNothing);
    // 追加格可填，默认 0 = 本次不动它。
    final append = tester.widget<TextField>(_appendQty('m-3'));
    expect(append.enabled, isTrue);
    expect(append.controller!.text, '0');
    // 「追加」这个语义现在只由追加下单格承载, 办理列不再有下达/追加按钮。
    expect(_issueButton('m-3'), findsNothing);
  });

  testWidgets('主表追加格也带动子层：在已下达父件的追加格填数，子件按新数量重算', (tester) async {
    await _pump(tester);
    // 已下达的自制父件两格都在(下单数量 + 追加下单)，它们是同一个提交单元的
    // 两半；子件此刻按权威快照是 600。
    expect(find.text('已下达委外父件'), findsWidgets);
    expect(find.text('父件的子件'), findsWidgets);
    expect(_qtyText(tester, _appendQty('m-p')), '0');
    expect(_qtyText(tester, _orderQty('m-pc')), '600');

    await tester.enterText(_appendQty('m-p'), '1500');
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();

    // 追加格填的数要进 typedOutputs，否则子层纹丝不动(这一条原来是断的)。
    expect(previews, isNotEmpty);
    expect(previews.last['typedOutputs'], [
      {'materialLineId': 'm-p', 'qty': 1500.0},
    ]);
    expect(previews.last['lines'], isEmpty);
    // 子件跟着重算后的数走。
    expect(_qtyText(tester, _orderQty('m-pc')), '1500');
  });

  testWidgets('父行改量后子件的还缺数量与下单预填都跟着重算后的快照走', (tester) async {
    await _pump(tester);
    final shortage = find.byKey(
      const ValueKey('material-analysis-net-shortage-m-pc'),
    );
    expect(tester.widget<Tooltip>(shortage).message, contains('还要另外下 600'));

    await tester.enterText(_appendQty('m-p'), '1500');
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();

    // 「还缺数量」与「下单数量」预填同源；「需要数量」列现在读的也是这份重算
    // 快照(原先它直读权威快照，同一行会出现「需要 1000 / 还缺 1500」的矛盾)。
    expect(tester.widget<Tooltip>(shortage).message, contains('还要另外下 1500'));
    expect(_qtyText(tester, _orderQty('m-pc')), '1500');
  });

  testWidgets('两格都空 = 交还系统算：清掉追加格后不再送这一行的数', (tester) async {
    await _pump(tester);
    await tester.enterText(_appendQty('m-p'), '1500');
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();
    expect(previews.last['typedOutputs'], isNotEmpty);

    final sent = previews.length;
    await tester.enterText(_appendQty('m-p'), '');
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();
    // 手滑敲一下再删掉不能让这一行永久脱离跟随：模拟快照当场作废、子件回到
    // 权威快照的 600，而且不必再问服务端一次(没有要送的数量了)。
    expect(previews, hasLength(sent));
    expect(_qtyText(tester, _orderQty('m-pc')), '600');
  });

  testWidgets('敲一下当场变：父行填数的那一拍子件就按比例换算好，不等服务端那趟', (tester) async {
    await _pump(tester);
    final shortage = find.byKey(
      const ValueKey('material-analysis-net-shortage-m-pc'),
    );
    expect(tester.widget<Tooltip>(shortage).message, contains('还要另外下 600'));

    await tester.enterText(_appendQty('m-p'), '1500');
    // 只推一帧、不推时间：去抖还没到，服务端一趟都没发。
    await tester.pump();
    expect(previews, isEmpty);
    // 估算：父件已下 1000、再追加 1500 → 产出 2500 = 2.5 倍；子件需求 1000 → 2500，
    // 已覆盖的 400 是不变量，还需安排 2100。三列一起变。
    expect(find.text('2500'), findsOneWidget);
    expect(tester.widget<Tooltip>(shortage).message, contains('还要另外下 2100'));
    expect(_qtyText(tester, _orderQty('m-pc')), '2100');

    // 300ms 后服务端那份回来(假后端按 1500 展开)，整体覆盖估算值。
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();
    expect(previews, hasLength(1));
    expect(tester.widget<Tooltip>(shortage).message, contains('还要另外下 1500'));
    expect(_qtyText(tester, _orderQty('m-pc')), '1500');
  });

  testWidgets('填了又立刻清空：子件当场回落到快照值，一次服务端都不问', (tester) async {
    await _pump(tester);
    await tester.enterText(_appendQty('m-p'), '1500');
    await tester.pump();
    expect(_qtyText(tester, _orderQty('m-pc')), '2100');

    await tester.enterText(_appendQty('m-p'), '');
    await tester.pump();
    expect(_qtyText(tester, _orderQty('m-pc')), '600');
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();
    expect(previews, isEmpty);
    expect(_qtyText(tester, _orderQty('m-pc')), '600');
  });

  testWidgets('服务端那份回来之后再改：从模拟快照起算比例，不是从权威快照', (tester) async {
    await _pump(tester);
    await tester.enterText(_appendQty('m-p'), '1500');
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();
    expect(_qtyText(tester, _orderQty('m-pc')), '1500');

    // 分母摆到「请求时那份填数」上：父件产出 1000 + 1500 = 2500 → 1000 + 3000 = 4000，
    // 比例 1.6；子件在模拟快照里是 1500(没有覆盖量) → 2400。
    await tester.enterText(_appendQty('m-p'), '3000');
    await tester.pump();
    expect(previews, hasLength(1));
    expect(_qtyText(tester, _orderQty('m-pc')), '2400');

    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();
    expect(previews, hasLength(2));
    expect(_qtyText(tester, _orderQty('m-pc')), '3000');
  });

  testWidgets('顶层产品行改数：整棵树当场按比例变，而且会去问服务端(原来判成没有下层)', (tester) async {
    await _pump(tester);
    expect(_qtyText(tester, _orderQty('m-6')), '400');
    expect(_qtyText(tester, _orderQty('m-pc')), '600');

    // 顶层需求 1000、本次填 1200 → 1.2 倍。第 1 层子件的 parentNodeKey 是空的，
    // 按原始桶查顶层永远「没有下层」——既不换算也不发请求，正是用户实机看到的
    // 「主表改数值没反应」。
    await tester.enterText(_orderQty('m-root'), '1200');
    await tester.pump();
    expect(previews, isEmpty);
    // 自制子件：需求 1000 → 1200，已覆盖 600 不变 → 还需 600。
    expect(_qtyText(tester, _orderQty('m-6')), '600');
    // 已下达的委外父件 m-p 跟着变(已下 1000 + 还需 200 = 1200)，它的子件再按 1.2 倍：
    // 需求 1200、已覆盖 400 → 还需 800。
    expect(_qtyText(tester, _orderQty('m-pc')), '800');

    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();
    expect(previews.last['typedOutputs'], [
      {'materialLineId': 'm-root', 'qty': 1200.0},
    ]);
  });

  testWidgets('数量填少了 / 填错了当场冒红，改对了红框就消失；父行改大让子行缺了也冒红', (tester) async {
    await _pump(tester);
    // 自制外壳：还需安排 400，预填 400 → 不红。
    expect(_framedRed(tester, _orderQty('m-6')), isFalse);
    await tester.enterText(_orderQty('m-6'), '300');
    await tester.pump();
    expect(_framedRed(tester, _orderQty('m-6')), isTrue);
    await tester.enterText(_orderQty('m-6'), '');
    await tester.pump();
    expect(_framedRed(tester, _orderQty('m-6')), isTrue);
    await tester.enterText(_orderQty('m-6'), '400');
    await tester.pump();
    expect(_framedRed(tester, _orderQty('m-6')), isFalse);
    // 多填不红：超出部分按公共备货记账。
    await tester.enterText(_orderQty('m-6'), '900');
    await tester.pump();
    expect(_framedRed(tester, _orderQty('m-6')), isFalse);

    // 子件亲手填了 700(此刻还需安排 600，多填不红)，父件再追加 1500 → 子件还需
    // 安排当场变成 2100，700 就是「缺的」，那一拍就冒红；不必等服务端。
    // (填 600 会与系统预填值相同，被当成没动过而跟着回填成 2100——那不叫缺。)
    await tester.enterText(_orderQty('m-pc'), '700');
    await tester.pump();
    expect(_framedRed(tester, _orderQty('m-pc')), isFalse);
    await tester.enterText(_appendQty('m-p'), '1500');
    await tester.pump();
    expect(previews, isEmpty);
    expect(_framedRed(tester, _orderQty('m-pc')), isTrue);
    await tester.enterText(_orderQty('m-pc'), '2100');
    await tester.pump();
    expect(_framedRed(tester, _orderQty('m-pc')), isFalse);
    // 追加格：填多少都行(追加的是额外的量, 不跟还需安排比)，0 也合法；清空 / 负数才红。
    expect(_framedRed(tester, _appendQty('m-p')), isFalse);
    await tester.enterText(_appendQty('m-p'), '1');
    await tester.pump();
    expect(_framedRed(tester, _appendQty('m-p')), isFalse);
    await tester.enterText(_appendQty('m-p'), '0');
    await tester.pump();
    expect(_framedRed(tester, _appendQty('m-p')), isFalse);
    await tester.enterText(_appendQty('m-p'), '-1');
    await tester.pump();
    expect(_framedRed(tester, _appendQty('m-p')), isTrue);
    await tester.enterText(_appendQty('m-p'), '');
    await tester.pump();
    expect(_framedRed(tester, _appendQty('m-p')), isTrue);
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();
  });

  testWidgets('父件追加带动已下过单的子件：刚好下够的子件追加格自动填上新缺口并替他勾上', (tester) async {
    await _pump(tester, permissions: _overSupplyPermissions, overSupply: true);
    // 子件之前刚好下够(需求 1000 = 现货 200 + 已订 800)：缺口 0，追加格 0，没勾。
    expect(_qtyText(tester, _appendQty('m-qc1')), '0');
    expect(_rowChecked(tester, 'm-qc1'), isFalse);

    // 父件(已下 1000)追加 200 → 1.2 倍 → 子件需求 1200、还缺 200：那一拍追加格就是 200，
    // 不等服务端(用户口径「父组件追加 200, 子组件追加那里也自动追加 200」)。
    await tester.enterText(_appendQty('m-q'), '200');
    await tester.pump();
    expect(previews, isEmpty);
    expect(_qtyText(tester, _appendQty('m-qc1')), '200');
    expect(
      tester
          .widget<Tooltip>(
            find.byKey(const ValueKey('material-analysis-net-shortage-m-qc1')),
          )
          .message,
      contains('还要另外下 200'),
    );
    // 停手 200ms 后那次整页刷新：有数的行替他勾上(亲手填数的父件也勾上)，
    // 底部「下单(2)」。
    await _settleRebuild(tester);
    expect(_rowChecked(tester, 'm-qc1'), isTrue);
    expect(_rowChecked(tester, 'm-q'), isTrue);
    expect(find.text('下单(2)'), findsOneWidget);
    // 服务端那份回来(按 200 展开)：追加格与勾选都保持。
    await _settlePreview(tester);
    expect(previews, hasLength(1));
    expect(_qtyText(tester, _appendQty('m-qc1')), '200');
    expect(_rowChecked(tester, 'm-qc1'), isTrue);

    // 父件清空追加 → 子件回落到 0，替他勾的那个勾撤掉，父件自己也撤掉。
    await tester.enterText(_appendQty('m-q'), '');
    await tester.pump();
    expect(_qtyText(tester, _appendQty('m-qc1')), '0');
    await _settleRebuild(tester);
    expect(_rowChecked(tester, 'm-qc1'), isFalse);
    expect(_rowChecked(tester, 'm-q'), isFalse);
    expect(find.text('下单(2)'), findsNothing);
    await _settlePreview(tester);
  });

  testWidgets('多下过的子件在父件追加时一颗都不缺：追加格保持 0、不替他勾', (tester) async {
    await _pump(tester, permissions: _overSupplyPermissions, overSupply: true);
    expect(_qtyText(tester, _appendQty('m-rc')), '0');
    // 子件需求 1000 → 1200，但它之前订了 2400(现货另有 200)，仍全被盖住——
    // 服务端封顶的还需安排看不出多下的那 1400，页面按不封顶的覆盖量算。
    await tester.enterText(_appendQty('m-r'), '200');
    await tester.pump();
    expect(find.text('1200'), findsOneWidget);
    expect(_qtyText(tester, _appendQty('m-rc')), '0');
    await _settleRebuild(tester);
    expect(_rowChecked(tester, 'm-rc'), isFalse);
    expect(_rowChecked(tester, 'm-r'), isTrue);
    expect(find.text('下单(1)'), findsOneWidget);
    await _settlePreview(tester);
    expect(previews, hasLength(1));
    expect(_qtyText(tester, _appendQty('m-rc')), '0');
    // 追加到 1700 才开始缺：需求 2700 − 覆盖 2600 = 100(从模拟快照起算比例)。
    await tester.enterText(_appendQty('m-r'), '1700');
    await tester.pump();
    expect(_qtyText(tester, _appendQty('m-rc')), '100');
    await _settleRebuild(tester);
    expect(_rowChecked(tester, 'm-rc'), isTrue);
    expect(find.text('下单(2)'), findsOneWidget);
    // 服务端那份回来(同一口径)：保持。
    await _settlePreview(tester);
    expect(previews, hasLength(2));
    expect(_qtyText(tester, _appendQty('m-rc')), '100');
    expect(_rowChecked(tester, 'm-rc'), isTrue);
  });

  testWidgets('子件追加格亲手填过就不跟父件走；亲手撤过的勾父件再改也不替他勾回来', (tester) async {
    await _pump(tester, permissions: _overSupplyPermissions, overSupply: true);
    await tester.enterText(_appendQty('m-qc1'), '50');
    await _settleRebuild(tester);
    // 亲手填了数 = 要下的行：勾上。
    expect(_rowChecked(tester, 'm-qc1'), isTrue);
    // 亲手撤掉。
    await tester.tap(_rowCheckbox('m-qc1'));
    await tester.pumpAndSettle();
    expect(_rowChecked(tester, 'm-qc1'), isFalse);

    await tester.enterText(_appendQty('m-q'), '200');
    await tester.pump();
    // 亲手填的 50 保留(父件把缺口抬到 200 也不覆盖)，勾也不替他勾回来；
    // 「还缺数量」照实说它缺 200。
    expect(_qtyText(tester, _appendQty('m-qc1')), '50');
    expect(
      tester
          .widget<Tooltip>(
            find.byKey(const ValueKey('material-analysis-net-shortage-m-qc1')),
          )
          .message,
      contains('还要另外下 200'),
    );
    await _settleRebuild(tester);
    expect(_rowChecked(tester, 'm-qc1'), isFalse);
    await _settlePreview(tester);
    expect(_qtyText(tester, _appendQty('m-qc1')), '50');
    expect(_rowChecked(tester, 'm-qc1'), isFalse);
  });

  testWidgets('物料办理：有别的计划锁着的量才可调拨，没有就置灰并说明', (tester) async {
    await _pump(tester);
    // 夹具只给 m-2 返回了可调拨量。
    expect(_enabled(tester, _transferButton('m-2')), isTrue);
    expect(_enabled(tester, _transferButton('m-3')), isFalse);
    expect(
      tester
          .widget<Tooltip>(
            find.ancestor(
              of: _transferButton('m-3'),
              matching: find.byType(Tooltip),
            ),
          )
          .message,
      contains('没有别的计划锁着这个物料'),
    );
  });

  testWidgets('勾选换义：确认过路线的行现在可勾，底部出现「下单(N)」', (tester) async {
    await _pump(tester);
    // 换义前只有「未确认路线」的行有勾选框；现在可下单的行也有。
    final row = find.byKey(const ValueKey('material-table-row-m-2'));
    expect(row, findsOneWidget);
    expect(
      find.descendant(of: row, matching: find.byType(Checkbox)),
      findsOneWidget,
    );
    await tester.tap(find.descendant(of: row, matching: find.byType(Checkbox)));
    await tester.pumpAndSettle();
    expect(find.text('下单(1)'), findsOneWidget);
    // 路线按钮仍在，两个动作各算各的数：m-2 已确认，不计进确认路线。
    expect(find.text('确认路线(0)'), findsOneWidget);
  });

  testWidgets('自制行的下单数量可填：预填毛量, 不再是只读的整批接管', (tester) async {
    await _pump(tester);
    // 2026-09-22 修订：锁死自制行的理由(服务端要求逐字等于剩余需求)引错了对象 ——
    // 那条校验长在 notifySupply 里, 而自制行在更靠前的地方就被拦掉、根本走不到;
    // 自制行实际走 issue-plans, 那条路按 V577 接受任意数量。
    final field = tester.widget<TextField>(_orderQty('m-6'));
    expect(field.enabled, isTrue);
    expect(field.controller!.text, '400');
    // 还没下达过, 追加格仍是只读的(避免两列都能填的歧义)。
    expect(_appendQty('m-6'), findsNothing);
  });

  testWidgets('顶层行不再是一排横杠：调拨按钮、下单数量、还缺数量都在', (tester) async {
    await _pump(tester);
    // 产品行直接承载 ROOT_SUPPLY(V478)。原来 _tableEditableGroup 对产品行一律
    // 早退, 导致办理/下单/追加/车间/负责人五列全横杠, 而「还缺数量」走另一套判据
    // 会显示真实数字 —— 同一行左边看得见缺口、右边办不了事。
    expect(_transferButton('m-root'), findsOneWidget);
    final field = tester.widget<TextField>(_orderQty('m-root'));
    expect(field.enabled, isTrue);
    expect(field.controller!.text, '600');
  });

  testWidgets('有公共在途可认领时：还缺数量显示净数，下单数量预填毛量', (tester) async {
    await _pump(tester);
    // 这一行需求覆盖 1000，其中 300 下达时服务端会自动从公共在途认领。
    // 「还缺数量」按用户口径显示净数 700。
    final tooltip = tester.widget<Tooltip>(
      find.byKey(const ValueKey('material-analysis-net-shortage-m-4')),
    );
    expect(tooltip.message, contains('还要另外下 700'));
    expect(tooltip.message, contains('已按公共在途扣减 300'));
    // 但「下单数量」必须预填毛量 1000：服务端是从你填的数里切走认领量、
    // 不是在它之上另加。填 700 只会换来「认领 300 + 新单 400 = 700」，
    // 对着 1000 的需求仍差 300 —— 每一行都少下一个认领量。
    expect(tester.widget<TextField>(_orderQty('m-4')).controller!.text, '1000');
    // 悬浮说明要把这个「两个数不一样」讲清楚，别让人以为填错了。
    expect(tooltip.message, contains('本次要覆盖的总量 1000'));
  });

  testWidgets('从别的计划调拨进来的量不算已下单，这一行照样能正常下单', (tester) async {
    await _pump(tester);
    // m-5 有一条 FUTURE_TRANSFER 分摊，但一张订货单都没下过。
    // 它不该被当成「已下达」——否则下单格锁死、追加默认 0、批量下单静默跳过它。
    expect(_orderQty('m-5'), findsOneWidget);
    expect(_appendQty('m-5'), findsNothing);
    // 追加格不出现本身就说明这一行没被当成「已下达」(已下达才给追加格)。
    expect(_issueButton('m-5'), findsNothing);
  });

  testWidgets('还缺数量的悬浮说明接住了退役三列的事实', (tester) async {
    await _pump(tester);
    final tooltip = tester.widget<Tooltip>(
      find.byKey(const ValueKey('material-analysis-net-shortage-m-2')),
    );
    expect(tooltip.message, contains('还要另外下 500'));
    // 「可用数量」「在途未到」并进这里，不再各占一列。
    expect(tooltip.message, contains('仓库现在可用 200'));
    expect(tooltip.message, contains('已安排但还没合格入库 100'));
    // 实物缺口是另一个口径，必须分开讲清楚。
    expect(tooltip.message, contains('实物缺口仍是 800'));
  });
}

/// 本次 pump 期间发出的每一份「下达预览」请求体，供断言 typedOutputs。
final List<Map<String, dynamic>> previews = [];

Future<void> _pump(
  WidgetTester tester, {
  Set<String> permissions = _permissions,
  // 夹具已有十几行物料, 视口给高一点: 页面级滚动下看不见的行不会被建出来,
  // 排在后面的行(以及别的用例 mutate 追加的行)的输入框会找不到。
  Size size = const Size(1800, 1800),
  bool overSupply = false,
}) async {
  previews.clear();
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pump();
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  var data = _analysis(overSupply: overSupply);
  final dio = Dio(BaseOptions(baseUrl: 'http://localhost:8080/api'));
  dio.interceptors.add(
    InterceptorsWrapper(
      onRequest: (request, handler) {
        Object result = <Object>[];
        if (request.path == '/master/warehouses/dict') {
          result = [
            {'id': 'main', 'name': '综合主仓', 'code': '001'},
            {
              'id': 'warehouse-1',
              'name': '原料子仓',
              'code': '010',
              'parentId': 'main',
            },
          ];
        } else if (request.path.endsWith('/transferable-in-summary')) {
          // 只有 m-2 能从别的计划调进来。
          result = {
            'qtyByMaterialLineId': {'m-2': 120},
          };
        } else if (request.path.endsWith('/default-workshops')) {
          result = <String, dynamic>{};
        } else if (request.path.endsWith('/issue-plans/preview')) {
          // 回滚式预览：按请求里 typedOutputs 把子层需求放大(与服务端「子件按
          // 父件计划产出量展开」同一口径)，并记下这次送了什么供断言。
          final body = request.data as Map<String, dynamic>;
          previews.add(body);
          final typed = {
            for (final raw in (body['typedOutputs'] as List? ?? const []))
              (raw as Map)['materialLineId'] as String: (raw['qty'] as num)
                  .toDouble(),
          };
          final scaled = jsonDecode(jsonEncode(data)) as Map<String, dynamic>;
          final parent = typed['m-p'];
          if (parent != null) {
            for (final raw in (scaled['flatMaterials'] as List)) {
              final material = raw as Map<String, dynamic>;
              if (material['materialLineId'] != 'm-pc') continue;
              // 模拟快照里这一行「没有覆盖量」：需求 = 缺口 = 还需安排, 现货分配也
              // 清零, 四个数自洽(页面按现货分配 + 已下达算不封顶的覆盖量)。
              material['requiredQty'] = parent;
              material['shortageQty'] = parent;
              material['demandSupplyGapQty'] = parent;
              material['allocatedAvailableQty'] = 0;
              material['netShortageQty'] = parent;
              material['additionalSupplyRecommendedQty'] = parent;
            }
          }
          // 父件二 / 三的追加带动**已下过单**的子件(服务端口径: 需求按父件产出量
          // 展开, 还需安排 = 需求 − 覆盖, 封顶 0): 刚好下够的子件覆盖 1000(现货 200 +
          // 已订 800), 多下过的覆盖 2600(现货 200 + 已订 2400)。
          for (final raw in (scaled['flatMaterials'] as List)) {
            final material = raw as Map<String, dynamic>;
            final line = material['materialLineId'] as String;
            final appended = switch (line) {
              'm-qc1' => typed['m-q'],
              'm-rc' => typed['m-r'],
              _ => null,
            };
            if (appended == null) continue;
            final covered = line == 'm-qc1' ? 1000.0 : 2600.0;
            final required = 1000 + appended;
            final residual = required - covered;
            material['requiredQty'] = required;
            material['additionalSupplyRecommendedQty'] = residual > 0
                ? residual
                : 0.0;
            material['netShortageQty'] = residual > 0 ? residual : 0.0;
          }
          result = scaled;
        } else if (request.path.endsWith('/notify')) {
          result = data;
        } else if (request.path == '/production/material-analyses/analysis-1') {
          result = data;
        } else if (request.path.endsWith('/routes') &&
            request.method == 'PUT') {
          data = jsonDecode(jsonEncode(data)) as Map<String, dynamic>;
          result = data;
        } else if (request.path.endsWith('/sales-candidates')) {
          result = {
            'items': <Object>[],
            'page': 1,
            'size': 20,
            'total': 0,
            'totalPages': 1,
          };
        }
        handler.resolve(
          Response<dynamic>(
            requestOptions: request,
            statusCode: 200,
            data: result,
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
        masterNameServiceProvider.overrideWithValue(MasterNameService(api)),
        materialAnalysisWarehousePrefsProvider.overrideWith(
          _WarehousePrefs.new,
        ),
        currentPermissionsProvider.overrideWithValue(permissions),
      ],
      child: MaterialApp(
        locale: const Locale('zh'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        theme: buildLightTheme(),
        home: const ProductionMaterialAnalysisPage(
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
}

/// 三行物料刚好铺满三种形态：未确认路线 / 已确认未下达 / 已下达。
/// [overSupply] = 服务端也放行超量(已下达的行追加要它)。
Map<String, dynamic> _analysis({bool overSupply = false}) => {
  'analysisId': 'analysis-1',
  'version': 3,
  'fingerprint': 'a' * 64,
  'warehouseId': 'warehouse-1',
  'warehouseIds': ['warehouse-1'],
  'status': 'ACTIVE',
  'allowedActions': [
    'VIEW',
    'CONFIRM_ROUTES',
    'NOTIFY_SUPPLY',
    'CROSS_REALLOCATE',
    if (overSupply) 'OVER_SUPPLY',
  ],
  'products': [
    {
      'analysisLineId': 'product-1',
      'sourceType': 'SALES_ORDER',
      'goodsId': 'product-goods',
      'goodsCode': 'UT-2026',
      'goodsName': '智能多功能插座',
      'requestedQty': 1000,
      'remainingQty': 1000,
      'readyNowQty': 0,
      'canSchedule': true,
      'maxSchedulableQty': 1000,
      'unitName': '件',
      'rootMaterialLineId': 'm-root',
    },
  ],
  'flatMaterials': [
    // 顶层根供给行: 产品行直接承载它(V478), 不再单独渲染一条根物料行。
    _material(
      line: 'm-root',
      name: '智能多功能插座',
      confirmed: 'MAKE',
      netShortageQty: 600,
      nodeRole: 'ROOT_SUPPLY',
      level: 0,
    ),
    // 自制子件: 2026-09-22 起下单数量可填可超量。
    _material(
      line: 'm-6',
      name: '自制外壳',
      confirmed: 'MAKE',
      netShortageQty: 400,
    ),
    _material(line: 'm-1', name: '未定路线件', confirmed: null, netShortageQty: 800),
    // 已下达的自制父件 + 它的采购子件：主表上「父改子跟」与「追加也要带动子层」
    // 两条口径都落在这一对上(父件只能在追加格填数)。
    _material(
      line: 'm-p',
      name: '已下达委外父件',
      confirmed: 'SUBCONTRACT',
      // V581 我方供料的单一子件件：直接外发、不建前置自制任务，所以追加格可填。
      subcontractOutboundForm: 'COMPONENT_OUTBOUND',
      netShortageQty: 0,
      stockQty: 0,
      downstream: [
        {
          'actionId': 'act-p',
          'route': 'SUBCONTRACT',
          'status': 'REQUESTED',
          'documentNo': 'SC-0001',
          'allocatedQty': 1000,
        },
      ],
    ),
    _material(
      line: 'm-pc',
      name: '父件的子件',
      confirmed: 'BUY',
      netShortageQty: 600,
      level: 2,
      parentLine: 'm-p',
    ),
    // 已下达的委外父件二 + 一个**刚好下够**的采购子件(需求 1000 = 现货 200 + 已订
    // 800)：父件追加时子件的追加格要自动填上新缺口(用户口径 2026-09-22)。
    _material(
      line: 'm-q',
      name: '已下达父件二',
      confirmed: 'SUBCONTRACT',
      subcontractOutboundForm: 'COMPONENT_OUTBOUND',
      netShortageQty: 0,
      stockQty: 0,
      downstream: [
        {
          'actionId': 'act-q',
          'route': 'SUBCONTRACT',
          'status': 'REQUESTED',
          'documentNo': 'SC-0002',
          'allocatedQty': 1000,
        },
      ],
    ),
    _material(
      line: 'm-qc1',
      name: '下够了的子件',
      confirmed: 'BUY',
      netShortageQty: 0,
      level: 2,
      parentLine: 'm-q',
      downstream: [
        {
          'actionId': 'act-qc1',
          'route': 'BUY',
          'status': 'REQUESTED',
          'documentNo': 'PR-0002',
          'allocatedQty': 800,
        },
      ],
    ),
    // 已下达的委外父件三 + 一个**多下过**的采购子件(需求 1000，现货 200 之外还订了
    // 2400)：父件追加 200 时它一颗都不缺，追加格保持 0。
    _material(
      line: 'm-r',
      name: '已下达父件三',
      confirmed: 'SUBCONTRACT',
      subcontractOutboundForm: 'COMPONENT_OUTBOUND',
      netShortageQty: 0,
      stockQty: 0,
      downstream: [
        {
          'actionId': 'act-r',
          'route': 'SUBCONTRACT',
          'status': 'REQUESTED',
          'documentNo': 'SC-0003',
          'allocatedQty': 1000,
        },
      ],
    ),
    _material(
      line: 'm-rc',
      name: '多下了的子件',
      confirmed: 'BUY',
      netShortageQty: 0,
      level: 2,
      parentLine: 'm-r',
      downstream: [
        {
          'actionId': 'act-rc',
          'route': 'BUY',
          'status': 'REQUESTED',
          'documentNo': 'PR-0003',
          'allocatedQty': 2400,
        },
      ],
    ),
    _material(
      line: 'm-2',
      name: '待下单紧固件',
      confirmed: 'BUY',
      netShortageQty: 500,
      inboundQty: 100,
    ),
    _material(
      line: 'm-3',
      name: '已下单紧固件',
      confirmed: 'BUY',
      netShortageQty: 0,
      downstream: [
        {
          'actionId': 'act-3',
          'route': 'BUY',
          'status': 'REQUESTED',
          'documentNo': 'PR-0001',
          'allocatedQty': 300,
        },
      ],
    ),
    // 有公共在途可认领：毛量 1000、净数 700。
    _material(
      line: 'm-4',
      name: '有公共在途件',
      confirmed: 'BUY',
      netShortageQty: 700,
      grossQty: 1000,
      sharedFutureAvailableQty: 300,
    ),
    // 只从别的计划调拨进来一点，没下过任何订货单。
    _material(
      line: 'm-5',
      name: '刚调拨进来的件',
      confirmed: 'BUY',
      netShortageQty: 950,
      downstream: [
        {
          'actionId': 'act-transfer',
          'route': 'BUY',
          'status': 'CREATED',
          'documentNo': 'PR-9999',
          'allocatedQty': 50,
        },
      ],
    ),
  ],
  // 客户端按 operationType 区分「真下过单」与「只是把别处的在途搬过来」。
  'supplyActions': [
    {'actionId': 'act-3', 'route': 'BUY', 'operationType': 'SUPPLY'},
    {
      'actionId': 'act-transfer',
      'route': 'BUY',
      'operationType': 'FUTURE_TRANSFER',
    },
  ],
};

Map<String, dynamic> _material({
  required String line,
  required String name,
  required String? confirmed,
  required double netShortageQty,
  double? grossQty,
  double sharedFutureAvailableQty = 0,
  double inboundQty = 0,
  String nodeRole = 'BOM_NODE',
  int level = 1,
  List<Map<String, dynamic>> downstream = const [],
  String? parentLine,
  String? subcontractOutboundForm,
  // 本批分到的合格现货(默认 200)；已下达的父件给 0 = 「下了 1000 刚好覆盖需求 1000」。
  double stockQty = 200,
}) => {
  'subcontractOutboundForm': ?subcontractOutboundForm,
  'materialLineId': line,
  'analysisLineId': 'product-1',
  'nodeRole': nodeRole,
  'nodeKey': 'n-$line',
  if (parentLine != null) 'parentNodeKey': 'n-$parentLine',
  'actionGroupKey': 'a-$line',
  'goodsId': 'g-$line',
  'goodsCode': 'M-$line',
  'goodsName': name,
  'colorName': '本色',
  'unitName': '个',
  'unitId': 'unit-1',
  'level': level,
  'path': ['智能多功能插座', name],
  'requiredQty': 1000,
  'allocatedAvailableQty': stockQty,
  'availableQty': stockQty,
  'shortageQty': 1000 - stockQty,
  'demandSupplyGapQty': 1000 - stockQty,
  'inboundQty': inboundQty,
  'additionalSupplyRecommendedQty': grossQty ?? netShortageQty,
  'netShortageQty': netShortageQty,
  'sharedFutureAvailableQty': sharedFutureAvailableQty,
  'sourceSuggestion': 'BUY',
  'sourceConfirmed': confirmed,
  'routeConfirmed': confirmed != null,
  'controlStage': 'START',
  'hardGate': true,
  'actionable': true,
  'downstreamReferences': downstream,
};

class _WarehousePrefs extends MaterialAnalysisWarehousePrefsNotifier {
  @override
  MaterialAnalysisWarehousePrefs build() =>
      const MaterialAnalysisWarehousePrefs();
  @override
  Future<void> syncNow() async {}
  @override
  void update(MaterialAnalysisWarehousePrefs next) => state = next;
}
