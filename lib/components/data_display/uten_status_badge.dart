// UtenStatusBadge - 状态徽章（用于工资条/报销/审批状态展示）
// 文档：docs/02-组件库/DocStatusBadge.md（单据状态列口径 + 本组件用法）；
// 配色档位见 docs/00-项目准则/08-主题与配色.md。
//
// 设计原则：柔和语义底色（UtenColors.*Bg）+ 深档同色文字，胶囊圆角，无边框。
// 深色模式下自动切换为"半透明底色 + 亮档文字"，保证可读性。
//
// 表格单元格内的状态列不再用胶囊（2026-09-27 用户口径「胶囊背景去掉、
// 改成单元格背景色」）：用 [utenStatusBadgeCellColor] 铺整格底色，
// 文字交给 MasterDataTableView 的 cellColor 双向对比度约定（黑/白自适应
// + 正文字号），选中行的统一青绿高亮也不会再被胶囊底盖住。

import 'package:flutter/material.dart';

import 'uten_status_cell_color.dart';
import '../../core/theme/uten_tokens.dart';

/// Uten 状态徽章
///
/// 用于工资条状态（待审核/已发布/已查看/已下载）、
/// 报销状态（草稿/已提交/已审批/已驳回/已打款）等。
class UtenStatusBadge extends StatelessWidget {
  const UtenStatusBadge({
    super.key,
    required this.label,
    required this.type,
    this.icon,
    this.size = UtenStatusBadgeSize.medium,
  });

  final String label;
  final UtenStatusBadgeType type;
  final IconData? icon;
  final UtenStatusBadgeSize size;

  /// 各尺寸的水平/垂直内边距、字号、图标尺寸(徽章与 [measureWidth] 同一份)。
  static (double, double, double, double) _metrics(UtenStatusBadgeSize size) =>
      switch (size) {
        UtenStatusBadgeSize.small => (8.0, 2.0, 11.0, 12.0),
        UtenStatusBadgeSize.medium => (10.0, 3.0, 12.0, 13.0),
        UtenStatusBadgeSize.large => (12.0, 5.0, 13.0, 14.0),
      };

  /// 图标与文字的间距。
  static const double _iconGap = 4;

  static TextStyle _labelStyle(double textSize) =>
      TextStyle(fontSize: textSize, fontWeight: FontWeight.w600, height: 1.3);

  /// 不带图标的徽章完整显示 [label] 所需的宽度(按当前字体、字号档与界面
  /// 缩放实测)。
  ///
  /// 给徽章预留固定槽位时用它，不要手写像素：不同语言、字号档下文字宽度不同，
  /// 写死的宽度会把标签截成省略号。
  static double measureWidth(
    BuildContext context,
    String label, {
    UtenStatusBadgeSize size = UtenStatusBadgeSize.medium,
  }) {
    final (padH, _, textSize, _) = _metrics(size);
    final painter = TextPainter(
      text: TextSpan(
        text: label,
        style: DefaultTextStyle.of(context).style.merge(_labelStyle(textSize)),
      ),
      textDirection: Directionality.of(context),
      textScaler: MediaQuery.textScalerOf(context),
      maxLines: 1,
    )..layout();
    final textWidth = painter.width;
    painter.dispose();
    return (padH * 2 + textWidth).ceilToDouble();
  }

  @override
  Widget build(BuildContext context) {
    if (UtenStatusCellScope.isCell(context)) {
      return Text(label, maxLines: 2, overflow: TextOverflow.ellipsis);
    }
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final colors = resolveStatusBadgeColors(type, isDark);
    final (padH, padV, textSize, iconSize) = _metrics(size);

    return Container(
      padding: EdgeInsets.symmetric(horizontal: padH, vertical: padV),
      decoration: BoxDecoration(
        color: colors.$1,
        borderRadius: BorderRadius.circular(UtenRadius.pill),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[
            Icon(icon, size: iconSize, color: colors.$2),
            const SizedBox(width: _iconGap),
          ],
          Flexible(
            child: Tooltip(
              message: label,
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: _labelStyle(textSize).copyWith(color: colors.$2),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 徽章类型（决定配色）
enum UtenStatusBadgeType {
  /// 中性灰（默认/草稿）
  neutral,

  /// 信息蓝
  info,

  /// 成功绿（已审批/已发布）
  success,

  /// 警告黄（待处理/审核中）
  warning,

  /// 危险红（驳回/失败）
  danger,

  /// 品红（分类强调，非语义状态：生产路线「持续生产」等类别色，
  /// 与绿/蓝拉开色相——2026-09-18 用户口径「颜色取差别大的」）
  fuchsia,

  /// 紫(部分就绪：车间任务「部分物料可领」，与全备齐的蓝、等待的琥珀拉开——
  /// 2026-09-20 用户口径「部分物料可领和物料已备齐的颜色还是一样的」)
  violet,

  /// 品牌青绿（已查看/特殊状态）
  accent,
}

/// 徽章尺寸
enum UtenStatusBadgeSize { small, medium, large }
