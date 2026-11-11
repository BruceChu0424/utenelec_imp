import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/features/production/models/material_preparation_original_command.dart';
import 'package:uten_imp/features/production/models/production_material_analysis.dart';

void main() {
  final view = ProductionMaterialAnalysisView.fromJson({
    'analysisId': 'analysis-original',
    'version': 3,
    'fingerprint': 'a' * 64,
    'warehouseId': 'warehouse-original',
    'products': <Object>[],
    'flatMaterials': <Object>[],
    'supplyActions': <Object>[],
  });
  test(
    'original request survives durable JSON and never rereads current quantity or date',
    () {
      final command = MaterialPreparationOriginalCommand.issuePlans(
        analysis: view,
        warehouseId: 'warehouse-original',
        idempotencyKey: 'original-plan-command',
        billDate: '2026-11-11',
        approveNow: true,
        lines: const [
          MaterialAnalysisIssueLine(
            analysisLineId: 'original-product',
            qty: 1234567890123,
            qtyExact: '1234567890123.0001',
            departmentId: 'original-workshop',
            workerId: 'original-worker',
          ),
        ],
        rowLabels: const {'original-row': '原产品'},
        lineIds: const {'original-material'},
      );
      final restored = MaterialPreparationOriginalCommand.fromDraft(
        Map<String, dynamic>.from(
          jsonDecode(jsonEncode(command.toDraft())) as Map,
        ),
      );
      expect(restored.bodyJson, command.bodyJson);
      final editable = restored.toBody();
      (editable['lines'] as List).clear();
      editable['billDate'] = '2099-01-01';
      final original = restored.toBody();
      expect(original['billDate'], '2026-11-11');
      expect(
        ((original['lines'] as List).single as Map)['qty'],
        '1234567890123.0001',
      );
      expect(original['idempotencyKey'], 'original-plan-command');
    },
  );
  test('notify replay retains exact original source allocation and scope', () {
    final command = MaterialPreparationOriginalCommand.notify(
      analysis: view,
      idempotencyKey: 'original-notify-command',
      target: MaterialSupplyRoute.subcontract,
      actionGroupKeys: const ['original-source'],
      quantities: const [
        MaterialSupplyQuantityInput(
          actionGroupKey: 'original-source',
          qty: 500,
          safetyReplenishmentQty: 0,
          qtyExact: '500.0001',
          quantityMode: 'COVERAGE_TOTAL',
          orderMethod: MaterialPreparationOrderMethod.orderAll,
        ),
      ],
    );
    expect(
      MaterialPreparationOriginalCommand.fromDraft(command.toDraft()).bodyJson,
      command.bodyJson,
    );
    expect(command.toBody()['target'], 'SUBCONTRACT');
  });
  test('unknown protocols and fields never become a replacement request', () {
    final command = MaterialPreparationOriginalCommand.notify(
      analysis: view,
      idempotencyKey: 'original-notify-command',
      target: MaterialSupplyRoute.buy,
    );
    final future = command.toDraft()..['operation'] = 'arbitrary-write';
    expect(
      () => MaterialPreparationOriginalCommand.fromDraft(future),
      throwsFormatException,
    );
    final body = command.toBody()..['futureBusinessPolicy'] = 'unknown';
    final next = command.toDraft()..['bodyJson'] = jsonEncode(body);
    expect(
      () => MaterialPreparationOriginalCommand.fromDraft(next),
      throwsFormatException,
    );
  });
}
