// 销售订货单财务确认任务模型（V294 闸门）。
//
// 后端 SalesOrderFinanceConfirmService 返回的待确认列表行：已审核但未财务确认的
// 销售订货单。确认后订单才对计划部可见（物料分析/待排产/MRP/计划关联）。

class SalesOrderFinancePendingItem {
  const SalesOrderFinancePendingItem({
    required this.orderId,
    required this.billNo,
    this.billDate,
    this.clientName,
    this.sellerName,
    this.deliverDate,
    this.itemCount = 0,
    this.totalOriginal,
    this.currencyCode,
  });

  final String orderId;
  final String billNo;
  final String? billDate;
  final String? clientName;
  final String? sellerName;
  final String? deliverDate;
  final int itemCount;

  /// 金额保留服务端字符串，避免大额或小数在客户端转换时丢精度。
  final String? totalOriginal;
  final String? currencyCode;

  bool get canConfirm => orderId.isNotEmpty;

  String get detailRoute =>
      '/sales/orders/${Uri.encodeComponent(orderId)}';

  factory SalesOrderFinancePendingItem.fromJson(Map<String, dynamic> json) {
    return SalesOrderFinancePendingItem(
      orderId: _string(json['orderId']) ?? '',
      billNo: _string(json['billNo']) ?? '未生成单号',
      billDate: _string(json['billDate']),
      clientName: _string(json['clientName']),
      sellerName: _string(json['sellerName']),
      deliverDate: _string(json['deliverDate']),
      itemCount: _int(json['itemCount']) ?? 0,
      totalOriginal: _string(json['totalOriginal']),
      currencyCode: _string(json['currencyCode']),
    );
  }
}

class SalesOrderFinancePendingPage {
  const SalesOrderFinancePendingPage({
    required this.items,
    required this.page,
    required this.size,
    required this.total,
    required this.totalPages,
  });

  final List<SalesOrderFinancePendingItem> items;
  final int page;
  final int size;
  final int total;
  final int totalPages;

  factory SalesOrderFinancePendingPage.fromJson(Map<String, dynamic> json) {
    final nested = json['data'];
    final root = nested is Map<String, dynamic>
        ? nested
        : nested is Map
            ? nested.cast<String, dynamic>()
            : json;
    final rawItems = root['items'];
    final items = rawItems is List
        ? rawItems
            .whereType<Map<Object?, Object?>>()
            .map(
              (item) => SalesOrderFinancePendingItem.fromJson(
                item.cast<String, dynamic>(),
              ),
            )
            .toList(growable: false)
        : const <SalesOrderFinancePendingItem>[];
    final page = _int(root['page']) ?? 1;
    final size = _int(root['size']) ?? items.length;
    final total = _int(root['total']) ?? items.length;
    final totalPages = _int(root['totalPages']) ??
        (size <= 0 ? 1 : ((total + size - 1) ~/ size).clamp(1, 1 << 30));
    return SalesOrderFinancePendingPage(
      items: items,
      page: page < 1 ? 1 : page,
      size: size,
      total: total < 0 ? 0 : total,
      totalPages: totalPages < 1 ? 1 : totalPages,
    );
  }
}

String? _string(Object? value) {
  if (value == null) return null;
  final result = value.toString().trim();
  return result.isEmpty ? null : result;
}

int? _int(Object? value) {
  if (value is num) return value.toInt();
  return int.tryParse(value?.toString() ?? '');
}
