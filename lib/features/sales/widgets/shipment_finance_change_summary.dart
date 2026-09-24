import 'dart:convert';

import 'package:flutter/material.dart';

import '../../../components/data_display/uten_revision_table.dart';
import '../../../shared/formatters/exact_decimal.dart';
import '../../basic_data/widgets/master_data_table_view.dart';

Map<String, dynamic>? _snapshot(String? text) {
  if (text == null || text.isEmpty) return null;
  try {
    final value = jsonDecode(text);
    if (value is! Map<String, dynamic> ||
        value['header'] is! Map<String, dynamic> ||
        value['items'] is! List) {
      return null;
    }
    final identities = <String>{};
    for (final row in value['items'] as List) {
      if (row is! Map<String, dynamic> ||
          row['id'] is! String ||
          (row['id'] as String).isEmpty ||
          !identities.add(row['id'] as String)) {
        return null;
      }
    }
    return value;
  } on Object {
    return null;
  }
}

bool readableShipmentReviewSnapshot(String? value) => _snapshot(value) != null;

/// Removed item names must also be loaded. Values and identity always come from
/// the immutable review snapshot, never from current document rows.
Set<String> shipmentReviewSnapshotIds(String? snapshot, String key) {
  final value = _snapshot(snapshot);
  if (value == null) return const {};
  return {
    if ((value['header'] as Map)[key] case final String id) id,
    for (final row in value['items'] as List)
      if ((row as Map)[key] case final String id) id,
  };
}

const _labels = <String, String>{
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
  'lineNo': '行号',
  'goodsId': '货品名称',
  'goodsCode': '编号',
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
  'orderItemId': '来源订单行',
};

const _numericFields = {
  'taxRate',
  'parcelCount',
  'lineNo',
  'unitRate',
  'qty',
  'price',
  'discount',
  'amountOriginal',
  'weight',
  'parcelQty',
  'cartonCount',
  'materialPrice',
  'dieCastPrice',
  'machiningPrice',
  'circumference',
};

Object? _comparisonValue(String key, Object? value) =>
    _numericFields.contains(key)
    ? financeExactTrimmed(value?.toString())
    : value;

String _display(
  String key,
  Object? value,
  String Function(String, Object?)? describe,
) {
  if (value == null || value == '') return '—';
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

/// Stable UUIDs prevent duplicate goods from being merged. Decimal text remains
/// intact rather than passing through binary floating point.
List<UtenRevisionRow<Map<String, dynamic>>> shipmentFinanceRevisionRows(
  String previous,
  String current,
) {
  final old = _snapshot(previous);
  final now = _snapshot(current);
  if (old == null || now == null) return const [];
  final remaining = {
    for (final row in (now['items'] as List).cast<Map<String, dynamic>>())
      row['id'] as String: row,
  };
  final rows = <UtenRevisionRow<Map<String, dynamic>>>[];
  for (final before in (old['items'] as List).cast<Map<String, dynamic>>()) {
    final after = remaining.remove(before['id']);
    final changed =
        after == null ||
        {...before.keys, ...after.keys}
            .where((key) => key != 'lineNo')
            .any(
              (key) =>
                  _comparisonValue(key, before[key]) !=
                  _comparisonValue(key, after[key]),
            );
    rows.add(
      UtenRevisionRow(
        value: changed ? before : after,
        kind: changed ? UtenRevisionKind.removed : UtenRevisionKind.unchanged,
        label: after == null
            ? '已删除'
            : changed
            ? '原内容'
            : null,
      ),
    );
    if (changed && after != null) {
      rows.add(
        UtenRevisionRow(
          value: after,
          kind: UtenRevisionKind.added,
          label: '修改后',
          changedKeys: {
            for (final key in {...before.keys, ...after.keys})
              if (key != 'lineNo' &&
                  _comparisonValue(key, before[key]) !=
                      _comparisonValue(key, after[key]))
                switch (key) {
                  'goodsNameSnapshot' => 'goodsId',
                  'goodsCodeSnapshot' => 'goodsCode',
                  _ => key,
                },
            if (before['goodsId'] != after['goodsId']) 'goodsCode',
          },
        ),
      );
    }
  }
  rows.addAll(
    remaining.values.map(
      (row) => UtenRevisionRow(
        value: row,
        kind: UtenRevisionKind.added,
        label: '新增',
      ),
    ),
  );
  return rows;
}

/// Only header changes belong above the table; product changes are full rows.
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

  @override
  Widget build(BuildContext context) {
    if (previous == null || previous!.isEmpty) return const SizedBox.shrink();
    final old = _snapshot(previous);
    final now = _snapshot(current);
    if (old == null || now == null) {
      return const Text('以前的审核内容暂时无法展示，请刷新并核对后再决定。');
    }
    final before = old['header'] as Map<String, dynamic>;
    final after = now['header'] as Map<String, dynamic>;
    final fields = <UtenRevisionField>[
      for (final key in {...before.keys, ...after.keys})
        if (_labels.containsKey(key) &&
            _comparisonValue(key, before[key]) !=
                _comparisonValue(key, after[key]))
          UtenRevisionField(
            label: _labels[key]!,
            before: _display(key, before[key], describe),
            after: _display(key, after[key], describe),
          ),
    ];
    if (fields.isEmpty) return const SizedBox.shrink();
    return UtenRevisionFields(changes: fields);
  }
}

