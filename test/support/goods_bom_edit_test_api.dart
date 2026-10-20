import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/features/basic_data/models/goods_bom_item.dart';
import 'package:uten_imp/features/basic_data/repositories/goods_bom_repository.dart';

/// UI fixture transport. Snapshot and draft remain separate from canonical fake
/// commands; only the explicit reviewed commit replays into [repository].
class GoodsBomEditTestApi extends ApiClient {
  GoodsBomEditTestApi(this.repository) : super(Dio());
  final GoodsBomRepository repository;
  final operations = <Map<String, dynamic>>[];
  Object? previewFailureOnce;
  int otherUsageCount = 0;
  int previewCalls = 0, commitCalls = 0;

  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    if (path.endsWith('/snapshot')) {
      final id = path.split('/').reversed.elementAt(3);
      return {
        'items': [
          for (final item in await repository.list(id)) bomItemTestJson(item),
        ],
        'fingerprint': 'fixture-$id',
      };
    }
    final id = path.split('/').last;
    return {'id': id, 'name': id, 'unitName': '个', 'issueMethod': 'ORDER'};
  }

  @override
  Future<Map<String, dynamic>> post(
    String path, {
    Object? body,
    Map<String, dynamic>? headers,
    Map<String, dynamic>? query,
  }) async {
    final request = Map<String, dynamic>.from(body! as Map);
    final pending = [
      for (final op in request['operations'] as List)
        Map<String, dynamic>.from(op as Map),
    ];
    if (path.endsWith('/preview')) {
      previewCalls++;
      final failure = previewFailureOnce;
      previewFailureOnce = null;
      if (failure != null) throw failure;
      return {
        'previewToken': 'fixture-preview',
        'operationCount': pending.length,
        'affectedParents': [
          for (final id
              in pending.map((op) => op['goodsId']).whereType<String>().toSet())
            {
              'goodsId': id,
              'goodsName': id,
              'otherUsageCount': otherUsageCount,
            },
        ],
        'otherUsageCount': otherUsageCount,
      };
    }
    commitCalls++;
    operations.addAll(pending);
    final root = path.split('/').reversed.elementAt(3);
    for (var index = 0; index < pending.length; index++) {
      final op = pending[index];
      final parent = op['goodsId'] as String? ?? root;
      switch (op['type']) {
        case 'CREATE':
          final items = [Map<String, dynamic>.from(op['body'] as Map)];
          while (index + 1 < pending.length &&
              pending[index + 1]['type'] == 'CREATE' &&
              pending[index + 1]['goodsId'] == parent) {
            items.add(
              Map<String, dynamic>.from(pending[++index]['body'] as Map),
            );
          }
          await repository.paste(
            mode: BomPasteMode.append,
            targets: [BomPasteTarget(parent)],
            items: items,
          );
        case 'UPDATE':
          await repository.update(
            parent,
            op['itemId'] as String,
            Map<String, dynamic>.from(op['body'] as Map),
          );
        case 'DELETE':
          await repository.deleteMany(
            root,
            List<String>.from(op['itemIds'] as List),
          );
        case 'MOVE':
          await repository.move(root, [
            for (final move
                in (op['moves'] as List).cast<Map<String, dynamic>>())
              GoodsBomMove(
                itemId: move['itemId'] as String,
                targetParentGoodsId: move['targetParentGoodsId'] as String,
                anchorItemId: move['anchorItemId'] as String?,
                afterAnchor: move['afterAnchor'] == true,
              ),
          ]);
      }
    }
    return {
      'operationCount': pending.length,
      'affectedGoodsIds': <String>[],
      'itemIds': <String, String>{},
    };
  }
}

Map<String, dynamic> bomItemTestJson(GoodsBomItem item) => {
  'id': item.id,
  'componentGoodsId': item.componentGoodsId,
  'componentCode': item.componentCode,
  'componentName': item.componentName,
  'componentModel': item.componentModel,
  'componentSpec': item.componentSpec,
  'componentMaterial': item.componentMaterial,
  'componentUnitName': item.componentUnitName,
  'componentColorName': item.componentColorName,
  'colorId': item.colorId,
  'colorLegacyId': item.colorLegacyId,
  'defaultSupplierId': item.defaultSupplierId,
  'vendLegacyId': item.vendLegacyId,
  'qty': item.qty,
  'price': item.price,
  'total': item.total,
  'summary': item.summary,
  'legacyId': item.legacyId,
  'hasChildren': item.hasChildren,
  'componentSourceType': item.componentSourceType,
  'controlStage': item.controlStage.code,
  'consumptionBasis': item.consumptionBasis.code,
  'basisOutputQty': item.basisOutputQty,
  'allowPartialPackage': item.allowPartialPackage,
  'hardGate': item.hardGate,
  'auditedAt': item.auditedAt?.toIso8601String(),
  'systemLearned': item.systemLearned,
  'componentIssueMethod': item.componentIssueMethod,
  'unitWeightGrams': item.unitWeightGrams,
  'warnings': item.warnings,
  'actualQty': item.actual.qty,
  'actualStatus': item.actual.status?.code,
  'usesActual': item.actual.usesActual,
  'actualNetQty': item.actual.netQty,
  'actualOutputQty': item.actual.outputQty,
  'actualSampleCount': item.actual.sampleCount,
};

Future<void> enterBomEdit(WidgetTester tester) async {
  await tester.tap(find.byKey(const Key('goods-bom-edit-mode')).hitTestable());
  await tester.pumpAndSettle();
}

Future<void> saveBomEdit(WidgetTester tester) async {
  await tester.tap(find.byKey(const Key('goods-bom-edit-mode')).hitTestable());
  await tester.pumpAndSettle();
  final confirm = find.byKey(const Key('goods-bom-save-confirm')).hitTestable();
  if (confirm.evaluate().isNotEmpty) {
    await tester.tap(confirm);
    await tester.pumpAndSettle();
  }
}
