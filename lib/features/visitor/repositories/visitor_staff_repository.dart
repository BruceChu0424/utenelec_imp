// 员工端访客接口封装（HR 审批 / 被访人确认 / 保安核验）：走员工 ApiClient（员工 token）。
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/network/api_client.dart';
import '../../../core/network/api_endpoints.dart';
import '../models/visitor_application.dart';
import 'visitor_repository.dart';

/// 保安扫码核验结果。
class SecurityVerifyResult {
  const SecurityVerifyResult({
    required this.valid,
    required this.color,
    required this.reason,
    this.applicationId,
    this.visitorName,
    this.visitPurpose,
    this.hostName,
    this.plateNo,
    this.plannedVisitAt,
    this.checkInAt,
  });

  final bool valid;
  final String color; // green / red
  final String reason; // ok / invalid / expired / used / rejected
  final String? applicationId;
  final String? visitorName;
  final String? visitPurpose;
  final String? hostName;
  final String? plateNo;
  final DateTime? plannedVisitAt;
  final DateTime? checkInAt;

  factory SecurityVerifyResult.fromJson(Map<String, dynamic> j) => SecurityVerifyResult(
        valid: j['valid'] == true,
        color: (j['color'] ?? '').toString(),
        reason: (j['reason'] ?? '').toString(),
        applicationId: j['applicationId']?.toString(),
        visitorName: j['visitorName'] as String?,
        visitPurpose: j['visitPurpose'] as String?,
        hostName: j['hostName'] as String?,
        plateNo: j['plateNo'] as String?,
        plannedVisitAt: j['plannedVisitAt'] is String
            ? DateTime.tryParse(j['plannedVisitAt'] as String)
            : null,
        checkInAt: j['checkInAt'] is String ? DateTime.tryParse(j['checkInAt'] as String) : null,
      );
}

class VisitorStaffRepository {
  VisitorStaffRepository(this._api);

  final ApiClient _api;

  // —— HR 审批 ——
  Future<List<VisitorApplication>> approvalList({String? status}) async {
    final list = await _api.getList(ApiEndpoints.visitorApproval,
        query: status == null ? null : {'status': status});
    return list.map(VisitorApplication.fromJson).toList();
  }

  /// HR 访客待办数（工作台/导航徽章）。
  Future<int> pendingCount() async {
    final r = await _api.get(ApiEndpoints.visitorApprovalPendingCount);
    return (r['count'] as num?)?.toInt() ?? 0;
  }

  /// 我作为接待人的待确认数（工作台/导航徽章）。
  Future<int> hostPendingCount() async {
    final r = await _api.get(ApiEndpoints.visitorApprovalHostPendingCount);
    return (r['count'] as num?)?.toInt() ?? 0;
  }

  Future<VisitorApplicationDetail> approvalDetail(String id) async {
    final r = await _api.get(ApiEndpoints.visitorApprovalById(id));
    final app = VisitorApplication.fromJson(r);
    final steps = (r['steps'] as List?)
            ?.map((e) => VisitorApprovalStep.fromJson(e as Map<String, dynamic>))
            .toList() ??
        const [];
    return VisitorApplicationDetail(application: app, steps: steps);
  }

  Future<VisitorApplication> action(String id,
      {required String action, String? comment, String? rejectReason}) async {
    final r = await _api.post(ApiEndpoints.visitorApprovalAction(id), body: {
      'action': action,
      'comment': comment,
      'rejectReason': rejectReason,
    });
    return VisitorApplication.fromJson(r);
  }

  Future<void> hostConfirm(String id, {required bool confirmed, String? comment}) async {
    await _api.post(ApiEndpoints.visitorHostConfirm(id), body: {
      'confirmed': confirmed,
      'comment': comment,
    });
  }

  // —— 被访人 ——
  Future<List<VisitorApplication>> myAsHost() async {
    final list = await _api.getList(ApiEndpoints.visitorApprovalAsHost);
    return list.map(VisitorApplication.fromJson).toList();
  }

  // —— 保安核验 ——
  Future<SecurityVerifyResult> verify({String? qrToken, String? passcode}) async {
    final r = await _api.post(ApiEndpoints.securityVerify, body: {
      if (qrToken != null) 'qrToken': qrToken,
      if (passcode != null) 'passcode': passcode,
    });
    return SecurityVerifyResult.fromJson(r);
  }

  Future<SecurityVerifyResult> checkIn(String appId) async {
    final r = await _api.post(ApiEndpoints.securityCheckIn(appId));
    return SecurityVerifyResult.fromJson(r);
  }
}

final visitorStaffRepositoryProvider = Provider<VisitorStaffRepository>((ref) {
  return VisitorStaffRepository(ref.watch(apiClientProvider));
});
