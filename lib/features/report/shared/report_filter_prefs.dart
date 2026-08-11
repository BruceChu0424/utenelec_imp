// 报表筛选偏好（按账号服务端持久化）：单据类型 + 日期范围 + facet 筛选 + 列排序。
//
// 报表页（仓库/采购/销售，明细/汇总各一页）共用同一状态形状，本文件提供：
//   ReportFilterPrefs         —— 状态对象（全 null = 未存过，页面回落各自默认）
//   ReportFilterPrefsNotifier —— 抽象 Notifier（序列化已就绪，子类只给 prefKey）
// 以及 6 个已实现的具体 provider（三模块 × 明细/汇总）。
//
// 持久化机制：UtenPagePrefsNotifier 基类（lib/shared/providers/uten_page_prefs_notifier.dart），
// 三层策略（本地缓存即时渲染 → 登录后服务端同步 → 防抖 800ms 推送）继承即得。
//
// 页面接入约定（三个报表页一致）：
// 1. initState 里先按页面默认初始化，再读 provider：有内容则覆盖本地字段后 _load()；
// 2. 任何筛选变更（切单据类型/改日期/改 facet/改排序）→ notifier.update(当前快照)；
// 3. ref.listen 服务端同步晚到：仅当用户尚未动手（_dirty=false）才应用，避免覆盖在输状态。
// 4. 关键字（keyword）不持久化——搜索是临时动作，记住口径=类型+日期+facet+排序。
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../shared/providers/uten_page_prefs_notifier.dart';

/// 报表筛选状态快照（不可变）。全字段 null/空 = 未存过。
class ReportFilterPrefs {
  const ReportFilterPrefs({
    this.docType,
    this.status,
    this.from,
    this.to,
    this.filters = const {},
    this.sortKey,
    this.sortAsc = true,
    this.extra = const {},
  });

  /// 单据类型 code（各模块枚举 .code，如 TRANSFER/ORDER；钱流报表卡=变体下标字符串）。
  final String? docType;

  /// 单据状态过滤（生产报表用：null=全部 / 0=草稿 / 1=已审 / -1=红冲）。
  final int? status;

  /// 日期起/止（yyyy-MM-dd）。
  final String? from;
  final String? to;

  /// facet 筛选（key → value；kMasterFilterNullValue 表「(空)」原样存）。
  final Map<String, String> filters;

  /// 列排序（null=后端默认）。
  final String? sortKey;
  final bool sortAsc;

  /// 页面特有扩展位（钱流特殊页：类别/往来单位/账户/年度/视图等）。
  /// 值只允许 String/num/bool（encode/decode 原样透传，其他类型丢弃）。
  final Map<String, Object?> extra;

  /// 是否「未存过」（页面据此决定用默认还是应用快照）。
  bool get isEmpty =>
      docType == null &&
      status == null &&
      from == null &&
      to == null &&
      filters.isEmpty &&
      sortKey == null &&
      extra.isEmpty;

  ReportFilterPrefs copyWith({
    String? docType,
    int? status,
    String? from,
    String? to,
    Map<String, String>? filters,
    String? sortKey,
    bool? sortAsc,
    Map<String, Object?>? extra,
  }) => ReportFilterPrefs(
    docType: docType ?? this.docType,
    status: status ?? this.status,
    from: from ?? this.from,
    to: to ?? this.to,
    filters: filters ?? this.filters,
    sortKey: sortKey ?? this.sortKey,
    sortAsc: sortAsc ?? this.sortAsc,
    extra: extra ?? this.extra,
  );
}

