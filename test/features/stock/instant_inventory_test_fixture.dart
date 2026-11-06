import 'package:dio/dio.dart';
import 'package:uten_imp/core/network/api_client.dart';

class InstantInventoryApiFixture extends ApiClient {
  InstantInventoryApiFixture({
    required this.withTotals,
    required this.withAnalysis,
    this.withCategories = false,
  }) : super(Dio());

  final bool withTotals;
  final bool withAnalysis;
  final bool withCategories;
  final inventoryRequests = <Map<String, dynamic>>[];
  Future<Map<String, dynamic>> Function(Map<String, dynamic> query)?
  onInventory;
  Future<Map<String, dynamic>>? nextInventoryResponse;

  @override
  Future<List<Map<String, dynamic>>> getList(
    String path, {
    Map<String, dynamic>? query,
  }) async => withCategories && path.contains('material-categories/tree')
      ? [
          <String, dynamic>{
            'id': 'raw',
            'code': 'RAW',
            'name': '原材料',
            'goodsCount': 137,
          },
        ]
      : <Map<String, dynamic>>[];

  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    if (!path.contains('instant-inventory')) return <String, dynamic>{};
    final request = Map<String, dynamic>.from(query ?? {});
    inventoryRequests.add(request);
    final handler = onInventory;
    if (handler != null) return handler(request);
    final deferred = nextInventoryResponse;
    if (deferred != null) {
      nextInventoryResponse = null;
      return deferred;
    }
    return response(query: request);
  }

  List<Map<String, dynamic>> get seedRows => [
    <String, dynamic>{
      'goodsId': '11111111-1111-1111-1111-111111111111',
      'name': '螺丝',
      'unitName': '个',
      'qty': 10,
      'weight': 1.5,
      'weightEstimated': true,
    },
    <String, dynamic>{
      'goodsId': '22222222-2222-2222-2222-222222222222',
      'name': '包装箱',
      'unitName': '箱',
      'qty': 2,
      'weight': 3,
    },
  ];

  /// Complete synthetic authorized scope: 100 positive, two negative and 35
  /// zero rows; 900 pieces / 20 boxes and 3520 kg, with 12 unweighed rows.
  List<Map<String, dynamic>> get allRows => [
    ...seedRows,
    for (var index = 2; index < 137; index++)
      {
        'goodsId':
            '00000000-0000-4000-8000-${index.toString().padLeft(12, '0')}',
        'name': '完整库存物料$index',
        'unitName': index == 3 ? '箱' : '个',
        'qty': index == 2
            ? 796
            : index == 3
            ? 18
            : index < 100
            ? 1
            : index < 102
            ? -1
            : 0,
        if (index < 90 || index >= 102) 'weight': index == 2 ? 3515.5 : 0,
        if (index >= 90 && index < 102) 'weightUnknown': true,
        if (index == 3 || index == 4) 'weightEstimated': true,
      },
  ];

  Map<String, dynamic> response({Map<String, dynamic> query = const {}}) {
    final page = (query['page'] as num?)?.toInt() ?? 1;
    final size = ((query['size'] as num?)?.toInt() ?? 20).clamp(1, 20);
    return <String, dynamic>{
      'items': allRows.skip((page - 1) * size).take(size).toList(),
      'page': page,
      'size': size,
      'total': allRows.length,
      'totalPages': (allRows.length + size - 1) ~/ size,
      'readScopeVersion': 'inventory-fixture-v1',
      if (withTotals)
        'totals': <Object?>[
          <String, dynamic>{
            'key': 'weight',
            'label': '合计库存重量',
            'type': 'weight',
            'groupKey': null,
            'groups': <Object?>[
              <String, dynamic>{'unit': null, 'value': 3520},
            ],
          },
          <String, dynamic>{
            'key': 'weight_unknown_rows',
            'label': '重量未知',
            'type': 'count',
            'groupKey': null,
            'groups': <Object?>[
              <String, dynamic>{'unit': null, 'value': 12},
            ],
          },
          <String, dynamic>{
            'key': 'weight_estimated_rows',
            'label': '重量含估算',
            'type': 'count',
            'groupKey': null,
            'groups': <Object?>[
              <String, dynamic>{'unit': null, 'value': 3},
            ],
          },
          <String, dynamic>{
            'key': 'qty',
            'label': '合计库存数量',
            'type': 'number',
            'groupKey': 'unit_name',
            'groups': <Object?>[
              <String, dynamic>{'unit': '个', 'value': 900},
              <String, dynamic>{'unit': '箱', 'value': 20},
              <String, dynamic>{'unit': '米', 'value': 0},
            ],
          },
          <String, dynamic>{
            'key': 'pending_qty',
            'label': '合计待检量',
            'type': 'number',
            'groupKey': 'unit_name',
            'groups': <Object?>[
              <String, dynamic>{'unit': '个', 'value': 11},
              <String, dynamic>{'unit': '箱', 'value': 0},
              <String, dynamic>{'unit': '米', 'value': 0},
            ],
          },
          <String, dynamic>{
            'key': 'pending_stock_in_qty',
            'label': '合计合格待入库',
            'type': 'number',
            'groupKey': 'unit_name',
            'groups': <Object?>[
              <String, dynamic>{'unit': '个', 'value': 0},
              <String, dynamic>{'unit': '箱', 'value': 7},
              <String, dynamic>{'unit': '米', 'value': 0},
            ],
          },
          if (withAnalysis)
            for (final entry in const <String, int>{
              'inventory_rows': 137,
              'positive_stock_rows': 100,
              'negative_stock_rows': 2,
              'negative_balance_rows': 3,
              'zero_stock_rows': 35,
              'pending_inspection_rows': 4,
              'pending_stock_in_rows': 5,
              'stocked_weight_known_rows': 90,
              'stocked_weight_unknown_rows': 12,
              'stocked_weight_estimated_rows': 3,
              'missing_unit_rows': 0,
              'nonpositive_pending_inspection_rows': 1,
              'nonpositive_pending_stock_in_rows': 2,
            }.entries)
              <String, dynamic>{
                'key': entry.key,
                'label': entry.key,
                'type': 'count',
                'groupKey': null,
                'groups': <Object?>[
                  <String, dynamic>{'unit': null, 'value': entry.value},
                ],
              },
        ],
    };
  }
}
