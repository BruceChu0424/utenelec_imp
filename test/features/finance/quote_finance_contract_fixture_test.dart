// 报价核价 JSON 契约(ADR-134)：前端解析/请求体与服务端 record 逐字一致。
//
// 两层：
//   1. 夹具：照服务端 record(QuoteFinanceListItem / QuoteFinanceReviewDto(+Line) /
//      QuoteRevisionDto / QuoteFinanceEditRequest / QuoteFinanceDecisionRequest /
//      QuoteActionRequest / SalesOrderFinanceReviewDto.SourceQuote)抄写的 JSON，锁住解析结果与请求体；
//   2. 源码契约：直接读服务端 record 源码的组件名，核对前端 fromJson 读的键、请求体写的键、
//      动作码与报价分桶键都在服务端存在——任一侧改名另一侧不跟就红(同 badge_registry_contract_test)。
//      服务端源码根默认 `server`(合并后的主仓)，可用环境变量 UTEN_CONTRACT_SERVER_ROOT 指到别的
//      服务端工作区(合并前核对并行开发的服务端包)。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/features/finance/models/sales_order_finance_confirmation.dart';
import 'package:uten_imp/features/finance/models/sales_quote_finance_review.dart';
import 'package:uten_imp/features/finance/repositories/sales_quote_finance_review_repository.dart';
import 'package:uten_imp/features/sales/models/sales_doc.dart';

// ---------------------------------------------------------------- 夹具(照服务端 record 抄写)

/// QuoteFinanceListItem(全部组件)。
const _listItemJson = <String, dynamic>{
  'id': '0d7a3c1e-0000-4000-8000-000000000001',
  'billNo': 'XB20260927001',
  'billDate': '2026-09-27',
  'clientName': '尼日利亚SUNAS',
  'sellerName': '张销售',
  'makerName': '李制单',
  'submittedAt': '2026-09-27T09:30:00+08:00',
  'lineCount': 35,
  'pricePendingCount': 2,
  'totalOriginal': '12345.6700',
  'clientFileCurrency': 'USD',
  'statusBucket': 'PENDING_FINANCE',
  'reviewRevision': 3,
  'resubmitted': true,
  'financeReturnReason': null,
  'financeReturnedAt': null,
  'financeConfirmedAt': null,
  'financeConfirmedByName': null,
  'convertedOrderNo': null,
  'claimedByName': '王会计',
  'claimedByMe': false,
};

/// QuoteFinanceReviewDto.Line(全部组件)：本行已存单价在服务端叫 listPrice。
const _lineJson = <String, dynamic>{
  'itemId': '0d7a3c1e-0000-4000-8000-0000000000a1',
  'lineNo': 1,
  'goodsId': '0d7a3c1e-0000-4000-8000-0000000000g1',
  'goodsCode': 'LX-100',
  'goodsName': '台灯',
  'colorName': '白',
  'unitName': '个',
  'qty': '10',
  'listPrice': '100.0000',
  'priceSource': 'MASTER',
  'financePriceByName': null,
  'financePriceAt': null,
  'currentMasterPrice': '120.0000',
  'clientPrice': '13.2000',
  'clientPriceLocal': '94.8000',
  'dealPrice': '95.00000000',
  'discount': '0.9500',
  'amount': '950.00000000',
  'fileAmountLocal': '948.0000',
  'diffToFile': '2.00000000',
  'salesProposedDiscount': '0.9000',
  'lastFinanceConfirmedDiscount': '0.9500',
  'changedSinceLastConfirm': true,
  'clientModel': 'DL-01',
  'clientGoodsName': 'DESK LAMP',
  'remark': '白色',
  'blockingReason': null,
};

/// QuoteFinanceReviewDto(全部组件)。
final _reviewJson = <String, dynamic>{
  'id': '0d7a3c1e-0000-4000-8000-000000000001',
  'billNo': 'XB20260927001',
  'billDate': '2026-09-27',
  'clientId': '0d7a3c1e-0000-4000-8000-0000000000c1',
  'clientName': '尼日利亚SUNAS',
  'clientCode': 'C001',
  'makerName': '李制单',
  'sellerName': '张销售',
  'currencyName': '人民币',
  'baseCurrency': true,
  'settlementMethodId': '0d7a3c1e-0000-4000-8000-0000000000s1',
  'settlementMethodName': '月结30天',
  'validUntil': '2026-10-31',
  'deliverDate': '2026-11-15',
  'contractNo': 'PI-2026-001',
  'remark': 'FOB 宁波',
  'clientFileCurrency': 'USD',
  'financeRate': '7.1818',
  'financeRateMissing': false,
  'status': 2,
  'statusBucket': 'PENDING_FINANCE',
  'reviewRevision': 3,
  'submittedAt': '2026-09-27T09:30:00+08:00',
  'submittedByName': '张销售',
  'financeRemark': '老客户价',
  'financeReturnReason': null,
  'financeReturnedAt': null,
  'financeReturnedByName': null,
  'financeConfirmedAt': null,
  'financeConfirmedByName': null,
  'totalOriginal': '950.0000',
  'fileTotalLocal': '948.0000',
  'pricePendingCount': 0,
  'blockingLineCount': 0,
  'resubmitted': true,
  'convertedOrderNo': null,
  'canMaintainGoodsPrice': true,
  'financeActions': ['edit', 'return', 'confirm'],
  'claimType': 'SALES_QUOTE_FINANCE_REVIEW',
  'lines': [_lineJson],
  'revisions': [
    {
      'revision': 3,
      'action': 'SUBMIT',
      'actionLabel': '提交财务核价',
      'actorName': '张销售',
      'reason': null,
      'createdAt': '2026-09-27T09:30:00+08:00',
    },
  ],
};

