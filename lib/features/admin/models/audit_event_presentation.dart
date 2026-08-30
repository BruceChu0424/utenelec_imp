import 'audit_field_labels.dart';

/// 审计事件在普通核查界面的中文叙事规则。
///
/// 后端仍是动作、对象和可读业务编号的权威来源；这里仅对必须稳定表达的
/// 跨端事件做展示兜底，并阻止 UUID、HTTP 路径进入主时间线。
abstract final class AuditEventPresentation {
  static const Map<String, String> _salesDetailObjects = {
    'view_sales_quote_detail': '销售报价详情',
    'view_sales_order_detail': '销售订单详情',
    'view_sales_shipment_detail': '销售出货详情',
    'view_sales_other_shipment_detail': '销售其他出库详情',
    'view_sales_return_detail': '销售退货详情',
  };

  static const Map<String, String> _salesHistoryObjects = {
    'view_sales_quote_detail_history': '销售报价历史单据',
    'view_sales_order_detail_history': '销售订单历史单据',
    'view_sales_shipment_detail_history': '销售出货历史单据',
    'view_sales_other_shipment_detail_history': '销售其他出库历史单据',
    'view_sales_return_detail_history': '销售退货历史单据',
  };

  static String? salesViewObjectLabel(String action) {
    final normalized = action.trim().toLowerCase();
    return _salesHistoryObjects[normalized] ?? _salesDetailObjects[normalized];
  }

  static bool isSalesView(String action) =>
      salesViewObjectLabel(action) != null;

  /// “查看销售订单历史单据”，适合“做了什么”字段。
  static String? salesViewActionLabel(String action) {
    final object = salesViewObjectLabel(action);
    return object == null ? null : '查看$object';
  }

  /// “查看了销售订单历史单据：SO-2026-001”，适合时间线主标题。
  static String? salesViewNarrative({
    required String action,
    String? targetName,
  }) {
    final object = salesViewObjectLabel(action);
    if (object == null) return null;
    final name = safeBusinessReference(targetName);
    return name == null ? '查看了$object(单号未记录)' : '查看了$object：$name';
  }

  /// “销售订单历史单据 · SO-2026-001”，适合详情里的操作对象。
  static String? salesViewObjectText({
    required String action,
    String? targetName,
  }) {
    final object = salesViewObjectLabel(action);
    if (object == null) return null;
    final name = safeBusinessReference(targetName);
    return '$object · ${name ?? '单号未记录'}';
  }

  /// 主时间线上的操作人。姓名和账号均存在时保留二者；从不拿 actorId 兜底。
  static String actorLabel({
    String? actorDisplay,
    String? actorName,
    String? actorAccount,
  }) {
    final display = _clean(actorDisplay);
    if (display != null) return display;
    final name = _clean(actorName);
    final account = _clean(actorAccount);
    if (name != null && account != null) return '$name($account)';
    if (name != null) return name;
    if (account != null) return '账号 $account';
    return '未知操作人';
  }

  /// 允许单据号、名称和后端 history_label；拒绝技术 UUID、URL/API 路径和未知占位。
  static String? safeBusinessReference(String? value) {
    final text = _clean(value);
    if (text == null) return null;
    final normalized = text.toLowerCase();
    if (const {
      '未知',
      '未知单据',
      'unknown',
      'null',
      'n/a',
      '-',
      '—',
    }.contains(normalized)) {
      return null;
    }
    if (AuditFieldLabels.looksLikeUuid(text) ||
        text.startsWith('/') ||
        normalized.startsWith('api/') ||
        normalized.contains('://')) {
      return null;
    }
    return text;
  }

  static String? _clean(String? value) {
    final text = value?.trim();
    return text == null || text.isEmpty ? null : text;
  }
}
