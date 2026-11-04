import '../../finance/config/finance_requirement_names.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../components/print/uten_print_preview.dart';
import '../../../core/network/api_client.dart';
import '../../../core/performance/ui_work_budget.dart';
import '../../../shared/formatters/money_display.dart';
import '../../../shared/print/procurement_order_print_document.dart'
    show procurementOrderRmbCapital;
import '../../../shared/providers/export_context_epoch_provider.dart';

/// Loads the complete authorized shipment; final paper authorization rechecks that same digest.
Future<void> showSalesShipmentPrint(
  BuildContext context,
  WidgetRef ref,
  String id,
) async {
  final api = ref.read(apiClientProvider),
      epoch = ref.read(exportContextEpochProvider);
  bool current() =>
      context.mounted &&
      epoch == ref.read(exportContextEpochProvider) &&
      identical(api, ref.read(apiClientProvider));
  final data = await api.get('/sales/shipments/$id/print-data');
  if (!current()) return;
  final table = buildSalesShipmentPrintTable(data);
  if (!context.mounted || !current()) return;
  await showUtenPrintPreview(
    context: context,
    title:
        '${data['companyName'] ?? ''}\n${data['title']?.toString() ?? FinanceRequirementNames.customerShipmentReview}',
    subtitle:
        '表单编号：${data['formCode']}　开单日期：${data['billDate']}\n客户名称：${data['clientName']}　单号：${data['billNo']}　电话：${data['phone']}\n送货地址：${data['shipAddr']}　币种：${data['currencyName']}\n结账方式：${data['settlementName']}　审核时间：${data['financeAuditedAt']}',
    applyTableProjection: false,
    loader: () async {
      if (!current()) throw const UiWorkCancelled();
      return table;
    },
    authorizePrint: () async {
      if (!current()) throw const UiWorkCancelled();
      await api.post(
        '/sales/shipments/$id/print-authorization',
        body: {'contentDigest': data['contentDigest']},
      );
      if (!current()) throw const UiWorkCancelled();
    },
  );
}

UtenPrintTable buildSalesShipmentPrintTable(Map<String, dynamic> data) {
  if (data['lines'] is! List ||
      (data['lines'] as List).any((row) => row is! Map)) {
    throw const FormatException('发货清单明细未完整读取，请重新预览');
  }
  final lines = [
    for (final row in data['lines'] as List? ?? const [])
      if (row is Map) Map<String, dynamic>.from(row),
  ];
  final masked = data['priceMasked'] == true;
  final headers = [
    for (final h in data['headers'] as List? ?? const []) h.toString(),
  ];
  if (headers.length != 12) throw const FormatException('原发货清单应为12列，请核对当前表样');
  if (lines.isEmpty ||
      lines.map((row) => row['id']).toSet().length != lines.length ||
      lines.any((row) => row['id'] == null)) {
    throw const FormatException('发货清单明细为空、重复或缺少来源编号');
  }
  if (data['signatures'] is! List || (data['signatures'] as List).length != 5) {
    throw const FormatException('原发货清单签名区未完整读取');
  }
  return UtenPrintTable(
    headers: headers,
    pageHeader:
        '${data['companyName'] ?? ''}　${data['title'] ?? ''}　单号：${data['billNo']}',
    pageFooter:
        '总成交金额大写：${masked
            ? '***'
            : data['currencyName']?.toString().contains('人民币') == true
            ? procurementOrderRmbCapital(data['totalOriginal']?.toString())
            : '—'}　总成交金额小写：${masked ? '***' : financeMoneyWithUnitSuffix(data['totalOriginal']?.toString(), currencyName: data['currencyName']?.toString())}\n${[for (final signature in data['signatures'] as List) '${(signature as Map)['label']}：${signature['name'] ?? ''}'].join('　')}',
    columnWidths: const [28, 65, 72, 32, 130, 42, 30, 46, 50, 30, 60, 90],
    columnKeys: const [
      'lineNo',
      'goodsCode',
      'model',
      'series',
      'goodsName',
      'color',
      'unit',
      'qty',
      'price',
      'discount',
      'amount',
      'remark',
    ],
    rows: [
      for (final row in lines)
        [
          row['lineNo'].toString(),
          row['goodsCode']?.toString() ?? '',
          row['model']?.toString() ?? '',
          row['series']?.toString() ?? '',
          row['goodsName']?.toString() ?? '',
          row['color']?.toString() ?? '',
          row['unit']?.toString() ?? '',
          row['qty']?.toString() ?? '—',
          masked ? '***' : financeMoneyText(row['price']?.toString()),
          masked ? '***' : (row['discount']?.toString() ?? '—'),
          masked ? '***' : financeMoneyText(row['amount']?.toString()),
          row['remark']?.toString() ?? '',
        ],
      [
        '',
        '合计',
        '',
        '',
        '',
        '',
        '',
        data['quantityTotal']?.toString() ?? '—',
        '',
        '',
        masked ? '***' : financeMoneyText(data['totalOriginal']?.toString()),
        '',
      ],
    ],
  );
}
