import 'dart:convert';
import 'package:flutter/material.dart';

bool readableShipmentReviewSnapshot(String? value) {
  if (value == null || value.isEmpty) return false;
  try {
    final json = jsonDecode(value);
    return json is Map && json['header'] is Map && json['items'] is List;
  } on Object {
    return false;
  }
}

/// Compares immutable financial review snapshots by stable item UUID. Decimal
/// properties arrive as text, so two amounts never collapse through double.
class ShipmentFinanceChangeSummary extends StatelessWidget {
  const ShipmentFinanceChangeSummary({
    super.key,
    required this.previous,
    required this.current,
    this.describe,
  });
  final String? previous;
  final String? current;
  final String Function(String key, Object? value)? describe;
  static const labels = <String, String>{
    'clientId': '客户',
    'warehouseId': '出货仓库',
    'currencyId': '币种',
    'taxRate': '税率',
    'settlementMethodId': '结账方式',
    'billDate': '单据日期',
    'billingMode': '是否收费',
    'purpose': '发货用途',
    'freeReason': '不收费原因',
    'shipAddr': '收货地址',
    'linkPhone': '联系电话',
    'remark': '备注',
    'sellerId': '销售员',
    'senderId': '发货人',
    'parcelCount': '件数',
    'logisticsNo': '物流单号',
    'goodsId': '货品',
    'colorId': '颜色',
    'unitId': '单位',
    'unitRate': '单位换算',
    'qty': '数量',
    'price': '单价',
    'discount': '折扣',
    'amountOriginal': '货款金额',
    'weight': '重量',
    'parcelQty': '包装数',
    'cartonCount': '箱数',
    'clientNo': '客户单号',
    'clientModel': '客户型号',
    'materialPrice': '材料价',
    'dieCastPrice': '压铸价',
    'machiningPrice': '机加价',
    'circumference': '围数',
  };
  String value(String key, Object? value) {
    if (value == null || value == '') return '未填写';
    if (key == 'billingMode') return value == 'FREE' ? '不收费' : '收费';
    if (key == 'purpose') {
      return switch (value) {
        'SAMPLE' => '样品',
        'GIFT' => '赠送',
        _ => '其它客户发货',
      };
    }
    return describe?.call(key, value) ?? value.toString();
  }

  @override
  Widget build(BuildContext context) {
    if (current == null || current!.isEmpty) return const SizedBox.shrink();
    final hasPrevious = previous != null && previous!.isNotEmpty;
    Map<String, dynamic> old, now;
    try {
      old = hasPrevious ? jsonDecode(previous!) as Map<String, dynamic> : {};
      now = jsonDecode(current!) as Map<String, dynamic>;
    } on Object {
      return const Text('以前的审核内容暂时无法展示，请刷新并核对后再决定。');
    }
    final changes = <({String label, String before, String after})>[];
    void compare(
      Map<String, dynamic> before,
      Map<String, dynamic> after,
      String prefix,
    ) {
      for (final key in {...before.keys, ...after.keys}) {
        if (!labels.containsKey(key) || before[key] == after[key]) continue;
        changes.add((
          label: '$prefix${labels[key]}',
          before: value(key, before[key]),
          after: value(key, after[key]),
        ));
      }
    }

    if (hasPrevious) {
      compare(
        Map<String, dynamic>.from(old['header'] as Map? ?? {}),
        Map<String, dynamic>.from(now['header'] as Map? ?? {}),
        '',
      );
    }
    Map<String, Map<String, dynamic>> items(Object? rows) => {
      for (final item
          in (rows as List? ?? []).whereType<Map<String, dynamic>>())
        if (item['id'] is String)
          item['id'] as String: Map<String, dynamic>.from(item),
    };
    final oldItems = items(old['items']), newItems = items(now['items']);
    for (final id in {...oldItems.keys, ...newItems.keys}) {
      final before = oldItems[id], after = newItems[id];
      final line = after?['lineNo'] ?? before?['lineNo'] ?? '—';
      if (hasPrevious && (before == null || after == null)) {
        changes.add((
          label: '第 $line 行明细',
          before: before == null ? '无此行' : '原有明细',
          after: after == null ? '已移除' : '新增明细',
        ));
      }
      final currentFields = hasPrevious
          ? after ?? {}
          : {
              for (final key in [
                'goodsId',
                'colorId',
                'unitId',
                'qty',
                'price',
                'discount',
                'amountOriginal',
              ])
                if (after?[key] != null) key: after![key],
            };
      compare(before ?? {}, currentFields, '第 $line 行 · ');
    }
    if (changes.isEmpty) return const Text('与上次审核相比，发货内容没有变化。');
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          hasPrevious ? '本次修改，请逐项核对' : '当前发货明细，请核对',
          style: Theme.of(context).textTheme.titleSmall,
        ),
        for (final change in changes)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(change.label),
                if (hasPrevious) SelectableText('以前：${change.before}'),
                SelectableText(
                  '${hasPrevious ? '本次：' : ''}${change.after}',
                  style: TextStyle(
                    color: Theme.of(context).colorScheme.primary,
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }
}