// ---------------------------------------------------------------- 源码契约工具

String get _serverRoot =>
    '${Platform.environment['UTEN_CONTRACT_SERVER_ROOT'] ?? 'server'}'
    '/src/main/java/com/uten/imp';

String _java(String relative) {
  final file = File('$_serverRoot/$relative');
  if (!file.existsSync()) {
    fail(
      '服务端源码 ${file.path} 不存在: 报价核价服务端包(ADR-134)合并前本组必然为红, '
      '可设 UTEN_CONTRACT_SERVER_ROOT 指到服务端工作区核对',
    );
  }
  return file.readAsStringSync();
}

/// record 的组件名(去掉注释、字符串、注解后取每个组件的最后一个标识符)。
Set<String> _recordComponents(String source, String record) {
  final text = source
      .replaceAll(RegExp(r'/\*[\s\S]*?\*/'), ' ')
      .replaceAll(RegExp(r'//[^\n]*'), ' ')
      .replaceAll(RegExp(r'"(?:[^"\\]|\\.)*"'), '""');
  final match = RegExp('record\\s+$record\\s*\\(').firstMatch(text);
  expect(match, isNotNull, reason: 'record $record not found');
  final parts = <String>[];
  var depth = 0;
  final buffer = StringBuffer();
  for (var i = match!.end; i < text.length; i++) {
    final c = text[i];
    if (c == ')' && depth == 0) {
      parts.add(buffer.toString());
      break;
    }
    if (c == '(' || c == '<') depth++;
    if (c == ')' || c == '>') depth--;
    if (c == ',' && depth == 0) {
      parts.add(buffer.toString());
      buffer.clear();
      continue;
    }
    buffer.write(c);
  }
  return {
    for (final part in parts)
      if (RegExp(r'(\w+)\s*$').firstMatch(part.trim()) case final m?)
        m.group(1)!,
  };
}

/// Dart 源码里一段 fromJson 读到的键(json['key'])。
Set<String> _dartJsonKeys(String source, String from, String to) {
  final start = source.indexOf(from);
  final end = source.indexOf(to, start + 1);
  expect(start, greaterThanOrEqualTo(0), reason: from);
  expect(end, greaterThan(start), reason: to);
  return {
    for (final m in RegExp(
      r"json\['(\w+)'\]",
    ).allMatches(source.substring(start, end)))
      m.group(1)!,
  };
}

const _modelPath =
    'lib/features/finance/models/sales_quote_finance_review.dart';

