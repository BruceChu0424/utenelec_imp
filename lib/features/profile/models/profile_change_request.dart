// 个人信息修改申请 — 前端模型。
//
// 文档：docs/03-页面/我的页.md（设计）、docs/04-数据模型/实体字典.md（实体段）。

import 'package:uten_imp/shared/models/paged_result.dart';

/// 字段策略（驱动表单是否可改 + 是否需 HR 审核）。
enum FieldPolicyKind { directEdit, requiresReview, hrOnly }

class ProfileFieldDef {
  const ProfileFieldDef({
    required this.code,
    required this.labelKey,
    required this.kind,
    required this.group,
    this.hrOnlyLabel,
  });

  /// 机器码（与后端 ProfileFieldPolicy.Field 对齐）。
  final String code;

  /// i18n key。
  final String labelKey;

  /// 字段策略。
  final FieldPolicyKind kind;

  /// 字段分组（identity / contact / address / emergency / org / compensation）。
  final String group;

  /// 当 [kind] == [FieldPolicyKind.hrOnly] 时显示的提示文案 key。
  final String? hrOnlyLabel;
}

/// 修改申请状态。
enum ProfileChangeStatus { pending, applied, approved, rejected, cancelled }

ProfileChangeStatus _parseStatus(String? s) {
  switch (s) {
    case 'pending':
      return ProfileChangeStatus.pending;
    case 'applied':
      return ProfileChangeStatus.applied;
    case 'approved':
      return ProfileChangeStatus.approved;
    case 'rejected':
      return ProfileChangeStatus.rejected;
    case 'cancelled':
      return ProfileChangeStatus.cancelled;
    default:
      return ProfileChangeStatus.pending;
  }
}

/// 单条申请记录（HR 详情 + 员工自查 共用）。
class ProfileChangeItem {
  const ProfileChangeItem({
    required this.id,
    required this.batchId,
    required this.fieldCode,
    required this.fieldLabel,
    required this.fieldGroup,
    this.oldValue,
    required this.newValue,
    required this.status,
    required this.submittedBy,
    this.submittedByName,
    required this.submittedAt,
    this.reviewedBy,
    this.reviewedByName,
    this.reviewedAt,
    this.reviewComment,
    this.employeeVersion,
  });

  final String id;
  final String batchId;
  final String fieldCode;
  final String fieldLabel;
  final String fieldGroup;
  final String? oldValue;
  final String newValue;
  final ProfileChangeStatus status;
  final String submittedBy;
  final String? submittedByName;
  final DateTime submittedAt;
  final String? reviewedBy;
  final String? reviewedByName;
  final DateTime? reviewedAt;
  final String? reviewComment;
  final int? employeeVersion;

  factory ProfileChangeItem.fromJson(Map<String, dynamic> json) {
    return ProfileChangeItem(
      id: json['id'] as String,
      batchId: json['batchId'] as String,
      fieldCode: json['fieldCode'] as String,
      fieldLabel: json['fieldLabel'] as String,
      fieldGroup: (json['fieldGroup'] as String?) ?? 'identity',
      oldValue: json['oldValue'] as String?,
      newValue: json['newValue'] as String? ?? '',
      status: _parseStatus(json['status'] as String?),
      submittedBy: json['submittedBy'] as String,
      submittedByName: json['submittedByName'] as String?,
      submittedAt: DateTime.parse(json['submittedAt'] as String),
      reviewedBy: json['reviewedBy'] as String?,
      reviewedByName: json['reviewedByName'] as String?,
      reviewedAt: json['reviewedAt'] == null
          ? null
          : DateTime.parse(json['reviewedAt'] as String),
      reviewComment: json['reviewComment'] as String?,
      employeeVersion: json['employeeVersion'] as int?,
    );
  }
}

/// 批次详情（含多字段 diff）。
class ProfileChangeBatch {
  const ProfileChangeBatch({
    required this.batchId,
    required this.employeeId,
    this.employeeName,
    this.employeeCode,
    required this.status,
    required this.itemCount,
    required this.items,
    required this.submittedAt,
    this.submittedByName,
    this.reviewedAt,
    this.reviewedByName,
    this.reviewComment,
  });

  final String batchId;
  final String employeeId;
  final String? employeeName;
  final String? employeeCode;
  final ProfileChangeStatus status;
  final int itemCount;
  final List<ProfileChangeItem> items;
  final DateTime submittedAt;
  final String? submittedByName;
  final DateTime? reviewedAt;
  final String? reviewedByName;
  final String? reviewComment;