class ShipmentFinanceChangeTable extends StatelessWidget {
  const ShipmentFinanceChangeTable({
    super.key,
    required this.previous,
    required this.current,
    this.describe,
    this.embedded = true,
    this.primary = false,
    this.bottomContentPadding = 0,
    this.priceMasked = false,
  });

  final String previous;
  final String current;
  final String Function(String key, Object? value)? describe;
  final bool embedded;
  final bool primary;
  final double bottomContentPadding;
  final bool priceMasked;

  static const _moneyKeys = {
    'price',
    'amountOriginal',
    'materialPrice',
    'dieCastPrice',
    'machiningPrice',
  };

  @override
  Widget build(BuildContext context) {
    final rows = shipmentFinanceRevisionRows(previous, current);
    final changedSources = <String, Object?>{};
    final changedFields = <String>{};
    for (var index = 0; index + 1 < rows.length; index++) {
      final before = rows[index];
      final after = rows[index + 1];
      if (before.kind == UtenRevisionKind.removed &&
          after.kind == UtenRevisionKind.added &&
          before.value['id'] == after.value['id']) {
        changedFields.addAll(
          {...before.value.keys, ...after.value.keys}.where(
            (key) =>
                _labels.containsKey(key) &&
                key != 'lineNo' &&
                _comparisonValue(key, before.value[key]) !=
                    _comparisonValue(key, after.value[key]),
          ),
        );
      }
      if (before.kind == UtenRevisionKind.removed &&
          after.kind == UtenRevisionKind.added &&
          before.value['id'] == after.value['id'] &&
          before.value['orderItemId'] != after.value['orderItemId']) {
        changedSources[before.value['id'] as String] =
            before.value['orderItemId'];
      }
    }
    final keys = <String>{
      'lineNo',
      'goodsId',
      'goodsCode',
      'colorId',
      'unitId',
      'qty',
      'price',
      'discount',
      'amountOriginal',
      if (changedSources.isNotEmpty) 'orderItemId',
      ...changedFields,
      for (final row in rows)
        for (final entry in row.value.entries)
          if (_labels.containsKey(entry.key) &&
              entry.value != null &&
              entry.value != '' &&
              entry.key != 'orderItemId' &&
              (entry.key != 'unitRate' || entry.value.toString() != '1') &&
              !RegExp(r'^0(?:\.0+)?$').hasMatch(entry.value.toString()))
            entry.key,
    };
    return UtenRevisionTable<Map<String, dynamic>>(
      embedded: embedded,
      primary: primary,
      bottomContentPadding: bottomContentPadding,
      rows: rows,
      summaryBar: rows.any((row) => row.value['goodsNameSnapshot'] == null)
          ? const Text('货品名称与编号按当前档案显示；数量、金额保留当时提交内容。')
          : null,
      columns: [
        for (final key in keys)
          MasterColumnDef<Map<String, dynamic>>(
            key: key,
            label: _labels[key]!,
            width: switch (key) {
              'goodsId' => 200,
              'remark' || 'clientModel' || 'orderItemId' => 180,
              'lineNo' => 70,
              _ => 110,
            },
            type: _moneyKeys.contains(key) ? 'money' : 'text',
            value: (row) => priceMasked && _moneyKeys.contains(key)
                ? '***'
                : key == 'goodsId' && row['goodsNameSnapshot'] != null
                ? row['goodsNameSnapshot'].toString()
                : key == 'goodsCode'
                ? row['goodsCodeSnapshot']?.toString() ??
                      (describe?.call('goodsCode', row['goodsId']) ?? '—')
                : key == 'orderItemId' && changedSources.containsKey(row['id'])
                ? row['orderItemId'] == changedSources[row['id']]
                      ? '原来源订单'
                      : row['orderItemId'] == null
                      ? '已取消来源订单'
                      : '来源订单已更换'
                : _display(key, row[key], describe),
          ),
      ],
    );
  }
}