void main() {
  group('fixtures copied from the server records', () {
    test('queue row', () {
      final item = SalesQuoteFinanceListItem.fromJson(_listItemJson);
      expect(item.quoteId, '0d7a3c1e-0000-4000-8000-000000000001');
      expect(item.lineCount, 35);
      expect(item.pricePendingCount, 2);
      expect(item.clientFileCurrency, 'USD');
      expect(item.claimedByName, '王会计');
      expect(item.claimedByMe, isFalse);
      expect(item.resubmitted, isTrue);
    });

    test('review header, lines and revisions', () {
      final review = SalesQuoteFinanceReview.fromJson(_reviewJson);
      expect(review.quoteId, '0d7a3c1e-0000-4000-8000-000000000001');
      expect(review.financeRate, '7.1818');
      expect(review.financeRateMissing, isFalse);
      expect(review.settlementMethodId, '0d7a3c1e-0000-4000-8000-0000000000s1');
      expect(review.canMaintainGoodsPrice, isTrue);
      expect(review.claimType, kSalesQuoteFinanceClaimType);
      expect(review.allows(SalesQuoteFinanceAction.edit), isTrue);
      expect(review.allows(SalesQuoteFinanceAction.returnToSales), isTrue);
      expect(review.allows(SalesQuoteFinanceAction.confirm), isTrue);
      expect(review.allows(SalesQuoteFinanceAction.reopen), isFalse);
      expect(review.needsClaim, isTrue);
      expect(review.revisions.single.action, SalesQuoteRevisionAction.submit);

      final line = review.lines.single;
      expect(line.storedPrice, '100.0000');
      expect(line.listPrice, '100.0000', reason: 'frozen list price in use');
      expect(line.currentMasterPrice, '120.0000');
      expect(line.canRefreshFromMaster, isTrue);
      expect(line.dealPrice, '95.00000000');
      expect(line.amount, '950.00000000');
      expect(line.diffToFile, '2.00000000');
      expect(line.changedSinceLastConfirm, isTrue);
      expect(line.needsFinancePrice, isFalse);
    });

    test('a confirmed quote only offers reopen, which needs no claim', () {
      final review = SalesQuoteFinanceReview.fromJson({
        ..._reviewJson,
        'status': 1,
        'statusBucket': 'APPROVED',
        'financeActions': ['reopen'],
      });
      expect(review.allows(SalesQuoteFinanceAction.reopen), isTrue);
      expect(review.hasFinanceActions, isTrue);
      expect(review.needsClaim, isFalse);
    });

    test('finance-priced line: list price comes from the goods master', () {
      final line = SalesQuoteFinanceLine.fromJson({
        ..._lineJson,
        'listPrice': '130.0000',
        'priceSource': 'FINANCE',
        'discount': '1.0000',
      });
      expect(line.isFinancePriced, isTrue);
      expect(line.listPrice, '120.0000');
      expect(line.canRefreshFromMaster, isFalse);
    });

    test('edit body: whole header state + one change per line', () {
      final body = quoteFinanceEditBody(
        expectedRevision: 3,
        expectedClaimId: 'claim-1',
        header: const SalesQuoteFinanceHeader(
          validUntil: '2026-10-31',
          financeRemark: '  ',
        ),
        lines: const [
          SalesQuoteFinanceLineEdit.discount(itemId: 'a', discount: '0.9500'),
          SalesQuoteFinanceLineEdit.dealPrice(itemId: 'b', dealPrice: '120'),
          SalesQuoteFinanceLineEdit.giftZeroPrice(itemId: 'c'),
          SalesQuoteFinanceLineEdit.useMasterPrice(itemId: 'd'),
        ],
      );
      expect(body, {
        'expectedRevision': 3,
        'expectedClaimId': 'claim-1',
        'validUntil': '2026-10-31',
        'settlementMethodId': null,
        'financeRemark': null,
        'lines': [
          {'itemId': 'a', 'discount': '0.9500'},
          {'itemId': 'b', 'dealPrice': '120'},
          {'itemId': 'c', 'giftZeroPrice': true},
          {'itemId': 'd', 'useMasterPrice': true},
        ],
      });
    });

    test('decision and reopen bodies', () {
      expect(
        quoteFinanceDecisionBody(
          expectedRevision: 3,
          expectedClaimId: 'claim-1',
          text: ' 客户要改数量 ',
        ),
        {'expectedRevision': 3, 'expectedClaimId': 'claim-1', 'text': '客户要改数量'},
      );
      expect(
        quoteFinanceDecisionBody(expectedRevision: 3, expectedClaimId: 'c'),
        {'expectedRevision': 3, 'expectedClaimId': 'c'},
      );
      expect(quoteFinanceReopenBody(expectedRevision: 4), {
        'expectedRevision': 4,
      });
    });

    test('order source quote carries the all-lines-match flag', () {
      final quote = SalesOrderSourceQuote.tryFromJson(const {
        'id': 'q-1',
        'billNo': 'XB-1',
        'financeConfirmedByName': '王会计',
        'financeConfirmedAt': '2026-09-27T10:00:00+08:00',
        'allLinesMatch': true,
      });
      expect(quote?.allLinesMatch, isTrue);
      expect(quote?.financeConfirmedByName, '王会计');
    });
  });

  group('source contract with the server records', () {
    const dto = 'features/sales/quote/dto';

    test('queue row keys exist on QuoteFinanceListItem', () {
      final server = _recordComponents(
        _java('$dto/QuoteFinanceListItem.java'),
        'QuoteFinanceListItem',
      );
      final dart = _dartJsonKeys(
        File(_modelPath).readAsStringSync(),
        'factory SalesQuoteFinanceListItem.fromJson',
        'class SalesQuoteFinanceLine',
      );
      expect(dart.difference(server), isEmpty);
      expect(server.difference(dart), isEmpty, reason: 'every field is read');
    });

    test('line and header keys exist on QuoteFinanceReviewDto', () {
      final source = _java('$dto/QuoteFinanceReviewDto.java');
      final model = File(_modelPath).readAsStringSync();
      final lineKeys = _dartJsonKeys(
        model,
        'factory SalesQuoteFinanceLine.fromJson',
        'class SalesQuoteFinanceReview',
      );
      // unitId: 服务端核价行还没有单位主键(见报告「需要别处改动」)，前端按单位名称兜底分组。
      expect(lineKeys.difference(_recordComponents(source, 'Line')), {
        'unitId',
      });
      final headerKeys = _dartJsonKeys(
        model,
        'factory SalesQuoteFinanceReview.fromJson',
        'class SalesQuoteFinanceLineEdit',
      );
      expect(
        headerKeys.difference(
          _recordComponents(source, 'QuoteFinanceReviewDto'),
        ),
        isEmpty,
      );
      final revisionServer = _recordComponents(
        _java('$dto/QuoteRevisionDto.java'),
        'QuoteRevisionDto',
      );
      expect(
        {
          'revision',
          'action',
          'actionLabel',
          'actorName',
          'reason',
          'createdAt',
        }.difference(revisionServer),
        isEmpty,
      );
    });

    test('request bodies only use QuoteFinanceEditRequest / '
        'QuoteFinanceDecisionRequest / QuoteActionRequest components', () {
      final edit = _java('$dto/QuoteFinanceEditRequest.java');
      final body = quoteFinanceEditBody(
        expectedRevision: 1,
        expectedClaimId: 'c',
        header: const SalesQuoteFinanceHeader(),
      );
      expect(
        body.keys.toSet().difference(
          _recordComponents(edit, 'QuoteFinanceEditRequest'),
        ),
        isEmpty,
      );
      final lineKeys = {
        for (final line in const [
          SalesQuoteFinanceLineEdit.discount(itemId: 'a', discount: '1'),
          SalesQuoteFinanceLineEdit.dealPrice(itemId: 'a', dealPrice: '1'),
          SalesQuoteFinanceLineEdit.giftZeroPrice(itemId: 'a'),
          SalesQuoteFinanceLineEdit.useMasterPrice(itemId: 'a'),
        ])
          ...line.toJson().keys,
      };
      expect(lineKeys, _recordComponents(edit, 'Line'));
      expect(
        quoteFinanceDecisionBody(
          expectedRevision: 1,
          expectedClaimId: 'c',
          text: 'x',
        ).keys.toSet(),
        _recordComponents(
          _java('$dto/QuoteFinanceDecisionRequest.java'),
          'QuoteFinanceDecisionRequest',
        ),
      );
      expect(
        quoteFinanceReopenBody(expectedRevision: 1).keys.toSet().difference(
          _recordComponents(
            _java('$dto/QuoteActionRequest.java'),
            'QuoteActionRequest',
          ),
        ),
        isEmpty,
      );
    });

    test('finance action codes are the ones the server hands out', () {
      final service = _java(
        'features/sales/quote/SalesQuoteFinanceService.java',
      );
      final method = service.substring(
        service.indexOf('private List<String> financeActions('),
      );
      final literals = {
        for (final m in RegExp(
          r'"(\w+)"',
        ).allMatches(method.substring(0, method.indexOf('\n    }'))))
          m.group(1)!,
      };
      expect(
        SalesQuoteFinanceAction.values.map((a) => a.code).toSet(),
        literals,
      );
    });

    test('quote list buckets match SalesQuoteService', () {
      final service = _java('features/sales/quote/SalesQuoteService.java');
      final buckets = {
        for (final m in RegExp(
          r'String BUCKET_\w+ = "(\w+)"',
        ).allMatches(service))
          m.group(1)!,
      };
      expect(SalesQuoteStage.segments.toSet().difference(buckets), isEmpty);
      expect(
        buckets,
        contains(SalesQuoteStage.awaitingConversion),
        reason: '「从报价引入」按 bucket=AWAITING_CONVERSION 在服务端筛(见报告)',
      );
    });

    test('order finance DTOs carry sourceQuote{..., allLinesMatch}', () {
      const order = 'features/sales/order/dto';
      final review = _java('$order/SalesOrderFinanceReviewDto.java');
      expect(
        _recordComponents(review, 'SourceQuote'),
        containsAll(<String>[
          'id',
          'billNo',
          'financeConfirmedByName',
          'financeConfirmedAt',
          'allLinesMatch',
        ]),
      );
      expect(
        _recordComponents(review, 'SalesOrderFinanceReviewDto'),
        containsAll(<String>['sourceQuote', 'clientFileCurrency']),
      );
      expect(
        _recordComponents(
          _java('$order/SalesOrderFinancePendingDto.java'),
          'SalesOrderFinancePendingDto',
        ),
        contains('sourceQuote'),
        reason: 'SPEC §6.1: 列表行与审核详情同一个 sourceQuote 形状',
      );
    });
  });
}
