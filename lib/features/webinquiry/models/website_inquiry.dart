// 官网询盘模型
// 后端：server .../features/webinquiry（/api/website-inquiries）

import 'package:flutter/material.dart';

/// 官网询盘处理状态（与服务端状态机一致）。
enum WebsiteInquiryStatus {
  newOne('未处理', 0xFF3B82F6),
  following('跟进中', 0xFFF59E0B),
  converted('已转客户', 0xFF22C55E),
  closed('已关闭', 0xFF64748B);

  const WebsiteInquiryStatus(this.label, this.colorHex);
  final String label;
  final int colorHex;
  Color get color => Color(colorHex);

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
