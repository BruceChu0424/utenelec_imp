// 通知模型
// 文档：docs/04-数据模型/实体字典.md#Notice

import 'package:flutter/material.dart';

import '../../../core/utils/china_datetime.dart';
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
  workflow('流程', 0xFF10B981, Icons.account_tree_rounded),

  /// 生日祝福（庆典类，可由系统按 birth_date 自动发布）
  birthday('生日', 0xFFF43F5E, Icons.cake_rounded),

  /// 入职周年（庆典类，可由系统按 hire_date 自动发布）
  anniversary('周年', 0xFFF59E0B, Icons.emoji_events_rounded),

  /// 新婚祝福（庆典类，仅手动发布）
  wedding('新婚', 0xFFD946EF, Icons.favorite_rounded),

  /// 新生儿祝福（庆典类，仅手动发布）
  newborn('新生儿', 0xFF38BDF8, Icons.child_care_rounded);

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

  /// 是否庆典类（生日/周年/新婚/新生儿）——同事可「送上祝福」。
  bool get isCelebratory => switch (this) {
    NoticeType.birthday ||
    NoticeType.anniversary ||
    NoticeType.wedding ||
    NoticeType.newborn =>
      true,
    _ => false,
  };

  /// 该类型支持的互动模式（与后端 interaction_mode 派生一致）。
  NoticeInteractionMode get interactionMode => switch (this) {
    NoticeType.birthday ||
    NoticeType.anniversary ||
    NoticeType.wedding ||
    NoticeType.newborn =>
      NoticeInteractionMode.bless,
    NoticeType.task || NoticeType.approval || NoticeType.workflow =>
      NoticeInteractionMode.none,
    _ => NoticeInteractionMode.acknowledge,
  };
}

/// 通知互动模式（按类型派生）：庆典→送上祝福；公告广播→点击收到；工作类→无。
enum NoticeInteractionMode {
  none,
  acknowledge,
  bless;

  static NoticeInteractionMode fromName(String? value) => switch (value) {
    'bless' => NoticeInteractionMode.bless,
    'acknowledge' => NoticeInteractionMode.acknowledge,
    _ => NoticeInteractionMode.none,
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
    this.interactionMode = NoticeInteractionMode.none,
    this.subjectName,
    this.eventLabel,
    this.ackCount = 0,
    this.blessingCount = 0,
    this.myAcked = false,
    this.myBlessing,
    this.recentAckers = const [],
    this.recentBlessings = const [],
    this.blessingTemplates = const [],
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

  /// 互动模式（来自后端 interaction_mode，缺省按 [type] 派生）。
  final NoticeInteractionMode interactionMode;

  /// 庆典对象姓名快照（生日/周年等「被祝福人」）。
  final String? subjectName;

  /// 事件标签快照（如「生日快乐」「入职5周年」）。
  final String? eventLabel;

  /// 已「点击收到」人数（acknowledge 模式）。
  final int ackCount;

  /// 已收到「祝福」条数（bless 模式）。
  final int blessingCount;

  /// 当前用户是否已点收到。
  final bool myAcked;

  /// 当前用户已送的祝福内容（未送为 null）。
  final String? myBlessing;

  /// 近期「已收到」人姓名（最多 8）。
  final List<String> recentAckers;

  /// 近期祝福（最多 5 条）。
  final List<NoticeBlessing> recentBlessings;

  /// 发布者勾选提供给送祝福者的模板（空=用系统默认）。
  final List<String> blessingTemplates;

  Notice copyWith({
    bool? isRead,
    DateTime? readAt,
    bool? taskCompleted,
    DateTime? taskCompletedAt,
    int? ackCount,
    int? blessingCount,
    bool? myAcked,
    String? myBlessing,
    List<String>? recentAckers,
    List<NoticeBlessing>? recentBlessings,
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
      interactionMode: interactionMode,
      subjectName: subjectName,
      eventLabel: eventLabel,
      ackCount: ackCount ?? this.ackCount,
      blessingCount: blessingCount ?? this.blessingCount,
      myAcked: myAcked ?? this.myAcked,
      myBlessing: myBlessing ?? this.myBlessing,
      recentAckers: recentAckers ?? this.recentAckers,
      recentBlessings: recentBlessings ?? this.recentBlessings,
    );
  }
}

/// 一条祝福（庆典通知互动）。
class NoticeBlessing {
  const NoticeBlessing({
    required this.id,
    required this.senderName,
    required this.content,
    required this.createdAt,
    this.mine = false,
  });

