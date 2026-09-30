// 识别结果 → 编辑页补丁(纯函数)的行为测试: 行状态、折扣四位小数、看不到价格时 null、
// 报价「待财务定价」、订货单拦下没标价的货品、表头带入、没找到的行写进备注、组合件拆行、
// 客户资料补全字段与 aiIntake 载荷; 以及与服务端同规则的折扣反推。
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/features/sales/intake/sales_intake_apply.dart';
import 'package:uten_imp/features/sales/intake/sales_intake_models.dart';
import 'package:uten_imp/features/sales/models/sales_doc.dart';

import 'sales_intake_fixture.dart';

final l10n = lookupAppLocalizations(const Locale('zh'));

SalesIntakePatch _patch(
  SalesIntakeResult result, {
  required SalesDocType docType,
  void Function(SalesIntakeDecisions d)? tweak,
}) {
  final decisions = SalesIntakeDecisions.initial(result, docType: docType);
  tweak?.call(decisions);
  return buildSalesIntakePatch(
    result: result,
    decisions: decisions,
    docType: docType,
    jobId: 'job-1',
    l10n: l10n,
  );
}

SalesIntakePatchRow _row(SalesIntakePatch patch, String key) =>
    patch.rows.singleWhere((r) => r.intakeLineKey == key);

