// 通知模型
// 文档：docs/04-数据模型/实体字典.md#Notice

import 'package:flutter/material.dart';

/// 通知类型
enum NoticeType {
  /// 公司公告（人事发布）
  announcement('公告', 0xFF0F3D2E, Icons.campaign_rounded),

  /// 制度发布
  policy('制度', 0xFF8B5CF6, Icons.gavel_rounded),

  /// 福利通知
  benefit('福利', 0xFFEC4899, Icons.card_giftcard_rounded),

  /// 系统通知
  system('系统', 0xFF3B82F6, Icons.info_rounded),

  /// 警告/紧急
  urgent('紧急', 0xFFEF4444, Icons.priority_high_rounded);

  const NoticeType(this.label, this.colorHex, this.icon);

  final String label;
  final int colorHex;
  final IconData icon;

  Color get color => Color(colorHex);
}

/// 通知
class Notice {
  const Notice({
    required this.id,
    required this.title,
    required this.content,
    required this.type,
    required this.publisher,
    required this.publishedAt,
    required this.isRead,
    this.topPriority = false,
    this.attachments = const [],
    this.readAt,
  });

  final String id;

  /// 标题
  final String title;

  /// 正文（多行）
  final String content;

  /// 类型
  final NoticeType type;

  /// 发布人
  final String publisher;

  /// 发布时间
  final DateTime publishedAt;

  /// 是否已读
  final bool isRead;

  /// 阅读时间
  final DateTime? readAt;

  /// 是否置顶
  final bool topPriority;

  /// 附件（前端 Mock 用文件名表示）
  final List<String> attachments;

  Notice copyWith({bool? isRead, DateTime? readAt}) {
    return Notice(
      id: id,
      title: title,
      content: content,
      type: type,
      publisher: publisher,
      publishedAt: publishedAt,
      isRead: isRead ?? this.isRead,
      topPriority: topPriority,
      attachments: attachments,
      readAt: readAt ?? this.readAt,
    );
  }
}
