// 建议模型
// 文档：docs/04-数据模型/实体字典.md#Suggestion

import 'package:flutter/material.dart';

/// 建议类别
enum SuggestionCategory {
  product('产品改进', Icons.precision_manufacturing_rounded, 0xFF14B8A6),
  process('流程优化', Icons.account_tree_rounded, 0xFF3B82F6),
  welfare('员工福利', Icons.volunteer_activism_rounded, 0xFFEC4899),
  environment('工作环境', Icons.eco_rounded, 0xFF22C55E),
  equipment('设备工具', Icons.build_rounded, 0xFF8B5CF6),
  other('其他', Icons.more_horiz_rounded, 0xFF64748B);

  const SuggestionCategory(this.label, this.icon, this.colorHex);
  final String label;
  final IconData icon;
  final int colorHex;
  Color get color => Color(colorHex);
}

/// 建议状态
enum SuggestionStatus {
  submitted('已提交', 0xFF3B82F6),
  reviewing('处理中', 0xFFF59E0B),
  resolved('已采纳', 0xFF22C55E),
  rejected('未采纳', 0xFFEF4444);

  const SuggestionStatus(this.label, this.colorHex);
  final String label;
  final int colorHex;
  Color get color => Color(colorHex);
}

/// 建议
class Suggestion {
  const Suggestion({
    required this.id,
    required this.submitterId,
    required this.submitterName,
    required this.category,
    required this.title,
    required this.content,
    required this.status,
    required this.submittedAt,
    this.isAnonymous = false,
    this.likes = 0,
    this.likedByMe = false,
    this.replyCount = 0,
    this.replies = const [],
  });

  final String id;
  final String submitterId;
  final String submitterName;

  /// 类别
  final SuggestionCategory category;

  /// 标题
  final String title;

  /// 正文
  final String content;

  /// 状态
  final SuggestionStatus status;

  /// 提交时间
  final DateTime submittedAt;

  /// 是否匿名
  final bool isAnonymous;

  /// 点赞数
  final int likes;

  /// 我是否已点赞
  final bool likedByMe;

  /// 回复总数。列表接口只返回计数，不展开回复正文。
  final int replyCount;

  /// 回复列表（人事/管理层回复）
  final List<SuggestionReply> replies;

  Suggestion copyWith({
    SuggestionStatus? status,
    int? likes,
    bool? likedByMe,
    int? replyCount,
    List<SuggestionReply>? replies,
  }) {
    return Suggestion(
      id: id,
      submitterId: submitterId,
      submitterName: submitterName,
      category: category,
      title: title,
      content: content,
      status: status ?? this.status,
      submittedAt: submittedAt,
      isAnonymous: isAnonymous,
      likes: likes ?? this.likes,
      likedByMe: likedByMe ?? this.likedByMe,
      replyCount: replyCount ?? this.replyCount,
      replies: replies ?? this.replies,
    );
  }

  /// 服务端已按当前查看人的权限完成匿名脱敏，前端不得二次推断或改写。
  String get displayName =>
      submitterName.trim().isEmpty ? '匿名用户' : submitterName;
}

/// 建议回复
class SuggestionReply {
  const SuggestionReply({
    required this.id,
    required this.replier,
    required this.replierRole,
    required this.content,
    required this.repliedAt,
  });

  final String id;
  final String replier;
  final String replierRole;
  final String content;
  final DateTime repliedAt;
}
