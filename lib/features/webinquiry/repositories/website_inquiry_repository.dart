// 官网询盘仓库（真实后端）
// 后端：server .../features/webinquiry/WebsiteInquiryController（/api/website-inquiries）

import '../../../core/network/api_client.dart';
import '../../../core/network/api_endpoints.dart';
import '../../../core/utils/china_datetime.dart';
import '../../../shared/models/paged_result.dart';
import '../models/website_inquiry.dart';

abstract interface class WebsiteInquiryRepository {
  /// 询盘分页列表，[status] 为空表示全部状态。
  Future<PagedResult<WebsiteInquiry>> list({
    WebsiteInquiryStatus? status,
    String keyword = '',
    int page = 1,
    int size = 20,
  });

  Future<WebsiteInquiry?> getById(String id);

  /// 跟进状态推进（new/following/closed）；[assignToMe] 把当前员工记为跟进人。
  Future<WebsiteInquiry> updateStatus({
    required String id,
    required WebsiteInquiryStatus status,
    String? note,
    bool assignToMe = false,
  });

  /// 一键转客户主档（幂等；成功后状态为 converted）。
  Future<WebsiteInquiry> convert(String id);
}

class DioWebsiteInquiryRepository implements WebsiteInquiryRepository {
  DioWebsiteInquiryRepository(this._api);

  final ApiClient _api;

  @override
  Future<PagedResult<WebsiteInquiry>> list({
    WebsiteInquiryStatus? status,
    String keyword = '',
    int page = 1,
    int size = 20,
  }) async {
    final json = await _api.get(
      ApiEndpoints.websiteInquiries,
      query: {
        if (status != null) 'status': status.wireName,
        if (keyword.trim().isNotEmpty) 'keyword': keyword.trim(),
        'page': page,
        'size': size,
      },
    );
    return PagedResult.fromJson(json, _fromJson);
  }

  @override
  Future<WebsiteInquiry?> getById(String id) async {
    final json = await _api.get(ApiEndpoints.websiteInquiry(id));
    if (json.isEmpty) return null;
    return _fromJson(json);
  }

  @override
  Future<WebsiteInquiry> updateStatus({
    required String id,
    required WebsiteInquiryStatus status,
    String? note,
    bool assignToMe = false,
  }) async {
    final json = await _api.post(
      ApiEndpoints.websiteInquiryStatus(id),
      body: {
        'status': status.wireName,
        if (note != null && note.trim().isNotEmpty) 'note': note.trim(),
        'assignToMe': assignToMe,
      },
    );
    return _fromJson(json);
  }

  @override
  Future<WebsiteInquiry> convert(String id) async {
    final json = await _api.post(ApiEndpoints.websiteInquiryConvert(id));
    return _fromJson(json);
  }

  WebsiteInquiry _fromJson(Map<String, dynamic> json) {
    final receivedAt = ChinaDateTime.tryParse(json['receivedAt'] as String?);
    if (receivedAt == null) {
      throw FormatException(
        'Invalid website inquiry receivedAt: ${json['receivedAt']}',
      );
    }
    return WebsiteInquiry(
      id: json['id'] as String,
      name: json['name'] as String? ?? '',
      message: json['message'] as String? ?? '',
      status: WebsiteInquiryStatus.fromName(json['status'] as String?),
      receivedAt: receivedAt,
      company: json['company'] as String?,
      phone: json['phone'] as String?,
      email: json['email'] as String?,
      market: json['market'] as String?,
      customerType: json['customerType'] as String?,
      requiredStandard: json['requiredStandard'] as String?,
      productInterest: json['productInterest'] as String?,
      requestType: json['requestType'] as String?,
      estimatedQuantity: json['estimatedQuantity'] as String?,
      targetSchedule: json['targetSchedule'] as String?,
      preferredContact: json['preferredContact'] as String?,
      source: json['source'] as String? ?? 'contact',
      locale: json['locale'] as String? ?? 'zh',
      assigneeName: json['assigneeName'] as String?,
      clientId: json['clientId'] as String?,
      clientName: json['clientName'] as String?,
      note: json['note'] as String?,
    );
  }
}