void main() {
  test(
    'saved file prices keep unknown exchange rate when appending information without a session',
    () {
      const patch = SalesIntakePatch(
        jobId: 'new-job',
        rows: [],
        clientFileCurrency: 'EUR',
        financeRate: '9.5',
      );
      final session = patch.toSession(
        preservePreviousPricing: true,
        previousFileCurrency: 'USD',
      );
      expect(session.clientFileCurrency, 'USD');
      expect(session.financeRate, isNull);
      expect(session.rateMissing, isTrue);
      expect(session.additionalJobIds, isEmpty);
      final restored = SalesIntakeSession.fromJson(session.toJson());
      expect(restored.rateMissing, isTrue);
      expect(restored.financeRate, isNull);
    },
  );

  test(
    'file extra columns retain selected values without inventing arithmetic',
    () {
      final json = intakeResultJson();
      json['extraColumns'] = [
        {
          'key': 'file_E',
          'label': '运费',
          'dataType': 'NUMBER',
          'suggestedOperation': 'ADD',
        },
        {'key': 'file_F', 'label': '认证', 'dataType': 'TEXT'},
      ];
      ((json['lines'] as List).first as Map<String, dynamic>)['extraValues'] = {
        'file_E': '12.50',
        'file_F': 'CE',
      };
      final result = SalesIntakeResult.fromJson(json);
      final patch = _patch(
        result,
        docType: SalesDocType.quote,
        tweak: (d) => d.includedExtraColumns.remove('file_F'),
      );
      expect(patch.extraColumns.map((c) => c.label), ['运费']);
      expect(patch.rows.first.extraValues, {'file_E': '12.50'});
    },
  );

  test(
    'append session retains all adopted jobs and selected client fields in drafts',
    () {
      final result = SalesIntakeResult.fromJson(intakeResultJson());
      final patch = _patch(result, docType: SalesDocType.quote);
      final session = patch.toSession(
        previous: SalesIntakeSession(
          jobId: 'previous-job',
          clientId: patch.clientId,
          additionalJobIds: const ['earlier-job'],
          clientFields: const {'website': 'https://buyer.test'},
        ),
      );
      final restored = SalesIntakeSession.fromJson(session.toJson());
      expect(
        restored.toSaveJson(
          currentClientId: patch.clientId,
        )['additionalJobIds'],
        ['previous-job', 'earlier-job'],
      );
      expect(restored.clientFields['website'], 'https://buyer.test');
      expect(
        patch
            .toSession(
              previous: const SalesIntakeSession(
                jobId: 'other',
                clientId: 'other-client',
              ),
            )
            .additionalJobIds,
        isEmpty,
      );
    },
  );

  group('解析', () {
    test('防御式解析: 数字字符串/千分位, 重复与缺键的行丢弃, 白名单外补全字段丢弃', () {
      final result = SalesIntakeResult.fromJson(intakeResultJson());
      expect(result.lines.map((l) => l.key), [
        'S1R9',
        'S1R10',
        'S1R11',
        'S1R12',
        'S1R13',
        'S1R14',
      ]);
      final first = result.lines.first;
      expect(first.qty, '1800');
      expect(first.customerUnitPrice, '21');
      expect(first.status, SalesIntakeLineStatus.matched);
      expect(first.candidates.single.listPrice, '21');
      expect(first.preselected?.goodsId, 'g-gz23-white');
      expect(result.lines[1].customerUnitPrice, '19.95');
      expect(result.client.enrichment.map((e) => e.field), [
        'email',
        'address',
      ]);
      expect(result.currency.financeRate, '7.1');
      expect(result.file.otherSheets.single.name, 'Packing');
      expect(result.file.otherSheets.single.index, 1);
      expect(result.file.otherSheets.single.lineCount, 32);
      expect(result.lines[4].bundleParts, hasLength(2));
    });

    test('结果不是对象时抛 FormatException; 缺字段按空值', () {
      expect(() => SalesIntakeResult.fromJson('oops'), throwsFormatException);
      final empty = SalesIntakeResult.fromJson(<String, dynamic>{});
      expect(empty.lines, isEmpty);
      expect(empty.client.status, SalesIntakeClientStatus.review);
      expect(empty.priceMasked, isFalse);
    });
  });

  group('默认选择', () {
    test('订货单: 对上的导入, 需核对且有预选的导入, 没找到与没标价的不导入', () {
      final result = SalesIntakeResult.fromJson(intakeResultJson());
      final d = SalesIntakeDecisions.initial(
        result,
        docType: SalesDocType.order,
      );
      expect(d.lines['S1R9']!.include, isTrue);
      expect(d.lines['S1R10']!.include, isTrue);
      expect(d.lines['S1R11']!.include, isFalse);
      expect(d.lines['S1R12']!.include, isFalse);
      expect(d.lines['S1R9']!.setNameEn, isTrue);
      expect(d.clientId, 'client-sunas');
      expect(d.clientName, '尼日利亚SUNAS(WM057)');
      // 空白字段默认勾, 值不同的默认不勾。
      expect(d.enrichmentFields, {'email': true, 'address': false});
      expect(d.enrichmentEnabled, isTrue);
      expect(
        salesIntakeBlockedLines(
          result,
          d,
          docType: SalesDocType.order,
        ).single.key,
        'S1R12',
      );
    });

    test('报价单: 没标价的货品照常导入(交财务定价)', () {
      final result = SalesIntakeResult.fromJson(intakeResultJson());
      final d = SalesIntakeDecisions.initial(
        result,
        docType: SalesDocType.quote,
      );
      expect(d.lines['S1R12']!.include, isTrue);
      expect(
        salesIntakeBlockedLines(result, d, docType: SalesDocType.quote),
        isEmpty,
      );
    });

    test('需要核对的行: 非对上/组合件/单位换算/折扣没算出/订货单没标价', () {
      final result = SalesIntakeResult.fromJson(intakeResultJson());
      final d = SalesIntakeDecisions.initial(
        result,
        docType: SalesDocType.order,
      );
      bool needs(String key) => salesIntakeLineNeedsReview(
        result.lines.singleWhere((l) => l.key == key),
        d.lines[key]!,
        docType: SalesDocType.order,
        priceMasked: false,
      );
      expect(needs('S1R9'), isFalse);
      expect(needs('S1R10'), isTrue);
      expect(needs('S1R11'), isTrue);
      expect(needs('S1R12'), isTrue);
      expect(needs('S1R13'), isTrue);
      expect(needs('S1R14'), isTrue);
    });
  });

  group('补丁: 订货单', () {
    test('行字段: 标价预览只读、折扣原样四位小数、文件原文与学习键; 只有需核对行带黄标', () {
      final result = SalesIntakeResult.fromJson(intakeResultJson());
      final patch = _patch(result, docType: SalesDocType.order);

      // S1R9 对上, S1R10 需核对, S1R13 组合件整行, S1R14 箱换算; S1R11/S1R12 不导入。
      expect(patch.rows.map((r) => r.intakeLineKey), [
        'S1R9',
        'S1R10',
        'S1R13',
        'S1R14',
      ]);
      final matched = _row(patch, 'S1R9');
      expect(matched.goodsId, 'g-gz23-white');
      expect(matched.goodsCode, '280235165');
      expect(matched.qty, '1800');
      expect(matched.listPrice, '21');
      expect(matched.discount, '1');
      expect(matched.clientModel, 'GZ23/D');
      expect(
        matched.clientGoodsName,
        'DOUBLE 3 PIN UNIVERSAL SOCKET WITH SWITCH',
      );
      expect(matched.clientPrice, '21');
      expect(matched.setNameEn, isTrue);
      expect(matched.userConfirmed, isFalse);
      expect(matched.reviewReason, isNull);

      final review = _row(patch, 'S1R10');
      expect(review.discount, '0.95');
      expect(review.reviewReason, '颜色没对上');
      expect(review.setNameEn, isFalse);

      final carton = _row(patch, 'S1R14');
      expect(carton.qty, '600', reason: '按每箱个数换算后的数量(需核对)');
      expect(carton.reviewReason, contains('箱(CTN)'));
      expect(patch.reviewRowCount, 3);
    });

    test('表头: 客户、合同号=客户单号、本位币、文件币种; 备注=条款+没找到+没标价', () {
      final result = SalesIntakeResult.fromJson(intakeResultJson());
      final patch = _patch(result, docType: SalesDocType.order);
      expect(patch.clientId, 'client-sunas');
      expect(patch.contractNo, 'UJ23');
      expect(patch.currencyId, 'cny');
      expect(patch.clientFileCurrency, 'USD');
      expect(patch.financeRate, '7.1');
      expect(patch.skippedUnmatched, 1);
      expect(patch.blockedUnpriced, 1);
      final remark = patch.remark!.split('\n');
      expect(remark[0], 'EXW; T/T 30% deposit, 70% before shipment');
      expect(remark[1], '以下 1 行没找到对应货品: XX-999 MYSTERY PART × 5');
      expect(remark[2], startsWith('以下 1 行还没有标价(或文件单价高于标价), 没有导入: Q1200046'));
    });

    test('用户在面板里改选/确认 → userConfirmed, 不再黄标', () {
      final result = SalesIntakeResult.fromJson(intakeResultJson());
      final patch = _patch(
        result,
        docType: SalesDocType.order,
        tweak: (d) {
          final line = result.lines[1];
          d.decisionFor(line)
            ..goods = line.candidates[1]
            ..userConfirmed = true;
        },
      );
      final row = _row(patch, 'S1R10');
      expect(row.goodsId, 'g-gz23-white');
      expect(row.userConfirmed, isTrue);
      expect(row.reviewReason, isNull);
    });

    test('没找到的行用户从货品资料选了货品: 导入并按同规则反推折扣', () {
      final result = SalesIntakeResult.fromJson(intakeResultJson());
      final line = result.lines[2];
      final manual = salesIntakeManualCandidate(
        goodsId: 'g-manual',
        code: 'M-1',
        name: '手选货品',
        listPrice: '4',
        line: line,
        currency: result.currency,
        priceMasked: false,
        reason: l10n.salesIntakePickedManually,
      );
      expect(manual.discount, '0.75');
      expect(manual.pricingFlag, SalesIntakePricingFlag.ok);
      final patch = _patch(
        result,
        docType: SalesDocType.order,
        tweak: (d) => d.decisionFor(line)
          ..goods = manual
          ..include = true
          ..userConfirmed = true,
      );
      final row = _row(patch, 'S1R11');
      expect(row.discount, '0.75');
      expect(row.reviewReason, isNull);
      expect(patch.skippedUnmatched, 0);
    });

    test('折扣没能算出的货品: 折扣留空并黄标请销售核对', () {
      final json = intakeResultJson();
      final lines = json['lines'] as List;
      final first = lines.first as Map<String, dynamic>;
      final cand = (first['candidates'] as List).first as Map<String, dynamic>;
      cand
        ..remove('discount')
        ..['pricingFlag'] = 'AMBIGUOUS_CURRENCY';
      final patch = _patch(
        SalesIntakeResult.fromJson(json),
        docType: SalesDocType.order,
      );
      final row = _row(patch, 'S1R9');
      expect(row.discount, '');
      expect(row.reviewReason, l10n.salesIntakeMarkerOrderDiscount);
    });
  });

  group('补丁: 报价单', () {
    test('没标价的货品导入, 折扣留空待财务定价', () {
      final result = SalesIntakeResult.fromJson(intakeResultJson());
      final patch = _patch(result, docType: SalesDocType.quote);
      final row = _row(patch, 'S1R12');
      expect(row.discount, '');
      expect(row.listPrice, '0');
      expect(row.reviewReason, contains(l10n.salesIntakeMarkerQuotePricing));
      expect(patch.blockedUnpriced, 0);
      expect(patch.remark, isNot(contains('还没有标价')));
    });
  });

  group('看不到价格', () {
    test('折扣一律 null(提交 null 由服务端按文件单价算), 标价预览不带, 订货单也不拦', () {
      final result = SalesIntakeResult.fromJson(
        intakeResultJson(priceMasked: true),
      );
      final patch = _patch(result, docType: SalesDocType.order);
      expect(patch.priceMasked, isTrue);
      expect(patch.rows, isNotEmpty);
      for (final row in patch.rows) {
        expect(row.discount, isNull, reason: row.intakeLineKey);
        expect(row.listPrice, isNull);
      }
      expect(patch.rows.map((r) => r.intakeLineKey), contains('S1R12'));
      expect(patch.toSession().priceMasked, isTrue);
    });
  });

  group('组合件拆行', () {
    test('拆成 2 行: 数量相同, 部件不挂文件单价, 折扣留空, 保留模板来源行键', () {
      final result = SalesIntakeResult.fromJson(intakeResultJson());
      final line = result.lines[4];
      final patch = _patch(
        result,
        docType: SalesDocType.quote,
        tweak: (d) => d.decisionFor(line).split = true,
      );
      final parts = patch.rows
          .where((r) => r.clientModel == 'WTV-03' || r.clientModel == 'WTV-04')
          .toList();
      expect(parts.map((r) => r.goodsId), ['g-wtv03', 'g-wtv04']);
      expect(parts.map((r) => r.qty), ['50', '50']);
      expect(parts.every((r) => r.clientPrice == null), isTrue);
      expect(parts[0].remark, '组合件 WTV-03+WTV-04 整套文件单价 12 USD');
      expect(parts[1].remark, isNull);
      expect(parts.every((r) => r.discount == ''), isTrue);
      expect(parts.map((r) => r.intakeLineKey).toSet(), {'S1R13'});
      expect(
        parts.every((r) => r.reviewReason == l10n.salesIntakeMarkerBundlePart),
        isTrue,
      );
      expect(patch.rows.where((r) => r.intakeLineKey == 'S1R13'), hasLength(2));
      expect(parts.every((r) => !r.setNameEn), isTrue);
    });

    test('行数统计与拆行一致', () {
      final result = SalesIntakeResult.fromJson(intakeResultJson());
      final line = result.lines[4];
      final d = SalesIntakeDecisions.initial(
        result,
        docType: SalesDocType.quote,
      );
      expect(
        salesIntakeRowCount(
          line,
          d.decisionFor(line),
          docType: SalesDocType.quote,
          priceMasked: false,
        ),
        1,
      );
      d.decisionFor(line).split = true;
      expect(
        salesIntakeRowCount(
          line,
          d.decisionFor(line),
          docType: SalesDocType.quote,
          priceMasked: false,
        ),
        2,
      );
      d.decisionFor(line).parts.first.include = false;
      expect(
        salesIntakeRowCount(
          line,
          d.decisionFor(line),
          docType: SalesDocType.quote,
          priceMasked: false,
        ),
        1,
      );
    });
  });

  group('客户资料补全与 aiIntake', () {
    test('只提交勾选的字段, 且仅在客户仍是识别对上的那个时', () {
      final result = SalesIntakeResult.fromJson(intakeResultJson());
      final patch = _patch(result, docType: SalesDocType.order);
      expect(patch.clientFields, {'email': 'buyer@example.com'});
      final session = patch.toSession();
      expect(session.clientId, 'client-sunas');
      expect(session.toSaveJson(currentClientId: 'client-sunas'), {
        'jobId': 'job-1',
        'clientFields': {'email': 'buyer@example.com'},
      });
      // 导入后表头换了客户: 文件里的客户信息不补到别的客户身上。
      expect(session.toSaveJson(currentClientId: 'client-b'), {
        'jobId': 'job-1',
        'clientFields': <String, String>{},
      });
      expect(
        session.toSaveJson(currentClientId: null)['clientFields'],
        isEmpty,
      );
      expect(session.importedRows, patch.rows.length);

      final ticked = _patch(
        result,
        docType: SalesDocType.order,
        tweak: (d) => d.enrichmentFields['address'] = true,
      );
      expect(ticked.clientFields, {
        'email': 'buyer@example.com',
        'address': 'New road 9',
      });

      final off = _patch(
        result,
        docType: SalesDocType.order,
        tweak: (d) => d.enrichmentEnabled = false,
      );
      expect(off.clientFields, isEmpty);

      final otherClient = _patch(
        result,
        docType: SalesDocType.order,
        tweak: (d) => d.clientId = 'client-other',
      );
      expect(otherClient.clientFields, isEmpty);
      expect(otherClient.clientId, 'client-other');
    });

    test('会话随草稿往返', () {
      final result = SalesIntakeResult.fromJson(intakeResultJson());
      final session = _patch(result, docType: SalesDocType.order).toSession();
      final restored = SalesIntakeSession.fromJson(session.toJson());
      expect(restored.jobId, 'job-1');
      expect(restored.clientId, 'client-sunas');
      expect(restored.clientFields, session.clientFields);
      // 旧草稿没有 clientId: 不补客户资料(宁可不补, 不补错)。
      final legacy = SalesIntakeSession.fromJson({
        'jobId': 'job-1',
        'clientFields': {'email': 'buyer@example.com'},
      });
      expect(
        legacy.toSaveJson(currentClientId: 'client-sunas')['clientFields'],
        isEmpty,
      );
      expect(restored.clientFileCurrency, 'USD');
      expect(restored.financeRate, '7.1');
      expect(restored.fileName, 'UJ23 quotation.xlsx');
      expect(restored.isValid, isTrue);
    });
  });

  group('订货单: 组合件拆开后没标价的部件', () {
    Map<String, dynamic> unpricedPartJson() {
      final json = intakeResultJson();
      final bundle = (json['lines'] as List)
          .cast<Map<String, dynamic>>()
          .singleWhere((l) => l['key'] == 'S1R13');
      final part = (bundle['bundleParts'] as List)
          .cast<Map<String, dynamic>>()
          .singleWhere((p) => p['partNo'] == 'WTV-04');
      // 服务端给部件定价时没有文件单价: 标价为 0 → NO_LIST_PRICE。
      part['candidates'] = [
        candidate(
          goodsId: 'g-wtv04',
          code: 'WTV-04',
          name: '电视插座面板',
          listPrice: '0',
          pricingFlag: 'NO_LIST_PRICE',
        ),
      ];
      return json;
    }

    test('默认不勾、不计数、不导入, 写进「还没有标价」备注并计入拦截个数', () {
      final result = SalesIntakeResult.fromJson(unpricedPartJson());
      final line = result.lines.singleWhere((l) => l.key == 'S1R13');
      final d = SalesIntakeDecisions.initial(
        result,
        docType: SalesDocType.order,
      );
      final decision = d.decisionFor(line)..split = true;
      expect(decision.parts.map((p) => p.include), [true, false]);
      // 即使被手动勾上也不导入(订货单不能导入没标价的货品)。
      decision.parts.last.include = true;
      expect(
        salesIntakeRowCount(
          line,
          decision,
          docType: SalesDocType.order,
          priceMasked: false,
        ),
        1,
      );
      expect(
        salesIntakeBlockedLines(
          result,
          d,
          docType: SalesDocType.order,
        ).map((l) => l.key),
        ['S1R12', 'S1R13'],
      );
      expect(
        salesIntakeBlockedGoodsCount(result, d, docType: SalesDocType.order),
        2,
      );
      final patch = buildSalesIntakePatch(
        result: result,
        decisions: d,
        docType: SalesDocType.order,
        jobId: 'job-1',
        l10n: l10n,
      );
      expect(patch.rows.map((r) => r.goodsId), isNot(contains('g-wtv04')));
      expect(
        patch.rows.where((r) => r.clientModel == 'WTV-03').single.goodsId,
        'g-wtv03',
      );
      expect(patch.blockedUnpriced, 2);
      expect(patch.remark, contains('WTV-04 × 50'));
    });

    test('标价缺失(没有定价标记)的部件同样拦下; 报价单照常导入', () {
      final json = unpricedPartJson();
      final bundle = (json['lines'] as List)
          .cast<Map<String, dynamic>>()
          .singleWhere((l) => l['key'] == 'S1R13');
      final part = (bundle['bundleParts'] as List)
          .cast<Map<String, dynamic>>()
          .last;
      ((part['candidates'] as List).single as Map)
        ..remove('listPrice')
        ..remove('pricingFlag');
      final result = SalesIntakeResult.fromJson(json);
      final line = result.lines.singleWhere((l) => l.key == 'S1R13');
      final goods = line.bundleParts.last.candidates.single;
      expect(
        salesIntakePartBlocked(
          docType: SalesDocType.order,
          goods: goods,
          priceMasked: false,
        ),
        isTrue,
      );
      expect(
        salesIntakePartBlocked(
          docType: SalesDocType.quote,
          goods: goods,
          priceMasked: false,
        ),
        isFalse,
      );
      final quote = SalesIntakeDecisions.initial(
        result,
        docType: SalesDocType.quote,
      );
      final decision = quote.decisionFor(line)..split = true;
      expect(
        salesIntakeRowCount(
          line,
          decision,
          docType: SalesDocType.quote,
          priceMasked: false,
        ),
        2,
      );
    });

    test('部件手工选货品: 不按整套文件单价算折扣; 标价未知不拦, 标价 0 拦', () {
      final result = SalesIntakeResult.fromJson(intakeResultJson());
      final line = result.lines.singleWhere((l) => l.key == 'S1R13');
      SalesIntakeCandidate pick(String? listPrice) =>
          salesIntakeManualCandidate(
            goodsId: 'g-part',
            listPrice: listPrice,
            bundlePart: true,
            line: line,
            currency: result.currency,
            priceMasked: false,
            reason: l10n.salesIntakePickedManually,
          );
      final priced = pick('20');
      expect(priced.discount, isNull, reason: '整套单价 12 不能拿来算单个部件');
      expect(priced.pricingFlag, isNull);
      expect(
        salesIntakePartBlocked(
          docType: SalesDocType.order,
          goods: priced,
          priceMasked: false,
        ),
        isFalse,
      );
      final unknown = pick(null);
      expect(unknown.listPriceUnknown, isTrue);
      expect(
        salesIntakePartBlocked(
          docType: SalesDocType.order,
          goods: unknown,
          priceMasked: false,
        ),
        isFalse,
      );
      expect(
        salesIntakePartBlocked(
          docType: SalesDocType.order,
          goods: pick('0'),
          priceMasked: false,
        ),
        isTrue,
      );
    });
  });

  group('不导入的原文不悄悄丢掉', () {
    test('「没找到」的行带着服务端建议货品, 默认不导入, 原文写进备注', () {
      final json = intakeResultJson();
      final unmatched = (json['lines'] as List)
          .cast<Map<String, dynamic>>()
          .singleWhere((l) => l['key'] == 'S1R11');
      unmatched
        ..['aiSuggestion'] = {'goodsId': 'g-guess', 'reason': '名字相近'}
        ..['candidates'] = [
          candidate(
            goodsId: 'g-guess',
            name: '猜的货品',
            listPrice: '3',
            discount: '1',
            pricingFlag: 'OK',
          ),
        ];
      final result = SalesIntakeResult.fromJson(json);
      final d = SalesIntakeDecisions.initial(
        result,
        docType: SalesDocType.quote,
      );
      expect(d.lines['S1R11']!.goods?.goodsId, 'g-guess');
      expect(d.lines['S1R11']!.include, isFalse);
      final patch = buildSalesIntakePatch(
        result: result,
        decisions: d,
        docType: SalesDocType.quote,
        jobId: 'job-1',
        l10n: l10n,
      );
      expect(patch.rows.map((r) => r.intakeLineKey), isNot(contains('S1R11')));
      expect(patch.skippedUnmatched, 1);
      expect(patch.remark, contains('以下 1 行没找到对应货品: XX-999 MYSTERY PART × 5'));
    });

    test('用户自己取消勾选的已对应行: 不写进备注', () {
      final result = SalesIntakeResult.fromJson(intakeResultJson());
      final patch = _patch(
        result,
        docType: SalesDocType.order,
        tweak: (d) => d.lines['S1R9']!.include = false,
      );
      expect(patch.rows.map((r) => r.intakeLineKey), isNot(contains('S1R9')));
      expect(patch.remark, isNot(contains('GZ23/D')));
    });
  });

  group('设为货品英文名只对会导入的行', () {
    SalesIntakeResult plateWithNameEn() {
      final json = intakeResultJson();
      final plate = (json['lines'] as List)
          .cast<Map<String, dynamic>>()
          .singleWhere((l) => l['key'] == 'S1R12');
      plate['nameEnText'] = 'PRESSURE PLATE';
      plate['setNameEnDefault'] = true;
      return SalesIntakeResult.fromJson(json);
    }

    bool offered(
      SalesIntakeResult result,
      SalesIntakeDecisions d,
      String key, {
      SalesDocType docType = SalesDocType.order,
    }) {
      final line = result.lines.singleWhere((l) => l.key == key);
      return salesIntakeNameEnOffered(
        line,
        d.decisionFor(line),
        docType: docType,
        priceMasked: result.priceMasked,
      );
    }

    test('导入的行给; 取消勾选/订货单不能导入/没找到/拆开的组合件不给', () {
      final result = plateWithNameEn();
      final d = SalesIntakeDecisions.initial(
        result,
        docType: SalesDocType.order,
      );
      expect(offered(result, d, 'S1R9'), isTrue);
      expect(offered(result, d, 'S1R10'), isTrue);
      // 订货单上没标价(不能导入)。
      expect(d.lines['S1R12']!.setNameEn, isTrue);
      expect(offered(result, d, 'S1R12'), isFalse);
      // 报价单上同一行照常导入。
      final quote = SalesIntakeDecisions.initial(
        result,
        docType: SalesDocType.quote,
      );
      expect(
        offered(result, quote, 'S1R12', docType: SalesDocType.quote),
        isTrue,
      );
      // 用户取消勾选。
      d.lines['S1R9']!.include = false;
      expect(offered(result, d, 'S1R9'), isFalse);
      // 没找到货品(没有候选)与没有英文品名的行。
      expect(offered(result, d, 'S1R11'), isFalse);
      expect(offered(result, d, 'S1R14'), isFalse);
    });

    test('勾着英文名但行不导入: 补丁里没有这一行, 更不会带 setNameEn', () {
      final result = plateWithNameEn();
      final patch = _patch(
        result,
        docType: SalesDocType.order,
        tweak: (d) => d.lines['S1R9']!
          ..setNameEn = true
          ..include = false,
      );
      expect(patch.rows.map((r) => r.intakeLineKey), isNot(contains('S1R9')));
      expect(patch.rows.map((r) => r.intakeLineKey), isNot(contains('S1R12')));
      expect(patch.rows.where((r) => r.setNameEn), isEmpty);

      final kept = _patch(result, docType: SalesDocType.order);
      expect(_row(kept, 'S1R9').setNameEn, isTrue);
      final quote = _patch(result, docType: SalesDocType.quote);
      expect(_row(quote, 'S1R12').setNameEn, isTrue);
    });
  });

  group('看不到价格的账号在订货单上', () {
    test('服务端保留的「不能导入」标记照样拦下没标价的货品', () {
      final json = intakeResultJson(priceMasked: true);
      final line = (json['lines'] as List)
          .cast<Map<String, dynamic>>()
          .singleWhere((l) => l['key'] == 'S1R12');
      final cand = (line['candidates'] as List).single as Map<String, dynamic>;
      // 服务端去掉价格字段, 只留不含价格的布尔标记。
      cand
        ..remove('listPrice')
        ..remove('discount')
        ..remove('pricingFlag')
        ..['orderBlocked'] = true;
      final result = SalesIntakeResult.fromJson(json);
      final d = SalesIntakeDecisions.initial(
        result,
        docType: SalesDocType.order,
      );
      expect(d.lines['S1R12']!.include, isFalse);
      final patch = buildSalesIntakePatch(
        result: result,
        decisions: d,
        docType: SalesDocType.order,
        jobId: 'job-1',
        l10n: l10n,
      );
      expect(patch.rows.map((r) => r.intakeLineKey), isNot(contains('S1R12')));
      expect(patch.blockedUnpriced, 1);
    });
  });

  group('折扣反推(与服务端 MoneyPolicy.discountFromUnitPrice 同规则)', () {
    SalesIntakeDiscountPreview preview(
      String? price,
      String? list, {
      String? currency,
      String? rate,
      bool rateMissing = false,
    }) => salesIntakeDiscountPreview(
      customerUnitPrice: price,
      listPrice: list,
      fileCurrency: currency,
      financeRate: rate,
      rateMissing: rateMissing,
    );

    test('等价 → 1; 九五折 → 0.95; 四舍五入到 4 位', () {
      expect(preview('21', '21').discount, '1');
      expect(preview('21', '21').flag, SalesIntakePricingFlag.ok);
      expect(preview('19.95', '21').discount, '0.95');
      final third = preview('2', '3');
      expect(third.discount, '0.6667');
      expect(third.flag, SalesIntakePricingFlag.rounded);
      expect(preview('0.99995', '1').discount, '1');
    });

    test('区间按取 4 位后的折扣判断(与服务端保存时反推同一个判断)', () {
      final floor = preview('30.004', '100');
      expect(floor.flag, SalesIntakePricingFlag.outOfRange);
      expect(floor.discount, isNull);
      final ceiling = preview('100.004', '100');
      expect(ceiling.discount, '1');
      expect(ceiling.flag, SalesIntakePricingFlag.rounded);
      expect(preview('100.006', '100').flag, SalesIntakePricingFlag.aboveList);
    });

    test('没有文件单价 → 不给折扣也不给标记(与服务端一致)', () {
      expect(preview(null, '21').flag, isNull);
      expect(preview(null, '21').discount, isNull);
      expect(preview(null, '0').flag, SalesIntakePricingFlag.noListPrice);
    });

    test('没标价/标价 0 → NO_LIST_PRICE; 高于标价 → ABOVE_LIST(不截成 1)', () {
      expect(preview('3', null).flag, SalesIntakePricingFlag.noListPrice);
      expect(preview('3', '0').flag, SalesIntakePricingFlag.noListPrice);
      final above = preview('22.11', '21');
      expect(above.flag, SalesIntakePricingFlag.aboveList);
      expect(above.discount, isNull);
    });

    test('外币: 恰好一个比例落在 (0.3, 1] 才采用; 两个都在 → 看不出币种', () {
      final usd = preview('1', '7.9', currency: 'USD', rate: '7.1');
      expect(usd.discount, '0.8987');
      expect(usd.flag, SalesIntakePricingFlag.rounded);
      final usdPricedGoods = preview('0.9', '1', currency: 'USD', rate: '7.1');
      expect(usdPricedGoods.discount, '0.9', reason: '按美元标价计算');
      final both = preview('0.5', '1', currency: 'USD', rate: '1.5');
      expect(both.flag, SalesIntakePricingFlag.ambiguousCurrency);
      expect(both.discount, isNull);
      final none = preview('1.1', '7.5', currency: 'USD', rate: '7.1');
      expect(none.flag, SalesIntakePricingFlag.outOfRange);
    });

    test('外币且参考汇率没维护: 按 1 算不在区间 → RATE_MISSING', () {
      final missing = preview('1.1', '7.5', currency: 'USD', rateMissing: true);
      expect(missing.flag, SalesIntakePricingFlag.rateMissing);
      expect(missing.discount, isNull);
    });
  });
}
