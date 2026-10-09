// UtenStatusBadge - 状态徽章（用于工资条/报销/审批状态展示）
// 文档：docs/02-组件库/DocStatusBadge.md（单据状态列口径 + 本组件用法）；
// 配色档位见 docs/00-项目准则/08-主题与配色.md §2.5 与 ADR-169。
//
// 设计原则（2026-10-08 状态色改版）：深色实底 + 成套前景字，明暗两主题同一
// 实底（自带对比度）。琥珀档是唯一亮底深棕字。状态→档位由各页映射函数显式
// 决定（逐页独立口径），档位语义锚定见枚举各项注释。
//
// 表格单元格内的状态列不再用胶囊（2026-09-27 用户口径「胶囊背景去掉、
// 改成单元格背景色」）：用 [utenStatusBadgeCellColor] 铺整格底色，
// 文字交给 MasterDataTableView 的 cellColor 双向对比度约定（黑/白自适应
// + 正文字号），选中行的统一青绿高亮也不会再被胶囊底盖住。

import 'package:flutter/material.dart';

import 'uten_status_cell_color.dart';
import '../../core/theme/uten_tokens.dart';
import '../../shared/ai/page_context/ai_page_context.dart';

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
      TextStyle(fontSize: textSize, fontWeight: FontWeight.w700, height: 1.3);

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
      // 格内降级单行（2026-10-06 行高统一口径）：两行降级文本会把整行撑高，
      // 超出单行文本格的基线；超长状态词交给省略号 + 宿主列宽自动加宽。
      return Text(label, maxLines: 1, overflow: TextOverflow.ellipsis);
    }
    final colors = resolveStatusBadgeColors(type);
    final (padH, padV, textSize, iconSize) = _metrics(size);

    // ADR-150: a standalone pill is part of what the AI assistant can read
    // (label + shared tone). Status cells are covered by the table legend.
    return AiPageRegistrar(
      source: AiBadgeSource(
        label: label,
        tone: type.name,
        color: type.colorName,
      ),
      child: Container(
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
      ),
    );
  }
}

/// 徽章类型（决定配色）。档位语义锚定（ADR-169，全局一致；具体哪个状态用
/// 哪一档由各页业务流程自行决定，同页同现的状态必须互可区分）：
/// 深红=阻断/驳回 · 深绿=完成/就绪 · 亮琥珀=等待外部 · 深蓝=正在执行 ·
/// 深橙=风险中间态 · 青=第二等待档 · 深紫=部分就绪。
enum UtenStatusBadgeType {
  /// 深灰（草稿/未提交/已取消/已中止等中性终态）
  neutral,

  /// 深蓝（正在执行/加工中/已提交流转中）
  info,

  /// 深绿（完成/通过/已审/就绪可动手：可开工、可领、可下单）
  success,

  /// 亮琥珀（等待外部处理：等财务/等仓库/在途/等检查，无异常。
  /// 注意：**不能执行/被锁死不是等待**，那是 [danger]）
  warning,

  /// 深红（硬阻断/锁定不能往下/驳回/失败/异常/不合格/逾期/红冲）
  danger,

  /// 深橙（风险中间态：部分异常/短交待判定/临期——未死锁但需注意，
  /// 与 [danger] 相邻色相靠明度区分，别用于仅语义微差的两档）
  orange,

  /// 青（第二等待档：同页需区分两种「等别人」时用，如等财务 vs 等仓库发料）
  sky,

  /// 品红（分类强调，非语义状态：生产路线「持续生产」、分批等待等类别色，
  /// 与绿/蓝拉开色相——2026-09-18 用户口径「颜色取差别大的」）
  fuchsia,

  /// 紫(部分就绪：可部分下单/部分可领/部分齐套，与全就绪、等待的拉开——
  /// 2026-09-20 用户口径「部分物料可领和物料已备齐的颜色还是一样的」)
  violet,

  /// 深青绿（他方执行中：委外商加工中等/品牌特殊档）
  accent;

  /// 中文颜色名(ADR-150 状态图例; AI 读页面时用, 与 utenColorName 同一张色名表)。
  String get colorName => switch (this) {
    UtenStatusBadgeType.neutral => '灰',
    UtenStatusBadgeType.info => '蓝',
    UtenStatusBadgeType.success => '绿',
    UtenStatusBadgeType.warning => '黄',
    UtenStatusBadgeType.danger => '红',
    UtenStatusBadgeType.orange => '橙',
    UtenStatusBadgeType.sky => '青',
    UtenStatusBadgeType.fuchsia => '品红',
    UtenStatusBadgeType.violet => '紫',
    UtenStatusBadgeType.accent => '青绿',
  };
}

/// 徽章尺寸
enum UtenStatusBadgeSize { small, medium, large }
