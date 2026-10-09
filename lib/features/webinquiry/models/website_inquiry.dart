// 官网询盘模型
// 后端：server .../features/webinquiry（/api/website-inquiries）

import '../../../components/data_display/uten_status_badge.dart';

/// 官网询盘处理状态（与服务端状态机一致）。
enum WebsiteInquiryStatus {
  newOne('未处理'),
  following('跟进中'),
  converted('已转客户'),
  closed('已关闭');

  const WebsiteInquiryStatus(this.label);
  final String label;

  static WebsiteInquiryStatus fromName(String? name) => switch (name) {
    'new' => WebsiteInquiryStatus.newOne,
    'following' => WebsiteInquiryStatus.following,
    'converted' => WebsiteInquiryStatus.converted,
    'closed' => WebsiteInquiryStatus.closed,
    _ => throw FormatException('Unknown website inquiry status: $name'),
  };

  String get wireName => switch (this) {
    WebsiteInquiryStatus.newOne => 'new',
    WebsiteInquiryStatus.following => 'following',
    WebsiteInquiryStatus.converted => 'converted',
    WebsiteInquiryStatus.closed => 'closed',
  };
}

/// 状态→徽章档位（ADR-169 逐页显式映射；列表/详情共用同一状态机，两个页面
/// 同一份映射）。四档在「全部」分段同现仍互可区分：
/// 未处理=蓝（客户已提交、流入收件箱待认领）/ 跟进中=黄（已认领、等客户
/// 回应——等待外部且无异常）/ 已转客户=绿（成功转化终态）/ 已关闭=灰
/// （未成交关闭的中性终态）。
UtenStatusBadgeType websiteInquiryStatusBadgeType(WebsiteInquiryStatus s) =>
    switch (s) {
      WebsiteInquiryStatus.newOne => UtenStatusBadgeType.info,
      WebsiteInquiryStatus.following => UtenStatusBadgeType.warning,
      WebsiteInquiryStatus.converted => UtenStatusBadgeType.success,
      WebsiteInquiryStatus.closed => UtenStatusBadgeType.neutral,
    };

/// 官网询盘（客户留言统一收件箱，综合营销处理）。
class WebsiteInquiry {
  const WebsiteInquiry({
    required this.id,
    required this.name,
    required this.message,
    required this.status,
    required this.receivedAt,
    this.company,
    this.phone,
    this.email,
    this.market,
    this.customerType,
    this.requiredStandard,
    this.productInterest,
    this.requestType,
    this.estimatedQuantity,
    this.targetSchedule,
    this.preferredContact,
    this.source = 'contact',
    this.locale = 'zh',
    this.assigneeName,
    this.clientId,
    this.clientName,
    this.note,
  });

  final String id;
  final String name;
  final String message;
  final WebsiteInquiryStatus status;
  final DateTime receivedAt;

  final String? company;
  final String? phone;
  final String? email;
  final String? market;
  final String? customerType;
  final String? requiredStandard;
  final String? productInterest;
  final String? requestType;
  final String? estimatedQuantity;
  final String? targetSchedule;
  final String? preferredContact;
  final String source;
  final String locale;

  /// 跟进人姓名快照（服务端按 assigneeEmployeeId 解析）。
  final String? assigneeName;

  /// 转客户后关联的客户主档。
  final String? clientId;
  final String? clientName;

  /// 最近一次跟进备注。
  final String? note;

  /// 列表卡片用的一句话摘要。
  String get subtitle => [
    company,
    market,
  ].whereType<String>().where((s) => s.isNotEmpty).join(' · ');
}
