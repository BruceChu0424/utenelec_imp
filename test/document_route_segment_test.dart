import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/router/permission_by_path.dart';
import 'package:uten_imp/core/router/route_names.dart';
import 'package:uten_imp/features/finance/models/finance_doc.dart';
import 'package:uten_imp/features/purchase/models/purchase_doc.dart';
import 'package:uten_imp/features/sales/models/sales_doc.dart';
import 'package:uten_imp/features/subcontract/models/subcontract_doc.dart';
import 'package:uten_imp/features/warehouse/models/stock_doc.dart';

void main() {
  group('document route segments', () {
    test('known segments resolve to the declared document type', () {
      expect(PurchaseDocType.tryByPath('receipts'), PurchaseDocType.receipt);
      expect(StockDocType.tryByCode('CHECK'), StockDocType.check);
      expect(SalesDocType.tryByPath('shipments'), SalesDocType.shipment);
      expect(
        SubcontractDocType.tryByPath('material-returns'),
        SubcontractDocType.materialReturn,
      );
      expect(
        FinanceDocType.tryByPath('bank-transfers'),
        FinanceDocType.bankTransfer,
      );
    });

    test('unknown segments never fall back to a writable business page', () {
      expect(PurchaseDocType.tryByPath('report'), isNull);
      expect(StockDocType.tryByCode('REPORT'), isNull);
      expect(SalesDocType.tryByPath('report'), isNull);
      expect(SubcontractDocType.tryByPath('report'), isNull);
      expect(FinanceDocType.tryByPath('assets'), isNull);

      expect(() => PurchaseDocType.byPath('report'), throwsArgumentError);
      expect(() => StockDocType.byCode('REPORT'), throwsArgumentError);
      expect(() => SalesDocType.byPath('report'), throwsArgumentError);
      expect(() => SubcontractDocType.byPath('report'), throwsArgumentError);
      expect(() => FinanceDocType.byPath('assets'), throwsArgumentError);
    });

    test('permission mapping also denies unknown dynamic segments', () {
      expect(requiredAnyPermFor('/purchase/unknown/new'), isEmpty);
      expect(requiredAnyPermFor('/warehouse/UNKNOWN/new'), isEmpty);
      expect(requiredAnyPermFor('/sales/unknown/new'), isEmpty);
      expect(requiredAnyPermFor('/subcontract/unknown/new'), isEmpty);
      expect(requiredAnyPermFor('/finance/unknown/new'), isEmpty);
      expect(RouteName.notFound, '/not-found');
    });
  });
}