  factory ProfileChangeBatch.fromJson(Map<String, dynamic> json) {
    final list = (json['items'] as List<dynamic>? ?? const [])
        .map((e) => ProfileChangeItem.fromJson(e as Map<String, dynamic>))
        .toList();
    return ProfileChangeBatch(
      batchId: json['batchId'] as String,
      employeeId: json['employeeId'] as String,
      employeeName: json['employeeName'] as String?,
      employeeCode: json['employeeCode'] as String?,
      status: _parseStatus(json['status'] as String?),
      itemCount: (json['itemCount'] as int?) ?? list.length,
      items: list,
      submittedAt: DateTime.parse(json['submittedAt'] as String),
      submittedByName: json['submittedByName'] as String?,
      reviewedAt: json['reviewedAt'] == null
          ? null
          : DateTime.parse(json['reviewedAt'] as String),
      reviewedByName: json['reviewedByName'] as String?,
      reviewComment: json['reviewComment'] as String?,
    );
  }
}

/// 员工自查列表项（折叠到 batch）。
class MyProfileChangeListItem {
  const MyProfileChangeListItem({
    required this.batchId,
    required this.status,
    required this.itemCount,
    required this.submittedAt,
    this.reviewedAt,
    this.reviewComment,
    required this.fieldCodes,
    required this.fieldLabels,
  });

  final String batchId;
  final ProfileChangeStatus status;
  final int itemCount;
  final DateTime submittedAt;
  final DateTime? reviewedAt;
  final String? reviewComment;
  final List<String> fieldCodes;
  final List<String> fieldLabels;

  factory MyProfileChangeListItem.fromJson(Map<String, dynamic> json) {
    return MyProfileChangeListItem(
      batchId: json['batchId'] as String,
      status: _parseStatus(json['status'] as String?),
      itemCount: (json['itemCount'] as int?) ?? 0,
      submittedAt: DateTime.parse(json['submittedAt'] as String),
      reviewedAt: json['reviewedAt'] == null
          ? null
          : DateTime.parse(json['reviewedAt'] as String),
      reviewComment: json['reviewComment'] as String?,
      fieldCodes: (json['fieldCodes'] as List<dynamic>? ?? const [])
          .cast<String>(),
      fieldLabels: (json['fieldLabels'] as List<dynamic>? ?? const [])
          .cast<String>(),
    );
  }
}

/// HR 队列列表项。
class HrProfileChangeListItem {
  const HrProfileChangeListItem({
    required this.batchId,
    required this.employeeId,
    this.employeeName,
    this.employeeCode,
    this.departmentName,
    required this.status,
    required this.itemCount,
    required this.fieldCodes,
    required this.submittedAt,
    this.reviewedAt,
    this.reviewedByName,
  });

  final String batchId;
  final String employeeId;
  final String? employeeName;
  final String? employeeCode;
  final String? departmentName;
  final ProfileChangeStatus status;
  final int itemCount;
  final List<String> fieldCodes;
  final DateTime submittedAt;
  final DateTime? reviewedAt;
  final String? reviewedByName;

  factory HrProfileChangeListItem.fromJson(Map<String, dynamic> json) {
    return HrProfileChangeListItem(
      batchId: json['batchId'] as String,
      employeeId: json['employeeId'] as String,
      employeeName: json['employeeName'] as String?,
      employeeCode: json['employeeCode'] as String?,
      departmentName: json['departmentName'] as String?,
      status: _parseStatus(json['status'] as String?),
      itemCount: (json['itemCount'] as int?) ?? 0,
      fieldCodes: (json['fieldCodes'] as List<dynamic>? ?? const [])
          .cast<String>(),
      submittedAt: DateTime.parse(json['submittedAt'] as String),
      reviewedAt: json['reviewedAt'] == null
          ? null
          : DateTime.parse(json['reviewedAt'] as String),
      reviewedByName: json['reviewedByName'] as String?,
    );
  }
}

/// 分页（profile_change 后端使用 {items,page,size,totalElements,totalPages}）。
class ProfileChangePage<T> {
  const ProfileChangePage({
    required this.items,
    required this.page,
    required this.size,
    required this.total,
    required this.totalPages,
  });

  final List<T> items;
  final int page;
  final int size;
  final int total;
  final int totalPages;

  factory ProfileChangePage.fromJson(
    Map<String, dynamic> json,
    T Function(Map<String, dynamic>) fromJson,
  ) {
    final list = (json['items'] as List<dynamic>? ?? const [])
        .map((e) => fromJson(e as Map<String, dynamic>))
        .toList();
    return ProfileChangePage<T>(
      items: list,
      page: (json['page'] as int?) ?? 1,
      size: (json['size'] as int?) ?? list.length,
      total: (json['totalElements'] as num?)?.toInt() ?? list.length,
      totalPages: (json['totalPages'] as int?) ?? 1,
    );
  }
}

/// 兼容老接口的 [PagedResult] 工厂。
PagedResult<T> toPagedResult<T>(
  ProfileChangePage<T> p,
  T Function(Map<String, dynamic>) fromJson,
) => PagedResult<T>(
  items: p.items,
  page: p.page,
  size: p.size,
  total: p.total,
  totalPages: p.totalPages,
);
