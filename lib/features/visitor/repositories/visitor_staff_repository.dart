// 员工端访客接口封装（HR 审批 / 被访人确认 / 保安核验）：走员工 ApiClient（员工 token）。
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/network/api_client.dart';
import '../../../core/network/api_endpoints.dart';
import '../../../core/utils/china_datetime.dart';
import '../../../shared/models/paged_result.dart';
import '../../basic_data/models/master_facet.dart';
import '../models/visitor_application.dart';
import 'visitor_repository.dart';

/// 保安扫码核验结果。
class SecurityVerifyResult {
  const SecurityVerifyResult({
    required this.valid,
    required this.color,
    required this.reason,
    this.applicationId,
    this.visitorId,
    this.visitorName,
    this.visitPurpose,
    this.hostName,
    this.plateNo,
    this.plannedVisitAt,
    this.checkInAt,
  });

  final bool valid;
  final String color; // green / red
  final String reason; // ok / invalid / expired / used / rejected / blocked
  final String? applicationId;

  /// 访客账号 id（红结果定位访客发起拉黑用；凭据无效时为 null）。
  final String? visitorId;
  final String? visitorName;
  final String? visitPurpose;
  final String? hostName;
  final String? plateNo;
  final DateTime? plannedVisitAt;
  final DateTime? checkInAt;

  factory SecurityVerifyResult.fromJson(Map<String, dynamic> j) =>
      SecurityVerifyResult(
        valid: j['valid'] == true,
        color: (j['color'] ?? '').toString(),
        reason: (j['reason'] ?? '').toString(),
        applicationId: j['applicationId']?.toString(),
        visitorId: j['visitorId']?.toString(),
        visitorName: j['visitorName'] as String?,
        visitPurpose: j['visitPurpose'] as String?,
        hostName: j['hostName'] as String?,
        plateNo: j['plateNo'] as String?,
        plannedVisitAt: j['plannedVisitAt'] is String
            ? ChinaDateTime.tryParse(j['plannedVisitAt'] as String)
            : null,
        checkInAt: j['checkInAt'] is String
            ? ChinaDateTime.tryParse(j['checkInAt'] as String)
            : null,
      );
}

/// 黑名单列表项（管理页）。
class VisitorBlacklistItem {
  const VisitorBlacklistItem({
    required this.id,
    required this.visitorNo,
    required this.name,
    this.phone,
    this.blockedReason,
    this.blockedAt,
    this.blockedByName,
  });

  final String id;
  final String visitorNo;
  final String name;
  final String? phone;
  final String? blockedReason;
  final DateTime? blockedAt;
  final String? blockedByName;

  factory VisitorBlacklistItem.fromJson(Map<String, dynamic> j) =>
      VisitorBlacklistItem(
        id: (j['id'] ?? '').toString(),
        visitorNo: (j['visitorNo'] ?? '').toString(),
        name: (j['name'] ?? '').toString(),
        phone: j['phone'] as String?,
        blockedReason: j['blockedReason'] as String?,
        blockedAt: j['blockedAt'] is String
            ? ChinaDateTime.tryParse(j['blockedAt'] as String)
            : null,
        blockedByName: j['blockedByName'] as String?,
      );
}

class VisitorStaffRepository {
  VisitorStaffRepository(this._api);

  final ApiClient _api;

  // —— HR 审批 ——
  /// [hostDepartmentId]：接待人所属部门（申请时快照），表头「接待人部门」筛选下推。
  Future<PagedResult<VisitorApplication>> approvalList({
    String? status,
    String? hostDepartmentId,
    int page = 1,
    int size = 20,
  }) async {
    final query = <String, dynamic>{'page': page, 'size': size};
    if (status != null) query['status'] = status;
    if (hostDepartmentId != null && hostDepartmentId.isNotEmpty) {
      query['hostDepartmentId'] = hostDepartmentId;
    }
    final response = await _api.get(ApiEndpoints.visitorApproval, query: query);
    return PagedResult.fromJson(response, VisitorApplication.fromJson);
  }

  /// HR 审批列表表头筛选桶（2026-09-10）：键与列 key 对齐——
  /// status（value=后端状态码，页面按 l10n 重贴标签）、hostDepartment（value=部门 id、
  /// label=部门名）。[status] 与列表分段同口径（空 = 待办状态集）。
  Future<Map<String, List<MasterFacetBucket>>> approvalFacets({
    String? status,
  }) async {
    final response = await _api.get(
      ApiEndpoints.visitorApprovalFacets,
      query: <String, dynamic>{'status': ?status},
    );
    List<MasterFacetBucket> parse(Object? raw) => [
      for (final e in (raw as List<dynamic>? ?? const []))
        MasterFacetBucket.fromJson(e as Map<String, dynamic>),
    ];
    return {
      'status': parse(response['statuses']),
      'hostDepartment': parse(response['departments']),
    };
  }