/// 抽象基类：序列化已实现，子类只声明 prefKey。
abstract class ReportFilterPrefsNotifier
    extends UtenPagePrefsNotifier<ReportFilterPrefs> {
  @override
  ReportFilterPrefs get defaultValue => const ReportFilterPrefs();

  @override
  ReportFilterPrefs? decode(Object? raw) {
    Map<dynamic, dynamic>? map;
    if (raw is Map<dynamic, dynamic>) {
      map = raw;
    } else if (raw is String && raw.isNotEmpty) {
      try {
        final decoded = jsonDecode(raw);
        if (decoded is Map<dynamic, dynamic>) map = decoded;
      } catch (_) {
        return null;
      }
    }
    if (map == null) return null;
    final filters = <String, String>{};
    final rawFilters = map['filters'];
    if (rawFilters is Map) {
      for (final e in rawFilters.entries) {
        if (e.key != null && e.value != null) {
          filters[e.key.toString()] = e.value.toString();
        }
      }
    }
    final extra = <String, Object?>{};
    final rawExtra = map['extra'];
    if (rawExtra is Map) {
      for (final e in rawExtra.entries) {
        // 只透传简单标量，其他类型（嵌套 Map/List）丢弃防脏数据
        if (e.key != null &&
            (e.value is String || e.value is num || e.value is bool)) {
          extra[e.key.toString()] = e.value;
        }
      }
    }
    return ReportFilterPrefs(
      docType: map['docType']?.toString(),
      status: map['status'] is num ? (map['status'] as num).toInt() : null,
      from: map['from']?.toString(),
      to: map['to']?.toString(),
      filters: filters,
      sortKey: map['sortKey']?.toString(),
      sortAsc: map['sortAsc'] is bool ? map['sortAsc'] as bool : true,
      extra: extra,
    );
  }

  @override
  Object? encode(ReportFilterPrefs state) => {
    if (state.docType != null) 'docType': state.docType,
    if (state.status != null) 'status': state.status,
    if (state.from != null) 'from': state.from,
    if (state.to != null) 'to': state.to,
    if (state.filters.isNotEmpty) 'filters': state.filters,
    if (state.sortKey != null) 'sortKey': state.sortKey,
    'sortAsc': state.sortAsc,
    if (state.extra.isNotEmpty) 'extra': state.extra,
  };
}

// ================== 12 个具体 provider（五模块：仓库/采购/销售/委外/生产） ==================

class WarehouseDetailReportPrefsNotifier extends ReportFilterPrefsNotifier {
  @override
  String get prefKey => 'report.warehouse.detail';
}

class WarehouseSummaryReportPrefsNotifier extends ReportFilterPrefsNotifier {
  @override
  String get prefKey => 'report.warehouse.summary';
}

class PurchaseDetailReportPrefsNotifier extends ReportFilterPrefsNotifier {
  @override
  String get prefKey => 'report.purchase.detail';
}

class PurchaseSummaryReportPrefsNotifier extends ReportFilterPrefsNotifier {
  @override
  String get prefKey => 'report.purchase.summary';
}

class PurchaseExpeditingReportPrefsNotifier extends ReportFilterPrefsNotifier {
  @override
  String get prefKey => 'report.purchase.expediting';
}

class SalesDetailReportPrefsNotifier extends ReportFilterPrefsNotifier {
  @override
  String get prefKey => 'report.sales.detail';
}

class SalesSummaryReportPrefsNotifier extends ReportFilterPrefsNotifier {
  @override
  String get prefKey => 'report.sales.summary';
}

class SubcontractDetailReportPrefsNotifier extends ReportFilterPrefsNotifier {
  @override
  String get prefKey => 'report.subcontract.detail';
}

class SubcontractSummaryReportPrefsNotifier extends ReportFilterPrefsNotifier {
  @override
  String get prefKey => 'report.subcontract.summary';
}

class SubcontractInOutStatusReportPrefsNotifier
    extends ReportFilterPrefsNotifier {
  @override
  String get prefKey => 'report.subcontract.inOutStatus';
}

class ProductionDetailReportPrefsNotifier extends ReportFilterPrefsNotifier {
  @override
  String get prefKey => 'report.production.detail';
}

class ProductionSummaryReportPrefsNotifier extends ReportFilterPrefsNotifier {
  @override
  String get prefKey => 'report.production.summary';
}

class FinanceDetailReportPrefsNotifier extends ReportFilterPrefsNotifier {
  @override
  String get prefKey => 'report.finance.detail';
}

class FinanceSummaryReportPrefsNotifier extends ReportFilterPrefsNotifier {
  @override
  String get prefKey => 'report.finance.summary';
}

