// 收付款类别模型（对应后端 PaymentStyleNode / PaymentStyleDetail）。
//
// 邻接 + 物化路径树（path 触发器维护），category 区分大类：
// ACCOUNT/LIABILITY/EQUITY/EXPENSE/INCOME/METHOD（必填，新建后不可改）。
// 收/付款类别用于钱流单据（费用/收入分摊项目、收/付款方式等），direction flags：
// receipt/payment/departmental。linkedAccountLegacyId 关联账户老 id（仅展示）。
//
// 实现 UtenTreeNode<PaymentStyleNode>：复用 UtenCategoryTreeView<PaymentStyleNode>
// 统一分类树外观（与货品资料左树一致），无需各自手搓递归树。

import 'uten_tree_node.dart';

/// 收付款类别大类（与后端 PaymentStyleCategory 对齐）。
enum PaymentStyleCategory {
  account('ACCOUNT', '账户'),
  liability('LIABILITY', '负债'),
  equity('EQUITY', '权益'),
  expense('EXPENSE', '费用'),
  income('INCOME', '收入'),
  method('METHOD', '结算方式');

  const PaymentStyleCategory(this.value, this.label);
  final String value;
  final String label;

  static PaymentStyleCategory? byValue(String? v) {
    if (v == null) return null;
    for (final c in PaymentStyleCategory.values) {
      if (c.value == v) return c;
    }
    return null;
  }

  static String labelOf(String? v) {
    final c = byValue(v);
    return c?.label ?? (v ?? '');
  }
}

/// 收付款类别树节点（递归 children）。
class PaymentStyleNode implements UtenTreeNode<PaymentStyleNode> {
  PaymentStyleNode({
    required this.id,
    required this.code,
    required this.name,
    required this.children,
    this.category,
    this.level,
    this.parentId,
    this.sortOrder,
    this.path,
    this.departmental = false,
    this.receipt = false,
    this.payment = false,
    this.linkedAccountLegacyId,
    this.initBalance,
    this.status,
    this.legacyId,
  });

  @override
  final String id;
  @override
  final String code;
  @override
  final String name;
  final String? category;
  final int? level;
  final String? parentId;
  final int? sortOrder;
  final String? path;
  final bool departmental;
  final bool receipt;
  final bool payment;
  final int? linkedAccountLegacyId;
  final double? initBalance;
  final String? status;
  final int? legacyId;
  @override
  final List<PaymentStyleNode> children;

  @override
  bool get hasChildren => children.isNotEmpty;

  factory PaymentStyleNode.fromJson(Map<String, dynamic> json) {
    final list = json['children'] as List<dynamic>? ?? const [];
    return PaymentStyleNode(
      id: json['id'] as String,
      code: json['code'] as String,
      name: json['name'] as String,
      category: json['category'] as String?,
      level: (json['level'] as num?)?.toInt(),
      parentId: json['parentId'] as String?,
      sortOrder: (json['sortOrder'] as num?)?.toInt(),
      path: json['path'] as String?,
      departmental: (json['departmental'] as bool?) ?? false,
      receipt: (json['receipt'] as bool?) ?? false,
      payment: (json['payment'] as bool?) ?? false,
      linkedAccountLegacyId: (json['linkedAccountLegacyId'] as num?)?.toInt(),
      initBalance: (json['initBalance'] as num?)?.toDouble(),
      status: json['status'] as String?,
      legacyId: (json['legacyId'] as num?)?.toInt(),
      children: list
          .map((e) => PaymentStyleNode.fromJson(e as Map<String, dynamic>))
          .toList(),
    );
  }
}

/// 收付款类别详情。
class PaymentStyleDetail {
  const PaymentStyleDetail({
    required this.id,
    required this.code,
    required this.name,
    required this.category,
    required this.level,
    required this.path,
    required this.childCount,
    this.parentId,
    this.parentName,
    this.sortOrder,
    this.departmental = false,
    this.receipt = false,
    this.payment = false,
    this.linkedAccountLegacyId,
    this.initBalance,
    this.status,
    this.legacyId,
  });

