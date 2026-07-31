// 通知模型
// 文档：docs/04-数据模型/实体字典.md#Notice

import 'package:flutter/material.dart';

import 'notice_audience.dart';

/// 通知类型
enum NoticeType {
  /// 公司公告（人事发布）
  announcement('公告', 0xFF14B8A6, Icons.campaign_rounded),

  /// 制度发布
  policy('制度', 0xFF8B5CF6, Icons.gavel_rounded),

  /// 福利通知
  benefit('福利', 0xFFEC4899, Icons.card_giftcard_rounded),

  /// 系统通知
  system('系统', 0xFF3B82F6, Icons.info_rounded),

  /// 警告/紧急
  urgent('紧急', 0xFFEF4444, Icons.priority_high_rounded),

  /// 工作任务下发（工作类）
  task('任务', 0xFF0EA5E9, Icons.assignment_rounded),

  /// 审批结果 / 待办（工作类）
  approval('审批', 0xFF6366F1, Icons.approval_rounded),

  /// 流程节点完成 / 上游完成（工作类）
  workflow('流程', 0xFF10B981, Icons.account_tree_rounded);

  const NoticeType(this.label, this.colorHex, this.icon);

  final String label;
  final int colorHex;
  final IconData icon;

  Color get color => Color(colorHex);

  /// 是否工作类通知（任务/审批/流程）——工作平台的核心标识，
  /// 与公告类（announcement/policy/benefit/system/urgent）区分。
  bool get isWork => switch (this) {
    NoticeType.task || NoticeType.approval || NoticeType.workflow => true,
    _ => false,
  };
}

/// 普通通知只进入消息中心；待办通知同时进入接收人的工作台。
enum NoticeKind {
  normal,
  todo;

  static NoticeKind fromName(String? value) => switch (value) {
    'TODO' || 'todo' => NoticeKind.todo,
    _ => NoticeKind.normal,
  };
}

/// 通知重要度（驱动卡片样式与到达时的弹出通道）
enum NoticePriority {
  /// 一般：到达时顶部弹条（微信式，不阻塞）
  normal('一般', 0xFF3B82F6),

  /// 重要：到达时屏幕正中弹窗（橙色），卡片带重要标识
  important('重要', 0xFFF59E0B),

  /// 紧急：到达时屏幕正中弹窗（红色，禁止遮罩关闭），卡片带紧急标识
  urgent('紧急', 0xFFEF4444);

  const NoticePriority(this.label, this.colorHex);

  final String label;
  final int colorHex;

  Color get color => Color(colorHex);

  /// 是否需要在卡片上显示重要度标识（normal 不显示）
  bool get showBadge => this != NoticePriority.normal;
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
    this.priority = NoticePriority.normal,
    this.attachments = const [],
    this.readAt,
    this.audienceScope = NoticeAudienceScope.all,
    this.audienceSummary = '全体员工',
    this.audienceCount,
    this.kind = NoticeKind.normal,
    this.actionRoute,
    this.dueAt,
    this.taskCompleted = false,
    this.taskCompletedAt,
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

  /// 重要度（默认一般；驱动卡片样式与到达弹出通道）
  final NoticePriority priority;

  /// 附件（前端 Mock 用文件名表示）
  final List<String> attachments;

  /// 全员广播 / 发布时固化的指定接收范围。
  final NoticeAudienceScope audienceScope;

  /// 可读接收范围摘要。
  final String audienceSummary;

  /// 指定范围去重后的实际接收人数；全员广播为 null。
  final int? audienceCount;

  /// 普通通知 / 工作台待办通知。
  final NoticeKind kind;

  /// 待办对应的站内办理入口。
  final String? actionRoute;

  /// 待办截止时间。
  final DateTime? dueAt;

  /// 当前接收人是否已完成该通知待办。
  final bool taskCompleted;

  final DateTime? taskCompletedAt;

  Notice copyWith({
    bool? isRead,
    DateTime? readAt,
    bool? taskCompleted,
    DateTime? taskCompletedAt,
  }) {
    return Notice(
      id: id,
      title: title,
      content: content,
      type: type,
      publisher: publisher,
      publishedAt: publishedAt,
      isRead: isRead ?? this.isRead,
      topPriority: topPriority,
      priority: priority,
      attachments: attachments,
      readAt: readAt ?? this.readAt,
      audienceScope: audienceScope,
      audienceSummary: audienceSummary,
      audienceCount: audienceCount,
      kind: kind,
      actionRoute: actionRoute,
      dueAt: dueAt,
      taskCompleted: taskCompleted ?? this.taskCompleted,
      taskCompletedAt: taskCompletedAt ?? this.taskCompletedAt,
    );
  }
}
