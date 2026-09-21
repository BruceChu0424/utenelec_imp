// 「进行中」黄色数量徽章 —— 全站三种计数呈现形态里的「在办型」那一种。
//
// 口径(docs/00-项目准则/14-徽章与计数口径.md, 2026-09-21 由两形态扩成三形态):
//   · UtenNotificationBadge(红) = 「轮到我动手, 不动会出事」: 待审 / 待确认 /
//     待收货 / 待出库 / 待检 / 被驳回 / 超期 / 异常 / 等待物料 / 本人草稿。
//   · UtenInProgressBadge(本组件, 黄) = 「已经在办、球还在流程里滚着, 但还没完,
//     现在不用我动手」: 生产中 / 加工中 / 执行中 / 在途 / 等待财务审核 /
//     财务已通过待执行 / 等待检查结果。
//   · UtenCountSuffix(中性括号) = 「已经结束的、历史的、全部的、纯浏览的集合」。
//
// 判定顺序只有两问: ① 这个数变大时有人在等我干活吗? 是 → 红。
// ② 不是 → 这批东西还在流程里没结束吗? 是 → 黄; 已结束/纯浏览 → 括号。
//
// 与红徽章一样 **会被上层容器逐级累加**, 但走的是另一张注册表
// (lib/shared/badges/in_progress_badge_registry.dart), 两条链互不相干:
// 红数字回答「我还欠多少活」, 黄数字回答「手上还有多少在跑」。
//
// 形态与 UtenNotificationBadge 严格同构(高度恒等于 size、minWidth=size 保证
// 单数字是正圆、多位数横向变宽呈胶囊、>99 显 99+、count<=0 整个不渲染),
// 这样卡片右上角「黄在左、红在右」并排时两枚一样高、基线对齐。
// 配色也与红色那枚同构: 深色实底 + 白字加粗, 只是底色换成深琥珀
// (2026-09-21 用户口径「数字加粗变白, 黄色再深点」; 白字要读得清, 底色就必须
//  压到 amber-700, 见 UtenColors.warningStrong 的注释)。

import 'package:flutter/material.dart';

import '../../core/theme/uten_colors.dart';

class UtenInProgressBadge extends StatelessWidget {
  const UtenInProgressBadge({
    super.key,
    required this.count,
    this.size = 16,
    this.showLabel = false,
  });

  /// 在办数量; <= 0 不渲染(不留黄色的 0, 也不把「未知」伪装成 0)。
  final int count;

  /// 徽章直径(单数字时即圆的直径)。
  final double size;

  /// true = 横向加宽内边距、字号 11(卡片/hub 角标用); false = 紧凑 10(分段标签用)。
  final bool showLabel;

  @override
  Widget build(BuildContext context) {
    if (count <= 0) return const SizedBox.shrink();

    final label = count > 99 ? '99+' : count.toString();

    return SizedBox(
      height: size,
      child: Container(
        padding: EdgeInsets.symmetric(horizontal: showLabel ? 8 : (size / 4)),
        constraints: BoxConstraints(minWidth: size),
        decoration: BoxDecoration(
          // 深琥珀实底 + 白字(2026-09-21 用户口径「加粗变白, 黄色再深点」)。
          // 明暗两档同一个底: 这是自带对比度的实心药丸, 不吃表面色。
          color: UtenColors.warningStrong,
          borderRadius: BorderRadius.circular(size / 2),
        ),
        alignment: Alignment.center,
        child: Text(
          label,
          textAlign: TextAlign.center,
          maxLines: 1,
          style: TextStyle(
            color: Colors.white,
            fontSize: showLabel ? 11 : 10,
            fontWeight: FontWeight.w800,
          ),
        ),
      ),
    );
  }
}