  final String id;
  final String code;
  final String name;
  final String category;
  final int level;
  final String? parentId;
  final String? parentName;
  final int? sortOrder;
  final String path;
  final bool departmental;
  final bool receipt;
  final bool payment;
  final int? linkedAccountLegacyId;
  final double? initBalance;
  final String? status;
  final int? legacyId;
  final int childCount;

  factory PaymentStyleDetail.fromJson(Map<String, dynamic> json) =>
      PaymentStyleDetail(
        id: json['id'] as String,
        code: json['code'] as String,
        name: json['name'] as String,
        category: json['category'] as String? ?? '',
        level: (json['level'] as num?)?.toInt() ?? 0,
        parentId: json['parentId'] as String?,
        parentName: json['parentName'] as String?,
        sortOrder: (json['sortOrder'] as num?)?.toInt(),
        departmental: (json['departmental'] as bool?) ?? false,
        receipt: (json['receipt'] as bool?) ?? false,
        payment: (json['payment'] as bool?) ?? false,
        linkedAccountLegacyId: (json['linkedAccountLegacyId'] as num?)?.toInt(),
        initBalance: (json['initBalance'] as num?)?.toDouble(),
        status: json['status'] as String?,
        legacyId: (json['legacyId'] as num?)?.toInt(),
        path: json['path'] as String? ?? '',
        childCount: (json['childCount'] as num?)?.toInt() ?? 0,
      );
}

/// 新建请求体：{code,name,category,parentId?,sortOrder?,flags...,linkedAccountLegacyId?,
/// initBalance?,status?}。
class PaymentStyleSaveInput {
  const PaymentStyleSaveInput({
    required this.code,
    required this.name,
    required this.category,
    this.parentId,
    this.sortOrder,
    this.departmental = false,
    this.receipt = false,
    this.payment = false,
    this.linkedAccountLegacyId,
    this.initBalance,
    this.status,
  });

  final String code;
  final String name;
  final String category;
  final String? parentId;
  final int? sortOrder;
  final bool departmental;
  final bool receipt;
  final bool payment;
  final int? linkedAccountLegacyId;
  final double? initBalance;
  final String? status;

  Map<String, dynamic> toJson() => {
    'code': code,
    'name': name,
    'category': category,
    if (parentId != null) 'parentId': parentId,
    if (sortOrder != null) 'sortOrder': sortOrder,
    'departmental': departmental,
    'receipt': receipt,
    'payment': payment,
    if (linkedAccountLegacyId != null)
      'linkedAccountLegacyId': linkedAccountLegacyId,
    if (initBalance != null) 'initBalance': initBalance,
    if (status != null) 'status': status,
  };
}

/// 编辑请求体：{name,parentId?,sortOrder?,flags...,linkedAccountLegacyId?,initBalance?,status?}。
/// code/category 不可改（影响 path 触发器与报表归类）。
class PaymentStyleUpdateInput {
  const PaymentStyleUpdateInput({
    required this.name,
    this.parentId,
    this.sortOrder,
    this.departmental = false,
    this.receipt = false,
    this.payment = false,
    this.linkedAccountLegacyId,
    this.initBalance,
    this.status,
  });

  final String name;
  final String? parentId;
  final int? sortOrder;
  final bool departmental;
  final bool receipt;
  final bool payment;
  final int? linkedAccountLegacyId;
  final double? initBalance;
  final String? status;

  Map<String, dynamic> toJson() => {
    'name': name,
    if (parentId != null) 'parentId': parentId,
    if (sortOrder != null) 'sortOrder': sortOrder,
    'departmental': departmental,
    'receipt': receipt,
    'payment': payment,
    if (linkedAccountLegacyId != null)
      'linkedAccountLegacyId': linkedAccountLegacyId,
    if (initBalance != null) 'initBalance': initBalance,
    if (status != null) 'status': status,
  };
}
