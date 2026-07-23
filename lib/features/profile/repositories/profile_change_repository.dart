// 个人信息修改 — 仓库层。
// 文档：docs/03-页面/我的页.md

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/network/api_client.dart';
import '../../../core/network/api_endpoints.dart';
import '../models/profile_change_request.dart';

abstract interface class ProfileChangeRepository {
  /// 自己提交修改申请。
  Future<SubmitProfileChangeResponse> submit(SubmitProfileChangeRequest req);

  /// 员工自查列表。
  Future<ProfileChangePage<MyProfileChangeListItem>> myList({
    int page = 1,
    int size = 20,
    String? status,
  });

  /// 员工自查单批详情。
  Future<ProfileChangeBatch> myBatchDetail(String batchId);

  /// 员工撤销未审次。
  Future<void> cancel(String batchId);

  /// HR 队列列表。
  Future<ProfileChangePage<HrProfileChangeListItem>> hrList({
    int page = 1,
    int size = 20,
    String? status,
    String? employeeId,
  });

  /// HR 单批详情。
  Future<ProfileChangeBatch> hrBatchDetail(String batchId);

  /// HR 审批（approve / reject）。
  Future<ProfileChangeBatch> review(String batchId, String action, String? comment);

  /// HR 全局待办数（导航徽章）。
  Future<int> hrPendingCount();

  /// 某员工的 HR 待办数（员工详情页 Hero 后区块）。
  Future<int> hrPendingCountFor(String employeeId);

  /// 密码二次确认（仅校验，不改密）。
  Future<void> verifyPassword(String password);
}

class SubmitProfileChangeRequest {
  SubmitProfileChangeRequest({
    this.batchId,
    required this.changes,
    required this.idemKey,
  });
  final String? batchId;
  final List<ProfileFieldChange> changes;
  final String idemKey;

  Map<String, dynamic> toJson() => {
        if (batchId != null) 'batchId': batchId,
        'changes': changes.map((c) => c.toJson()).toList(),
        'idemKey': idemKey,
      };
}

class ProfileFieldChange {
  ProfileFieldChange({
    required this.fieldCode,
    required this.fieldLabel,
    required this.newValue,
  });
  final String fieldCode;
  final String fieldLabel;
  final String newValue;

  Map<String, dynamic> toJson() => {
        'fieldCode': fieldCode,
        'fieldLabel': fieldLabel,
        'newValue': newValue,
      };
}

class SubmitProfileChangeResponse {
  const SubmitProfileChangeResponse({
    required this.batchId,
    required this.requestIds,
    required this.count,
  });
  final String batchId;
  final List<String> requestIds;
  final int count;

  factory SubmitProfileChangeResponse.fromJson(Map<String, dynamic> json) {
    return SubmitProfileChangeResponse(
      batchId: json['batchId'] as String,
      requestIds: (json['requestIds'] as List<dynamic>? ?? const []).cast<String>(),
      count: (json['count'] as int?) ?? 0,
    );
  }
}

class DioProfileChangeRepository implements ProfileChangeRepository {
  DioProfileChangeRepository(this.api);
  final ApiClient api;

  @override
  Future<SubmitProfileChangeResponse> submit(SubmitProfileChangeRequest req) async {
    final json = await api.post(ApiEndpoints.profileMyChanges, body: req.toJson());
    return SubmitProfileChangeResponse.fromJson(json);
  }

  @override
  Future<ProfileChangePage<MyProfileChangeListItem>> myList({
    int page = 1,
    int size = 20,
    String? status,
  }) async {
    final query = <String, dynamic>{
      'page': page,
      'size': size,
      if (status != null && status.isNotEmpty) 'status': status,
    };
    final json = await api.get(ApiEndpoints.profileMyChanges, query: query);
    return ProfileChangePage.fromJson(json, MyProfileChangeListItem.fromJson);
  }

  @override
  Future<ProfileChangeBatch> myBatchDetail(String batchId) async {
    final json = await api.get('${ApiEndpoints.profileMyChanges}/$batchId');
    return ProfileChangeBatch.fromJson(json);
  }

  @override
  Future<void> cancel(String batchId) async {
    await api.delete('${ApiEndpoints.profileMyChanges}/$batchId');
  }

  @override
  Future<ProfileChangePage<HrProfileChangeListItem>> hrList({
    int page = 1,
    int size = 20,
    String? status,
    String? employeeId,
  }) async {
    final query = <String, dynamic>{
      'page': page,
      'size': size,
      if (status != null && status.isNotEmpty) 'status': status,
      if (employeeId != null && employeeId.isNotEmpty) 'employeeId': employeeId,
    };
    final json = await api.get(ApiEndpoints.hrProfileChanges, query: query);
    return ProfileChangePage.fromJson(json, HrProfileChangeListItem.fromJson);
  }

  @override
  Future<ProfileChangeBatch> hrBatchDetail(String batchId) async {
    final json = await api.get(ApiEndpoints.hrProfileChangeDetail(batchId));
    return ProfileChangeBatch.fromJson(json);
  }

  @override
  Future<ProfileChangeBatch> review(String batchId, String action, String? comment) async {
    final json = await api.post(
      ApiEndpoints.hrProfileChangeReview(batchId),
      body: {'action': action, if (comment != null) 'comment': comment},
    );
    return ProfileChangeBatch.fromJson(json);
  }

  @override
  Future<int> hrPendingCount() async {
    final json = await api.get(ApiEndpoints.hrProfileChangesPendingCount);
    return (json['count'] as num?)?.toInt() ?? 0;
  }

  @override
  Future<int> hrPendingCountFor(String employeeId) async {
    final json = await api.get(ApiEndpoints.hrProfileChangesPendingCountFor(employeeId));
    return (json['count'] as num?)?.toInt() ?? 0;
  }

  @override
  Future<void> verifyPassword(String password) async {
    await api.post(ApiEndpoints.authVerifyPassword, body: {'password': password});
  }
}

final profileChangeRepositoryProvider = Provider<ProfileChangeRepository>(
  (ref) => DioProfileChangeRepository(ref.watch(apiClientProvider)),
);