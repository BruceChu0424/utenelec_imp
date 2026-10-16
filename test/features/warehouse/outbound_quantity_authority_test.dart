import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/features/subcontract/models/subcontract_doc.dart';
import 'package:uten_imp/features/warehouse/models/production_draw_discovery_row.dart';
import 'package:uten_imp/features/warehouse/models/stock_doc.dart';
import 'package:uten_imp/features/warehouse/models/subcontract_outbound.dart';
import 'package:uten_imp/features/warehouse/models/subcontract_outbound_execution.dart';
import 'package:uten_imp/features/warehouse/models/warehouse_form_draft_codec.dart';
import 'package:uten_imp/features/warehouse/widgets/production_draw_detail_table.dart';
import 'package:uten_imp/features/warehouse/widgets/subcontract_outbound_detail_table.dart';
import 'package:uten_imp/shared/measurement/document_quantity.dart';
import 'package:uten_imp/shared/models/production_material_discovery.dart';

void main() {
  SubcontractOutboundLineDraft subcontract(String? exact, {String? maximum}) =>
      SubcontractOutboundLineDraft(
        OutboundPickLine.fromJson({
          'issueItemId': 'item',
          'planItemId': 'plan',
          'goodsId': 'goods',
          'qty': 100000000000000.0,
          'qtyExact': exact,
          'requestedQty': 100000000000000.0,
          'requestedQtyExact': maximum ?? exact,
        }),
        SubcontractDocItem.fromJson({
          'id': 'item',
          'planItemId': 'plan',
          'goodsId': 'goods',
          'unitId': 'unit',
          'unitRate': 1,
          'unitRateExact': '1',
          'qty': 100000000000000.0,
          'qtyExact': exact,
        }),
      );

  StockDocItem draw({
    String? requested = '99999999999999.9999',
    String? issued = '99999999999999.9998',
  }) => StockDocItem.fromJson({
    'id': 'item',
    'goodsId': 'goods',
    'unitId': 'unit',
    'qty': 100000000000000.0,
    'qtyExact': requested,
    'requestedQty': 100000000000000.0,
    'requestedQtyExact': requested,
    'issuedQty': 100000000000000.0,
    'issuedQtyExact': issued,
  });

  test(
    'subcontract initialization and payload retain every original digit',
    () {
      final row = subcontract('99999999999999.9999');
      addTearDown(row.dispose);
      expect(row.qty.text, '99999999999999.9999');
      expect(row.validate(), isNull);
      expect(row.toPayload()['qty'], '99999999999999.9999');
      row.qty.text = '99999999999999.9998';
      expect(row.validate(), isNull);
      expect(row.toPayload()['qty'], '99999999999999.9998');
    },
  );

  test('subcontract upper bound compares the last decimal digit exactly', () {
    final row = subcontract('99999999999999.9998');
    addTearDown(row.dispose);
    row.qty.text = '99999999999999.9999';
    expect(row.validate(), subcontractOutboundQuantityInvalid);
    expect(row.toPayload, throwsFormatException);
  });

  test('minimum quantity remains exact and zero retains skip semantics', () {
    final row = subcontract('0.0001');
    addTearDown(row.dispose);
    expect(row.toPayload()['qty'], '0.0001');
    row.qty.text = '0.0000';
    expect(row.skipped, isTrue);
    expect(subcontractOutboundPayloadItems([row]), isEmpty);
  });

  for (final invalid in [
    '1.00001',
    '100000000000000',
    '1e3',
    '-1',
    'NaN',
    '',
  ]) {
    test('invalid quantity cannot become a subcontract command: $invalid', () {
      final row = subcontract('99999999999999.9999');
      addTearDown(row.dispose);
      row.qty.text = invalid;
      expect(row.validate(), isNotNull);
      expect(row.toPayload, throwsFormatException);
    });
  }

  test(
    'missing recorded subcontract facts never produce a numeric command',
    () {
      final row = subcontract(null);
      addTearDown(row.dispose);
      expect(row.qty.text, isEmpty);
      row.qty.text = '1';
      expect(row.validate(), contains('原文缺失'));
      expect(row.toPayload, throwsFormatException);
      expect(recordedDocumentDecimal({'qty': 1.25}, 'qty'), isNull);
      expect(recordedDocumentDecimal({'qty': '1.25'}, 'qty'), '1.25');
    },
  );

  test(
    'DRAW difference and forward limit survive rounded numeric companions',
    () {
      final item = draw();
      expect(
        item.remainingQty,
        0,
        reason: 'legacy double estimate loses this delta',
      );
      expect(item.remainingQtyText, '0.0001');
      final row = ProductionDrawDetailRow(
        const StockDocDetail(id: 'draw'),
        item,
      );
      expect(drawIssueQtyError(row, '0.0001'), isNull);
      expect(drawIssueQtyError(row, '0.0002'), contains('不能超过'));
      expect(drawIssueQtyError(row, '0.00001'), isNotNull);
    },
  );

  test(
    'null and numeric-only DRAW facts stay unknown rather than become zero',
    () {
      for (final item in [
        draw(issued: null),
        StockDocItem.fromJson({'qty': 10, 'requestedQty': 10, 'issuedQty': 0}),
      ]) {
        expect(item.remainingQtyText, isNull);
        expect(
          drawIssueQtyError(
            ProductionDrawDetailRow(const StockDocDetail(id: 'draw'), item),
            '1',
          ),
          contains('原文缺失'),
        );
      }
    },
  );

  test(
    'cancel issue uses recorded upper bound and precision with zero skip',
    () {
      final item = draw();
      expect(drawCancelIssueQtyError(item, '99999999999999.9998'), isNull);
      expect(
        drawCancelIssueQtyError(item, '99999999999999.9999'),
        contains('不能超过'),
      );
      expect(drawCancelIssueQtyError(item, '0'), isNull);
      expect(drawCancelIssueQtyError(item, '1.00001'), isNotNull);
      expect(
        drawCancelIssueQtyError(draw(issued: null), '1'),
        contains('原文缺失'),
      );
    },
  );

  test(
    'recorded DRAW facts survive interrupted-request draft serialization',
    () {
      final restored = StockDocDetail.fromJson(
        stockDocumentDraftFacts(StockDocDetail(id: 'draw', items: [draw()])),
      );
      expect(restored.items.single.remainingQtyText, '0.0001');
      expect(restored.items.single.issuedQtyText, '99999999999999.9998');
    },
  );

  test('safe legacy snapshots restore but rounded sources remain blocked', () {
    final old = {'qty': 10.0, 'unitRate': 1.0, 'goodsId': 'g'};
    expect(
      subcontractOutboundSnapshotMatches(
        jsonEncode(old),
        jsonEncode({'qty': '10.0000', 'unitRate': '1', 'goodsId': 'g'}),
      ),
      isTrue,
    );
    expect(
      subcontractOutboundSnapshotMatches(
        'o|g|c|u|1.0|p|pc|10.0',
        'o|g|c|u|1|p|pc|10.0000',
      ),
      isTrue,
    );
    final rounded = {'qty': 100000000000000.0, 'unitRate': 1.0};
    expect(
      subcontractOutboundSnapshotMatches(rounded, {
        'qty': '99999999999999.9999',
        'unitRate': '1',
      }),
      isFalse,
    );
    expect(
      rounded['qty'],
      100000000000000.0,
      reason: 'rejected draft remains intact',
    );
    expect(
      subcontractOutboundSnapshotMatches(old, {
        'qty': '10',
        'unitRate': '1',
        'goodsId': 'different',
      }),
      isFalse,
      reason: 'canonical migration does not skip source identity',
    );
  });

  test(
    'discovery input reads recorded text and validates before string payload',
    () {
      final request = ProductionMaterialDiscoveryDetail.fromJson({
        'requestId': 'request',
        'segmentId': 'segment',
        'version': 1,
        'status': 'PENDING',
      });
      final row = ProductionDrawDiscoveryRow(
        request: request,
        index: 0,
        initial: {
          'goodsId': 'goods',
          'unitId': 'unit',
          'warehouseId': 'warehouse',
          'qty': 100000000000000.0,
          'qtyExact': '99999999999999.9999',
        },
      );
      addTearDown(row.dispose);
      expect(row.quantity.text, '99999999999999.9999');
      expect(row.toJson()['qty'], '99999999999999.9999');
      row.quantity.text = '100000000000000';
      expect(row.quantityError, isNotNull);
      expect(row.toJson, throwsFormatException);
      final unknown = ProductionDrawDiscoveryRow(
        request: request,
        index: 1,
        initial: {'qty': 12.5},
      );
      addTearDown(unknown.dispose);
      expect(unknown.quantity.text, isEmpty);
      expect(unknown.toJson, throwsFormatException);
    },
  );
}
