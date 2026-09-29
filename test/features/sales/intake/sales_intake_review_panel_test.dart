// 核对面板交互: 默认只看需要核对的行(已对应的收起)、筛选切换、候选下拉改选与「就是它」、
// 组合件拆行、没找到的行从货品资料选、订货单没标价 →「改为新建报价单」、客户换一个/新建、
// 「全部导入 (N 行)」计数与返回的选择、100+ 行按需构建。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/core/theme/light_theme.dart';
import 'package:uten_imp/features/sales/intake/sales_intake_apply.dart';
import 'package:uten_imp/features/sales/intake/sales_intake_models.dart';
import 'package:uten_imp/features/sales/intake/sales_intake_review_panel.dart';
import 'package:uten_imp/features/sales/models/sales_doc.dart';

import 'sales_intake_fixture.dart';

class _Harness {
  SalesIntakeReviewOutcome? outcome;
  bool closed = false;
  int goodsPicks = 0;
  SalesIntakeNewClientProposal? createdFrom;
  final rerunSheets = <SalesIntakeOtherSheet>[];
}

Future<_Harness> _open(
  WidgetTester tester, {
  SalesDocType docType = SalesDocType.order,
  Map<String, dynamic>? json,
  bool canHandoffToQuote = true,
  String? jobId,
  SalesIntakeSheetRerun? Function(SalesIntakeOtherSheet sheet)? rerun,
  Locale locale = const Locale('zh'),
}) async {
  await tester.binding.setSurfaceSize(const Size(1400, 1100));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  final harness = _Harness();
  final result = SalesIntakeResult.fromJson(json ?? intakeResultJson());
  final actions = SalesIntakeReviewActions(
    pickClient: (_) async =>
        const SalesIntakePickedClient(id: 'client-other', name: '约旦二'),
    pickGoods: (_) async {
      harness.goodsPicks++;
      return const SalesIntakePickedGoods(
        id: 'g-manual',
        code: 'M-1',
        name: '手选货品',
        colorName: '白色',
        price: '4',
      );
    },
    createClient: (_, proposal) async {
      harness.createdFrom = proposal;
      return SalesIntakePickedClient(id: 'client-new', name: proposal.name!);
    },
    canHandoffToQuote: canHandoffToQuote,
    rerunSheet: rerun == null
        ? null
        : (_, sheet) async {
            harness.rerunSheets.add(sheet);
            return rerun(sheet);
          },
  );
  await tester.pumpWidget(
    MaterialApp(
      theme: buildLightTheme(),
      locale: locale,
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(
        body: Builder(
          builder: (context) => Center(
            child: TextButton(
              onPressed: () async {
                harness.outcome = await showSalesIntakeReviewPanel(
                  context,
                  result: result,
                  docType: docType,
                  actions: actions,
                  jobId: jobId,
                );
                harness.closed = true;
              },
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
  return harness;
}

Finder _line(String key) => find.byKey(ValueKey('sales-intake-line-$key'));

Finder get _panelScrollable => find
    .descendant(
      of: find.byKey(const ValueKey('sales-intake-review-scroll')),
      matching: find.byType(Scrollable),
    )
    .first;

/// 面板正文按需构建: 先滚到目标出现(先往下找, 找不到再往上找), 再保证完整可见。
Future<void> _reveal(
  WidgetTester tester,
  Finder finder, {
  double step = 200,
}) async {
  if (finder.evaluate().isEmpty) {
    try {
      await tester.scrollUntilVisible(
        finder,
        step,
        scrollable: _panelScrollable,
        maxScrolls: 100,
      );
    } on StateError {
      await tester.scrollUntilVisible(
        finder,
        -step,
        scrollable: _panelScrollable,
        maxScrolls: 100,
      );
    }
  }
  await tester.ensureVisible(finder);
  await tester.pumpAndSettle();
}

/// 底部固定栏(汇总 + 全部导入)不在滚动区里, 直接点。
Future<void> _tapFooter(WidgetTester tester, Finder finder) async {
  await tester.tap(finder);
  await tester.pumpAndSettle();
}

Future<void> _tap(WidgetTester tester, Finder finder) async {
  await _reveal(tester, finder);
  await tester.tap(finder);
  await tester.pumpAndSettle();
}

const _importAll = ValueKey('sales-intake-import-all');

void main() {
  testWidgets('默认只看需要核对的行; 已对应的收起, 展开/切到全部能看到', (tester) async {
    await _open(tester);
    expect(find.text('核对识别结果'), findsOneWidget);
    await _reveal(
      tester,
      find.byKey(const ValueKey('sales-intake-blocked-notice')),
    );
    expect(
      find.byKey(const ValueKey('sales-intake-duplicate-notice')),
      findsOneWidget,
    );
    // 一般说明合成一条(币种折算/其它工作表/服务端提示), 不把正文挤下去。
    final info = find.byKey(const ValueKey('sales-intake-info-notice'));
    expect(info, findsOneWidget);
    expect(
      find.descendant(of: info, matching: find.textContaining('重新上传这个文件')),
      findsOneWidget,
    );
    // 没有原文件可重新识别时, 别的工作表只提示, 不给可点的小标签。
    expect(
      find.byKey(const ValueKey('sales-intake-other-sheets')),
      findsNothing,
    );
    await _reveal(tester, find.text('客户: 尼日利亚SUNAS(WM057)'));
    await _reveal(tester, find.text('需要核对 (5)'));
    expect(find.text('全部 (6)'), findsOneWidget);
    await _reveal(tester, _line('S1R10'));
    await _reveal(tester, find.text('1 行已自动对应'));
    expect(_line('S1R9'), findsNothing);

    await _tap(
      tester,
      find.byKey(const ValueKey('sales-intake-matched-toggle')),
    );
    await _reveal(tester, _line('S1R9'));

    await _tap(tester, find.text('全部 (6)'));
    await _reveal(tester, _line('S1R9'));
    expect(find.text('1 行已自动对应'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('候选下拉改选 → 已确认; 全部导入返回选择', (tester) async {
    final harness = await _open(tester);
    expect(find.text('全部导入 (4 行)'), findsOneWidget);

    await _tap(tester, find.byKey(const ValueKey('sales-intake-goods-S1R10')));
    await tester.tap(find.text('两开多功能三极插座(280235165) · 白色').last);
    await tester.pumpAndSettle();
    expect(
      find.descendant(of: _line('S1R10'), matching: find.text('已确认')),
      findsOneWidget,
    );

    await _tapFooter(tester, find.byKey(_importAll));
    final apply = harness.outcome! as SalesIntakeReviewApply;
    final d = apply.decisions.lines['S1R10']!;
    expect(d.goods!.goodsId, 'g-gz23-white');
    expect(d.userConfirmed, isTrue);
    expect(d.include, isTrue);
  });

  testWidgets('「就是它」确认预选货品', (tester) async {
    final harness = await _open(tester);
    await _tap(
      tester,
      find.byKey(const ValueKey('sales-intake-confirm-S1R10')),
    );
    expect(
      find.byKey(const ValueKey('sales-intake-confirm-S1R10')),
      findsNothing,
    );
    await _tapFooter(tester, find.byKey(_importAll));
    final d = (harness.outcome! as SalesIntakeReviewApply).decisions;
    expect(d.lines['S1R10']!.goods!.goodsId, 'g-gz23-gold');
    expect(d.lines['S1R10']!.userConfirmed, isTrue);
  });

  testWidgets('组合件拆成 2 行: 计数 +1, 可合回', (tester) async {
    final harness = await _open(tester);
    await _tap(tester, find.byKey(const ValueKey('sales-intake-split-S1R13')));
    await _reveal(
      tester,
      find.byKey(const ValueKey('sales-intake-part-S1R13-0')),
    );
    await _reveal(
      tester,
      find.byKey(const ValueKey('sales-intake-part-S1R13-1')),
    );
    expect(find.text('全部导入 (5 行)'), findsOneWidget);

    await _tap(tester, find.byKey(const ValueKey('sales-intake-merge-S1R13')));
    expect(find.text('全部导入 (4 行)'), findsOneWidget);
    await _tap(tester, find.byKey(const ValueKey('sales-intake-split-S1R13')));
    await _tapFooter(tester, find.byKey(_importAll));
    final d = (harness.outcome! as SalesIntakeReviewApply).decisions;
    expect(d.lines['S1R13']!.split, isTrue);
    expect(d.lines['S1R13']!.parts.map((p) => p.goods?.goodsId), [
      'g-wtv03',
      'g-wtv04',
    ]);
  });

  testWidgets('订货单拆开组合件: 没标价的部件不能勾、不计数, 计入「还没有标价」', (tester) async {
    final json = intakeResultJson();
    final bundle = (json['lines'] as List)
        .cast<Map<String, dynamic>>()
        .singleWhere((l) => l['key'] == 'S1R13');
    final part = (bundle['bundleParts'] as List)
        .cast<Map<String, dynamic>>()
        .last;
    part['candidates'] = [
      candidate(
        goodsId: 'g-wtv04',
        code: 'WTV-04',
        name: '电视插座面板',
        listPrice: '0',
        pricingFlag: 'NO_LIST_PRICE',
      ),
    ];
    final harness = await _open(tester, json: json);
    expect(find.text('全部导入 (4 行)'), findsOneWidget);
    await _reveal(tester, find.text('这 1 个货品还没有标价(或文件单价高于标价)'));

    await _tap(tester, find.byKey(const ValueKey('sales-intake-split-S1R13')));
    final partInclude = find.byKey(
      const ValueKey('sales-intake-part-include-S1R13-1'),
    );
    await _reveal(tester, partInclude);
    expect(tester.widget<Checkbox>(partInclude).value, isFalse);
    expect(tester.widget<Checkbox>(partInclude).onChanged, isNull);
    expect(
      find.byKey(const ValueKey('sales-intake-part-blocked-S1R13-1')),
      findsOneWidget,
    );
    // 整行 1 行换成能导入的 1 个部件: 仍是 4 行; 没标价的货品变成 2 个。
    expect(find.text('全部导入 (4 行)'), findsOneWidget);
    await _reveal(tester, find.text('这 2 个货品还没有标价(或文件单价高于标价)'));

    // 整行的勾先去掉再勾上: 没标价的部件不会被一起勾上。
    final lineInclude = find.byKey(
      const ValueKey('sales-intake-include-S1R13'),
    );
    await _tap(tester, lineInclude);
    expect(find.text('全部导入 (3 行)'), findsOneWidget);
    await _tap(tester, lineInclude);
    expect(find.text('全部导入 (4 行)'), findsOneWidget);
    expect(tester.widget<Checkbox>(partInclude).value, isFalse);

    await _tapFooter(tester, find.byKey(_importAll));
    final d = (harness.outcome! as SalesIntakeReviewApply).decisions;
    expect(d.lines['S1R13']!.parts.map((p) => p.include), [true, false]);
  });

  testWidgets('折扣按某种币种口径算出时, 折扣旁给出服务端说明', (tester) async {
    final json = intakeResultJson();
    final line = (json['lines'] as List)
        .cast<Map<String, dynamic>>()
        .singleWhere((l) => l['key'] == 'S1R10');
    ((line['candidates'] as List).first
            as Map<String, dynamic>)['pricingNote'] =
        '客户单价按人民币标价计算(没有按汇率换算)';
    await _open(tester, json: json);
    final note = find.byKey(const ValueKey('sales-intake-pricing-note-S1R10'));
    await _reveal(tester, note);
    expect(
      find.descendant(of: note, matching: find.text('客户单价按人民币标价计算(没有按汇率换算)')),
      findsOneWidget,
    );
  });

  testWidgets('没找到的行默认不导入; 从货品资料选了就导入并按文件单价算折扣', (tester) async {
    final harness = await _open(tester);
    final include = find.byKey(const ValueKey('sales-intake-include-S1R11'));
    await _reveal(tester, include);
    expect(tester.widget<Checkbox>(include).value, isFalse);
    expect(tester.widget<Checkbox>(include).onChanged, isNull);

    await _tap(
      tester,
      find.byKey(const ValueKey('sales-intake-pick-goods-S1R11')),
    );
    expect(harness.goodsPicks, 1);
    expect(tester.widget<Checkbox>(include).value, isTrue);
    expect(find.text('全部导入 (5 行)'), findsOneWidget);
    await _reveal(tester, find.text('折扣 0.75'));

    await _tapFooter(tester, find.byKey(_importAll));
    final d = (harness.outcome! as SalesIntakeReviewApply).decisions;
    final manual = d.lines['S1R11']!.goods!;
    expect(manual.pickedManually, isTrue);
    expect(manual.discount, '0.75');
  });

  testWidgets('订货单有没标价的货品: 行不能勾, 可改为新建报价单', (tester) async {
    final harness = await _open(tester);
    final include = find.byKey(const ValueKey('sales-intake-include-S1R12'));
    await _reveal(tester, include);
    expect(tester.widget<Checkbox>(include).onChanged, isNull);
    expect(
      find.descendant(of: _line('S1R12'), matching: find.text('不能导入')),
      findsOneWidget,
    );
    await _tap(
      tester,
      find.byKey(const ValueKey('sales-intake-handoff-quote')),
    );
    expect(harness.outcome, isA<SalesIntakeReviewHandoffToQuote>());
  });

  testWidgets('没有新建报价权限时不给「改为新建报价单」', (tester) async {
    await _open(tester, canHandoffToQuote: false);
    await _reveal(
      tester,
      find.byKey(const ValueKey('sales-intake-blocked-notice')),
    );
    expect(
      find.byKey(const ValueKey('sales-intake-handoff-quote')),
      findsNothing,
    );
  });

  testWidgets('报价单: 没标价的货品照常导入, 不提示改做报价', (tester) async {
    await _open(tester, docType: SalesDocType.quote);
    expect(
      find.byKey(const ValueKey('sales-intake-blocked-notice')),
      findsNothing,
    );
    expect(find.text('全部导入 (5 行)'), findsOneWidget);
  });

  testWidgets('客户换一个: 候选/选其它客户; 换了客户不再补客户资料', (tester) async {
    final harness = await _open(tester);
    await _reveal(
      tester,
      find.byKey(const ValueKey('sales-intake-enrichment')),
    );
    await _tap(tester, find.text('换一个'));
    await _reveal(
      tester,
      find.byKey(const ValueKey('sales-intake-client-client-sunas')),
    );
    await _tap(tester, find.byKey(const ValueKey('sales-intake-pick-client')));
    await _reveal(tester, find.text('客户: 约旦二'));
    expect(find.byKey(const ValueKey('sales-intake-enrichment')), findsNothing);
    await _tapFooter(tester, find.byKey(_importAll));
    final d = (harness.outcome! as SalesIntakeReviewApply).decisions;
    expect(d.clientId, 'client-other');
  });

  testWidgets('客户没找到: 用文件信息新建客户', (tester) async {
    final harness = await _open(
      tester,
      json: intakeResultJson(clientStatus: 'UNMATCHED'),
    );
    await _reveal(tester, find.text('没在你的客户里找到这个买方'));
    await _tap(
      tester,
      find.byKey(const ValueKey('sales-intake-create-client')),
    );
    expect(harness.createdFrom?.email, 'buyer@example.com');
    await _reveal(tester, find.text('客户: SUNAS TRADING'));
  });

  testWidgets('客户没找到但没有新建客户权限(服务端不给提议): 不显示新建按钮', (tester) async {
    final json = intakeResultJson(clientStatus: 'UNMATCHED');
    (json['client'] as Map<String, dynamic>)['newClientProposal'] = null;
    await _open(tester, json: json);
    await _reveal(tester, find.text('没在你的客户里找到这个买方'));
    expect(
      find.byKey(const ValueKey('sales-intake-create-client')),
      findsNothing,
    );
  });

  test('理由标签: 「其他客户的专用货品」要留意, 「其他客户也这样叫」是对得上的依据', () {
    expect(salesIntakeReasonNeedsAttention('其他客户的专用货品'), isTrue);
    expect(salesIntakeReasonNeedsAttention('其他客户也这样叫'), isFalse);
    expect(salesIntakeReasonNeedsAttention('型号一致'), isFalse);
    expect(salesIntakeReasonNeedsAttention('颜色不一致'), isTrue);
  });

  test('服务端「名下没有客户资料」按中文原句识别', () {
    expect(
      salesIntakeIsNoVisibleClientsNotice('你名下还没有客户资料, 请联系主管在客户资料里把客户分配给你'),
      isTrue,
    );
    expect(salesIntakeIsNoVisibleClientsNotice('文件有 600 行货品'), isFalse);
  });

  for (final locale in const [Locale('en'), Locale('ko')]) {
    testWidgets('名下没有客户(${locale.languageCode}): 服务端中文提示不在提示区重复', (
      tester,
    ) async {
      final json = intakeResultJson(clientStatus: 'NO_VISIBLE_CLIENTS');
      json['notices'] = ['你名下还没有客户资料, 请联系主管在客户资料里把客户分配给你'];
      await _open(tester, json: json, locale: locale);
      expect(find.textContaining('你名下还没有客户资料'), findsNothing);
    });
  }

  testWidgets('取消返回 null', (tester) async {
    final harness = await _open(tester);
    await _tapFooter(tester, find.text('取消'));
    expect(harness.closed, isTrue);
    expect(harness.outcome, isNull);
  });

  testWidgets('150 行需要核对: 按需构建, 滚到底才建最后一行', (tester) async {
    final json = intakeResultJson();
    json['lines'] = [
      for (var i = 0; i < 150; i++)
        {
          'key': 'S1R${100 + i}',
          'lineNo': '${i + 1}',
          'partNo': 'P-$i',
          'qty': 1,
          'status': 'REVIEW',
          'reasonText': '找到 2 个相似货品, 请选一个',
          'candidates': [
            candidate(
              goodsId: 'g-$i',
              name: '货品$i',
              listPrice: '1',
              discount: '1',
              pricingFlag: 'OK',
            ),
          ],
          'selectedGoodsId': 'g-$i',
        },
    ];
    await _open(tester, json: json);
    expect(find.text('全部导入 (150 行)'), findsOneWidget);
    await _reveal(tester, find.text('需要核对 (150)'));
    final built = find.byWidgetPredicate(
      (w) =>
          w.key is ValueKey<String> &&
          (w.key! as ValueKey<String>).value.startsWith('sales-intake-line-'),
    );
    expect(built.evaluate().length, lessThan(40));
    expect(_line('S1R249'), findsNothing);
    await _reveal(tester, _line('S1R249'), step: 1500);
    expect(_line('S1R249'), findsOneWidget);
  });

  group('设为货品英文名', () {
    Map<String, dynamic> withPlateNameEn() {
      final json = intakeResultJson();
      final plate = (json['lines'] as List)
          .cast<Map<String, dynamic>>()
          .singleWhere((l) => l['key'] == 'S1R12');
      plate['nameEnText'] = 'PRESSURE PLATE';
      plate['setNameEnDefault'] = true;
      return json;
    }

    Finder nameEn(String key) =>
        find.byKey(ValueKey('sales-intake-name-en-$key'));

    testWidgets('只给会导入的行: 取消勾选就收起, 保存也不带', (tester) async {
      final harness = await _open(tester);
      await _reveal(tester, nameEn('S1R10'));
      expect(nameEn('S1R10'), findsOneWidget);
      await _tap(tester, nameEn('S1R10'));
      expect(tester.widget<Checkbox>(nameEn('S1R10')).value, isTrue);

      await _tap(
        tester,
        find.byKey(const ValueKey('sales-intake-include-S1R10')),
      );
      expect(nameEn('S1R10'), findsNothing);
      await _tapFooter(tester, find.byKey(_importAll));
      final apply = harness.outcome! as SalesIntakeReviewApply;
      final patch = buildSalesIntakePatch(
        result: apply.result,
        decisions: apply.decisions,
        docType: SalesDocType.order,
        jobId: 'job-1',
        l10n: lookupAppLocalizations(const Locale('zh')),
      );
      expect(patch.rows.map((r) => r.intakeLineKey), isNot(contains('S1R10')));
      expect(
        patch.rows.where((r) => r.setNameEn).map((r) => r.intakeLineKey),
        isNot(contains('S1R10')),
      );
    });

    testWidgets('订货单上不能导入(没标价)的行不给; 没找到货品的行不给', (tester) async {
      await _open(tester, json: withPlateNameEn());
      await _reveal(tester, _line('S1R12'));
      expect(nameEn('S1R12'), findsNothing);
      await _reveal(tester, _line('S1R11'));
      expect(nameEn('S1R11'), findsNothing);
    });

    testWidgets('报价单上同一行照常导入, 就给', (tester) async {
      await _open(tester, docType: SalesDocType.quote, json: withPlateNameEn());
      await _reveal(tester, nameEn('S1R12'));
      expect(nameEn('S1R12'), findsOneWidget);
      expect(tester.widget<Checkbox>(nameEn('S1R12')).value, isTrue);
    });
  });

  group('另有工作表', () {
    final second = SalesIntakeResult.fromJson(intakeSheetResultJson());

    testWidgets('点「另有工作表」用同一个文件改为识别那一张, 新结果整个替换面板', (tester) async {
      final harness = await _open(
        tester,
        jobId: 'job-1',
        rerun: (_) =>
            SalesIntakeSheetRerun(jobId: 'job-sheet-1', result: second),
      );
      final chip = find.byKey(const ValueKey('sales-intake-other-sheet-1'));
      await _reveal(tester, chip);
      expect(find.text('另有工作表 Packing 也像明细表 (32 行)'), findsOneWidget);
      expect(find.textContaining('这次识别的是工作表「Sheet1」'), findsOneWidget);
      await _tap(tester, chip);

      expect(harness.rerunSheets.single.index, 1);
      expect(harness.rerunSheets.single.name, 'Packing');
      // 换成新表后回到顶部, 先看到这次识别的是哪张表。
      expect(
        tester.state<ScrollableState>(_panelScrollable).position.pixels,
        0,
      );
      expect(find.textContaining('这次识别的是工作表「Packing」'), findsOneWidget);
      // 整个换成新表: 旧行不见了, 新行在; 原来那张变成可点回去的「另有工作表」。
      expect(_line('S1R10'), findsNothing);
      await _reveal(tester, find.text('全部 (1)'));
      await _reveal(tester, _line('S2R5'));
      await _reveal(
        tester,
        find.byKey(const ValueKey('sales-intake-other-sheet-0')),
      );
      expect(find.text('另有工作表 Sheet1 也像明细表 (6 行)'), findsOneWidget);
      expect(find.text('全部导入 (1 行)'), findsOneWidget);

      await _tapFooter(tester, find.byKey(_importAll));
      final apply = harness.outcome! as SalesIntakeReviewApply;
      expect(apply.jobId, 'job-sheet-1');
      expect(apply.result.file.sheet, 'Packing');
      expect(apply.decisions.lines.keys, ['S2R5']);
    });

    testWidgets('重新识别失败或取消: 面板保持原样, 仍是原作业', (tester) async {
      final harness = await _open(tester, jobId: 'job-1', rerun: (_) => null);
      final chip = find.byKey(const ValueKey('sales-intake-other-sheet-1'));
      await _tap(tester, chip);
      expect(harness.rerunSheets, hasLength(1));
      await _reveal(tester, find.text('全部 (6)'));
      await _reveal(tester, chip);
      await _tapFooter(tester, find.byKey(_importAll));
      final apply = harness.outcome! as SalesIntakeReviewApply;
      expect(apply.jobId, 'job-1');
      expect(apply.result.file.sheet, 'Sheet1');
    });

    testWidgets('「改为新建报价单」交出的是当前显示那张表的作业', (tester) async {
      final json = intakeSheetResultJson();
      final line = (json['lines'] as List).cast<Map<String, dynamic>>().single;
      line['candidates'] = [
        candidate(
          goodsId: 'g-gk12',
          name: '一开双控开关',
          listPrice: '0',
          pricingFlag: 'NO_LIST_PRICE',
        ),
      ];
      line['status'] = 'REVIEW';
      final harness = await _open(
        tester,
        jobId: 'job-1',
        rerun: (_) => SalesIntakeSheetRerun(
          jobId: 'job-sheet-1',
          result: SalesIntakeResult.fromJson(json),
        ),
      );
      await _tap(
        tester,
        find.byKey(const ValueKey('sales-intake-other-sheet-1')),
      );
      await _tap(
        tester,
        find.byKey(const ValueKey('sales-intake-handoff-quote')),
      );
      final handoff = harness.outcome! as SalesIntakeReviewHandoffToQuote;
      expect(handoff.jobId, 'job-sheet-1');
    });
  });
}