  Future<VisitorApplicationDetail> approvalDetail(String id) async {
    final r = await _api.get(ApiEndpoints.visitorApprovalById(id));
    final app = VisitorApplication.fromJson(r);
    final steps =
        (r['steps'] as List?)
            ?.map(
              (e) => VisitorApprovalStep.fromJson(e as Map<String, dynamic>),
            )
            .toList() ??
        const [];
    return VisitorApplicationDetail(application: app, steps: steps);
  }

  Future<VisitorApplication> action(
    String id, {
    required String action,
    String? comment,
    String? rejectReason,
  }) async {
    final r = await _api.post(
      ApiEndpoints.visitorApprovalAction(id),
      body: {
        'action': action,
        'comment': comment,
        'rejectReason': rejectReason,
      },
    );
    return VisitorApplication.fromJson(r);
  }

  Future<void> hostConfirm(
    String id, {
    required bool confirmed,
    String? comment,
  }) async {
    await _api.post(
      ApiEndpoints.visitorHostConfirm(id),
      body: {'confirmed': confirmed, 'comment': comment},
    );
  }

  // —— 被访人 ——
  Future<PagedResult<VisitorApplication>> myAsHost({
    String? status,
    int page = 1,
    int size = 20,
  }) async {
    final query = <String, dynamic>{'page': page, 'size': size};
    if (status != null) query['status'] = status;
    final response = await _api.get(
      ApiEndpoints.visitorApprovalAsHost,
      query: query,
    );
    return PagedResult.fromJson(response, VisitorApplication.fromJson);
  }

  // —— 保安核验 ——
  Future<SecurityVerifyResult> verify({
    String? qrToken,
    String? passcode,
  }) async {
    final r = await _api.post(
      ApiEndpoints.securityVerify,
      body: {'qrToken': ?qrToken, 'passcode': ?passcode},
    );
    return SecurityVerifyResult.fromJson(r);
  }

  Future<SecurityVerifyResult> checkIn(String appId) async {
    final r = await _api.post(ApiEndpoints.securityCheckIn(appId));
    return SecurityVerifyResult.fromJson(r);
  }

  // —— 黑名单（visitor:blacklist）——
  /// 拉黑访客账号：原因必填（≤200 字），后端同事务写 blocked_* 并审计。
  Future<void> blacklist(String visitorId, {required String reason}) async {
    await _api.post(
      ApiEndpoints.securityBlacklistById(visitorId),
      body: {'reason': reason},
    );
  }

  /// 解除拉黑：账号回 active，可重新登录/申请；历史申请状态不变。
  Future<void> unblacklist(String visitorId) async {
    await _api.delete(ApiEndpoints.securityBlacklistById(visitorId));
  }

  /// 黑名单分页列表（拉黑时间新者优先）。
  Future<PagedResult<VisitorBlacklistItem>> blacklistPage({
    int page = 1,
    int size = 20,
  }) async {
    final response = await _api.get(
      ApiEndpoints.securityBlacklist,
      query: {'page': page, 'size': size},
    );
    return PagedResult.fromJson(response, VisitorBlacklistItem.fromJson);
  }
}

final visitorStaffRepositoryProvider = Provider<VisitorStaffRepository>((ref) {
  return VisitorStaffRepository(ref.watch(apiClientProvider));
});

/// 被访人四档计数快照(ADR-100)。值相等: 徽章汇总每分钟换一份新对象,
/// 计数没变时不让「我的访客」整页重建。
class VisitorHostCounts {
  const VisitorHostCounts({
    this.pending = 0,
    this.ongoing = 0,
    this.hrReviewing = 0,
    this.awaitingVisit = 0,
  });

  /// 待我确认接待(红徽章)。
  final int pending;

  /// 我已确认、这趟来访还没走完(黄徽章, 卡面与顶栏用)。
  final int ongoing;

  /// [ongoing] 的一半: 我已确认、HR 还在审批(列表 status=pending 段)。
  final int hrReviewing;

  /// [ongoing] 的另一半: 已通过、访客还没来核验(列表 status=approved 段)。
  final int awaitingVisit;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is VisitorHostCounts &&
          other.pending == pending &&
          other.ongoing == ongoing &&
          other.hrReviewing == hrReviewing &&
          other.awaitingVisit == awaitingVisit;

  @override
  int get hashCode => Object.hash(pending, ongoing, hrReviewing, awaitingVisit);
}