  final String id;

  /// 送祝福人姓名快照。
  final String senderName;

  /// 祝福内容。
  final String content;

  /// 送出时间。
  final DateTime createdAt;

  /// 是否当前用户所送。
  final bool mine;

  factory NoticeBlessing.fromJson(Map<String, dynamic> json) {
    return NoticeBlessing(
      id: json['id'] as String? ?? '',
      senderName: json['senderName'] as String? ?? '',
      content: json['content'] as String? ?? '',
      createdAt:
          ChinaDateTime.tryParse(json['createdAt'] as String?) ??
          ChinaDateTime.now(),
      mine: json['mine'] as bool? ?? false,
    );
  }
}

/// 发布页庆典预览：选对象 + 类型后，服务端返回自动填充信息。
class NoticeCelebrationPreview {
  const NoticeCelebrationPreview({
    required this.subjectName,
    required this.eventLabel,
    required this.suggestedTitle,
    this.suggestedTemplates = const [],
  });

  final String subjectName;
  final String eventLabel;
  final String suggestedTitle;
  final List<String> suggestedTemplates;

  factory NoticeCelebrationPreview.fromJson(Map<String, dynamic> json) {
    return NoticeCelebrationPreview(
      subjectName: json['subjectName'] as String? ?? '',
      eventLabel: json['eventLabel'] as String? ?? '',
      suggestedTitle: json['suggestedTitle'] as String? ?? '',
      suggestedTemplates:
          (json['suggestedTemplates'] as List<dynamic>? ?? const [])
              .cast<String>(),
    );
  }
}

/// 自动庆典发布设置（系统设置）。
class NoticeCelebrationSettings {
  const NoticeCelebrationSettings({
    this.autoEnabled = true,
    this.autoTypes = const ['birthday', 'anniversary'],
    this.publisherName = '公司',
  });

  final bool autoEnabled;
  final List<String> autoTypes;
  final String publisherName;

  factory NoticeCelebrationSettings.fromJson(Map<String, dynamic> json) {
    return NoticeCelebrationSettings(
      autoEnabled: json['autoEnabled'] as bool? ?? true,
      autoTypes:
          (json['autoTypes'] as List<dynamic>? ?? const []).cast<String>(),
      publisherName: json['publisherName'] as String? ?? '公司',
    );
  }
}

/// 当前用户「今日庆典」条目（登录弹窗 / 今日概览庆典卡片）。
/// 生日/周年由服务端按 birth_date / hire_date 月日判定；新婚/新生儿由今日发布的庆典通知判定。
/// noticeId 可空（尚未发布对应通知时），用于跳转祝福墙。无任何日期原值（PII 安全）。
class MyCelebrationToday {
  const MyCelebrationToday({
    required this.type,
    required this.subjectName,
    required this.eventLabel,
    this.noticeId,
  });

  final NoticeType type;
  final String subjectName;
  final String eventLabel;
  final String? noticeId;

  factory MyCelebrationToday.fromJson(Map<String, dynamic> json) {
    return MyCelebrationToday(
      type: _typeFromName(json['type'] as String?),
      subjectName: json['subjectName'] as String? ?? '',
      eventLabel: json['eventLabel'] as String? ?? '',
      noticeId: json['noticeId'] as String?,
    );
  }

  static NoticeType _typeFromName(String? name) => switch (name) {
    'birthday' => NoticeType.birthday,
    'anniversary' => NoticeType.anniversary,
    'wedding' => NoticeType.wedding,
    'newborn' => NoticeType.newborn,
    _ => NoticeType.birthday,
  };
}

/// 一键批量发布庆典祝福结果。
class CelebrationBatchResult {
  const CelebrationBatchResult({required this.published, required this.skipped});

  final int published;
  final int skipped;

  factory CelebrationBatchResult.fromJson(Map<String, dynamic> json) {
    return CelebrationBatchResult(
      published: (json['published'] as num?)?.toInt() ?? 0,
      skipped: (json['skipped'] as num?)?.toInt() ?? 0,
    );
  }
}