class FinanceArApOverviewReportPrefsNotifier extends ReportFilterPrefsNotifier {
  @override
  String get prefKey => 'report.finance.arApOverview';
}

class FinanceStatementReportPrefsNotifier extends ReportFilterPrefsNotifier {
  @override
  String get prefKey => 'report.finance.statement';
}

class FinanceAccountFlowReportPrefsNotifier extends ReportFilterPrefsNotifier {
  @override
  String get prefKey => 'report.finance.accountFlow';
}

final warehouseDetailReportPrefsProvider =
    NotifierProvider<WarehouseDetailReportPrefsNotifier, ReportFilterPrefs>(
      WarehouseDetailReportPrefsNotifier.new,
    );
final warehouseSummaryReportPrefsProvider =
    NotifierProvider<WarehouseSummaryReportPrefsNotifier, ReportFilterPrefs>(
      WarehouseSummaryReportPrefsNotifier.new,
    );
final purchaseDetailReportPrefsProvider =
    NotifierProvider<PurchaseDetailReportPrefsNotifier, ReportFilterPrefs>(
      PurchaseDetailReportPrefsNotifier.new,
    );
final purchaseSummaryReportPrefsProvider =
    NotifierProvider<PurchaseSummaryReportPrefsNotifier, ReportFilterPrefs>(
      PurchaseSummaryReportPrefsNotifier.new,
    );
final purchaseExpeditingReportPrefsProvider =
    NotifierProvider<PurchaseExpeditingReportPrefsNotifier, ReportFilterPrefs>(
      PurchaseExpeditingReportPrefsNotifier.new,
    );
final salesDetailReportPrefsProvider =
    NotifierProvider<SalesDetailReportPrefsNotifier, ReportFilterPrefs>(
      SalesDetailReportPrefsNotifier.new,
    );
final salesSummaryReportPrefsProvider =
    NotifierProvider<SalesSummaryReportPrefsNotifier, ReportFilterPrefs>(
      SalesSummaryReportPrefsNotifier.new,
    );
final subcontractDetailReportPrefsProvider =
    NotifierProvider<SubcontractDetailReportPrefsNotifier, ReportFilterPrefs>(
      SubcontractDetailReportPrefsNotifier.new,
    );
final subcontractSummaryReportPrefsProvider =
    NotifierProvider<SubcontractSummaryReportPrefsNotifier, ReportFilterPrefs>(
      SubcontractSummaryReportPrefsNotifier.new,
    );
final subcontractInOutStatusReportPrefsProvider =
    NotifierProvider<
      SubcontractInOutStatusReportPrefsNotifier,
      ReportFilterPrefs
    >(SubcontractInOutStatusReportPrefsNotifier.new);
final productionDetailReportPrefsProvider =
    NotifierProvider<ProductionDetailReportPrefsNotifier, ReportFilterPrefs>(
      ProductionDetailReportPrefsNotifier.new,
    );
final productionSummaryReportPrefsProvider =
    NotifierProvider<ProductionSummaryReportPrefsNotifier, ReportFilterPrefs>(
      ProductionSummaryReportPrefsNotifier.new,
    );
final financeDetailReportPrefsProvider =
    NotifierProvider<FinanceDetailReportPrefsNotifier, ReportFilterPrefs>(
      FinanceDetailReportPrefsNotifier.new,
    );
final financeSummaryReportPrefsProvider =
    NotifierProvider<FinanceSummaryReportPrefsNotifier, ReportFilterPrefs>(
      FinanceSummaryReportPrefsNotifier.new,
    );
final financeArApOverviewReportPrefsProvider =
    NotifierProvider<FinanceArApOverviewReportPrefsNotifier, ReportFilterPrefs>(
      FinanceArApOverviewReportPrefsNotifier.new,
    );
final financeStatementReportPrefsProvider =
    NotifierProvider<FinanceStatementReportPrefsNotifier, ReportFilterPrefs>(
      FinanceStatementReportPrefsNotifier.new,
    );
final financeAccountFlowReportPrefsProvider =
    NotifierProvider<FinanceAccountFlowReportPrefsNotifier, ReportFilterPrefs>(
      FinanceAccountFlowReportPrefsNotifier.new,
    );
