import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/features/purchase/models/purchase_doc.dart';
import 'package:uten_imp/features/subcontract/models/subcontract_doc.dart';
import 'package:uten_imp/features/operations_workbench/models/operations_workbench.dart';

void main() {
  test(
    'purchase and subcontract preserve the server exact signed difference',
    () {
      const json = {
        'differenceQty': -9007199254740992,
        'differenceQtyExact': '-9007199254740993.0001',
      };
      expect(
        PurchaseDocItem.fromJson(json).differenceQtyText,
        '-9007199254740993.0001',
      );
      expect(
        SubcontractDocItem.fromJson(json).differenceQtyText,
        '-9007199254740993.0001',
      );
    },
  );

  test('old responses leave variance unknown instead of inventing a zero', () {
    expect(PurchaseDocItem.fromJson(const {}).differenceQtyText, isNull);
    expect(SubcontractDocItem.fromJson(const {}).differenceQtyText, isNull);
  });

  test(
    'task center uses exact signed facts independently of administrative open quantity',
    () {
      final task = OperationsWorkbenchTask.fromJson(const {
        'taskId': 'ended-order-item',
        'supplyRoute': 'PURCHASE',
        'taskStatus': 'COMPLETED',
        'openQty': 0,
        'differenceQtyExact': '-1194',
      }, OperationsWorkbenchDepartment.purchase);
      expect(task.openQty, 0);
      expect(task.differenceQtyText, '-1194');
    },
  );
}
