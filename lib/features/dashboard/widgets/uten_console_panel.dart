// 工作台「任务控制台」外观件（2026-09-12）。
//
// 用户要求工作台的「今日概览」「待办任务」**不要再是一堆卡片**，要「更好看、更酷炫、
// 更高级、很科幻」。第一版只把卡片换成了带细线的格子，用户反馈「也不是很好看、
// 没有啥特别的」——问题在于**没有一个记得住的视觉主角**。这一版补上。
//
// ## 四个「主角」
//
// 1. **HUD 角标**：四角的直角括号。仪器面板最省事也最有效的识别符——一眼就不像
//    普通业务卡片；纯线条，不占对比度、不干扰阅读。
// 2. **顶边光线**：上沿一条两端淡出的 1px 渐变高光（玻璃边缘那一下）。成本极低，
//    是面板"有厚度、有材质"的关键。
// 3. **扫描光带**：一条很淡的光带横向掠过。"科幻"的那一下。
//    **一次性播放，不循环**——进工作台时扫一次、数据刷新时再扫一次
//    （范式同 UtenLivePulseDot 的 pulse）。循环动画会一直烧电，也过不了
//    准则 07 §七 对循环动画的门槛，更会让任何 pumpAndSettle 永远停不下来。
// 4. **巨型数字水印**（[UtenGhostNumeral]）：把数值本身极淡地重复画在格子背景里。
//
// ## 为什么不是霓虹
//
// 「科幻」在消费类产品里通常等于高饱和霓虹 + 强发光。但本系统是车间、仓库、财务每天
// 盯着用的 ERP，项目自己的准则里有适老化基线、字号可调与 WCAG 对比度要求
// （docs/00-项目准则/13-适老化UX基线.md、04-字体与字号可调.md）。霓虹会直接违反
// 这些硬约束——字都看不清的"炫"是负分。
//
// 所以全部装饰**只在背景层**，前景文字一律实色高对比；"高级感"由结构、细节与排版
// 反差承担，不由颜色饱和度承担。
//
// ## 无障碍与性能
//
// - `MediaQuery.disableAnimationsOf` 为真时扫描光带整条不渲染，其余静态装饰保留。
//   动效不承载任何信息。
// - 全部装饰在**一个** CustomPainter 里画完，不叠多层半透明 Container；
//   `RepaintBoundary` 隔离，扫描光带重绘不牵连内容层。
// - 不设固定高度：字号放大到最大档时面板自然长高，不裁切。
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../core/theme/uten_tokens.dart';

/// 控制台面板：仪器底色 + HUD 角标 + 顶边光线 + 慢速扫描光带。
///
/// 「今日概览」「待办任务」共用这一个外壳，保证两块看起来是同一台仪器上的两个区域。
class UtenConsolePanel extends StatefulWidget {
  const UtenConsolePanel({
    super.key,
    required this.child,
    this.accentColor,
    this.padding = const EdgeInsets.all(UtenSpacing.s16),
    this.sweepTrigger = 0,
  });

  final Widget child;

  /// 角标、网格与辉光的取色；缺省用主题主色。
  final Color? accentColor;

  final EdgeInsetsGeometry padding;

  /// 扫描光带的播放触发器：**值一变就重扫一次**（首帧也扫一次）。
  /// 调用方传数据版本号/采样计数即可；传固定值则只在首次挂载时扫。
  /// 不循环——见文件头第 3 条。
  final int sweepTrigger;

  @override
  State<UtenConsolePanel> createState() => _UtenConsolePanelState();
}

class _UtenConsolePanelState extends State<UtenConsolePanel>
    with SingleTickerProviderStateMixin {
  // 1.6 秒扫完：慢到像仪器自检扫过，又不至于让人等着它走完。
  late final AnimationController _sweep = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1600),
  );

  @override
  void initState() {
    super.initState();
    // 首帧不抢绘制：等第一帧画完再扫，避免和页面入场动画抢时间片。
    WidgetsBinding.instance.addPostFrameCallback((_) => _play());
  }

  @override
  void didUpdateWidget(covariant UtenConsolePanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.sweepTrigger != widget.sweepTrigger) _play();
  }

  void _play() {
    if (!mounted) return;
    if (MediaQuery.disableAnimationsOf(context)) return;
    _sweep.forward(from: 0);
  }

  @override
  void dispose() {
    _sweep.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final dark = theme.brightness == Brightness.dark;
    final accent = widget.accentColor ?? theme.colorScheme.primary;
    // 浅色主题下不能真的用深色面板（整页会割裂），改用极浅的中性面板 + 更淡的装饰；
    // 深色主题才是"仪表盘"本色。两套各自独立调对比度，不做「浅色反色成深色」。
    final surface = dark
        ? Color.alphaBlend(
            accent.withValues(alpha: 0.07),
            theme.colorScheme.surfaceContainerHighest,
          )
        : Color.alphaBlend(
            accent.withValues(alpha: 0.04),
            theme.colorScheme.surface,
          );
    final radius = BorderRadius.circular(UtenRadius.control + 6);

    return RepaintBoundary(
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: surface,
          borderRadius: radius,
          border: Border.all(
            color: dark
                ? accent.withValues(alpha: 0.22)
                : theme.colorScheme.outlineVariant,
          ),
          boxShadow: UtenElevation.low(isDark: dark),
        ),
        child: ClipRRect(
          borderRadius: radius,
          child: AnimatedBuilder(
            animation: _sweep,
            builder: (context, child) => CustomPaint(
              painter: _ConsoleBackdropPainter(
                accent: accent,
                dark: dark,
                // 静止（0 或 1）时整条不画：不留一道停在边上的亮带。
                sweep: _sweep.isAnimating ? _sweep.value : null,
              ),
              child: child,
            ),
            child: Padding(padding: widget.padding, child: widget.child),
          ),
        ),
      ),
    );
  }
}

/// 面板背景：网格 → 角落辉光 → 扫描光带 → 顶边光线 → HUD 角标。
/// 顺序即层次，后画的压在先画的上面。
class _ConsoleBackdropPainter extends CustomPainter {
  const _ConsoleBackdropPainter({
    required this.accent,
    required this.dark,
    required this.sweep,
  });

  final Color accent;
  final bool dark;

  /// 扫描光带进度 0..1；null = 不画（静止态、reduced-motion）。
  final double? sweep;

  /// 网格间距。太密会摩尔纹、太疏就没有仪器感。
  static const double _grid = 26;

  /// HUD 角标的臂长。
  static const double _bracket = 14;

  @override
  void paint(Canvas canvas, Size size) {
    final gridAlpha = dark ? 0.06 : 0.04;
    final glowAlpha = dark ? 0.18 : 0.06;

    final grid = Paint()
      ..color = accent.withValues(alpha: gridAlpha)
      ..strokeWidth = 1;
    for (double x = _grid; x < size.width; x += _grid) {
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), grid);
    }
    for (double y = _grid; y < size.height; y += _grid) {
      canvas.drawLine(Offset(0, y), Offset(size.width, y), grid);
    }

    // 左上主辉光 + 右下副辉光：给面板一个光源方向，避免平板一片。
    final radius = math.max(size.width, size.height) * 0.85;
    canvas.drawRect(
      Offset.zero & size,
      Paint()
        ..shader =
            RadialGradient(
              colors: [
                accent.withValues(alpha: glowAlpha),
                accent.withValues(alpha: 0),
              ],
            ).createShader(
              Rect.fromCircle(
                center: Offset(size.width * 0.06, 0),
                radius: radius,
              ),
            ),
    );
    canvas.drawRect(
      Offset.zero & size,
      Paint()
        ..shader =
            RadialGradient(
              colors: [
                accent.withValues(alpha: glowAlpha * 0.45),
                accent.withValues(alpha: 0),
              ],
            ).createShader(
              Rect.fromCircle(
                center: Offset(size.width, size.height),
                radius: radius * 0.65,
              ),
            ),
    );

    // 扫描光带：软边竖向光带从左掠到右。宽度取面板的 1/4，强度压到辉光的一半——
    // 要的是"余光里有东西在动"，不是"有个亮块在跑"。
    final progress = sweep;
    if (progress != null) {
      final band = size.width * 0.25;
      // -band → width+band：光带完整进出，不在边缘突然出现/消失。
      final x = -band + (size.width + band * 2) * progress;
      final rect = Rect.fromLTWH(x, 0, band, size.height);
      canvas.drawRect(
        rect,
        Paint()
          ..shader = LinearGradient(
            colors: [
              accent.withValues(alpha: 0),
              accent.withValues(alpha: dark ? 0.10 : 0.045),
              accent.withValues(alpha: 0),
            ],
          ).createShader(rect),
      );
    }

    // 顶边光线：两端淡出的 1px 高光，玻璃边缘那一下。面板"有材质"全靠它。
    final top = Rect.fromLTWH(0, 0, size.width, 1);
    canvas.drawRect(
      top,
      Paint()
        ..shader = LinearGradient(
          colors: [
            accent.withValues(alpha: 0),
            accent.withValues(alpha: dark ? 0.85 : 0.45),
            accent.withValues(alpha: 0),
          ],
        ).createShader(top),
    );

    // HUD 角标：四角直角括号。纯线条，不占对比度，但一眼就"是台仪器"。
    final bracket = Paint()
      ..color = accent.withValues(alpha: dark ? 0.62 : 0.42)
      ..strokeWidth = 1.6
      ..strokeCap = StrokeCap.round
      ..style = PaintingStyle.stroke;
    const inset = 7.0;
    void corner(Offset origin, double dx, double dy) {
      canvas.drawLine(origin, origin.translate(_bracket * dx, 0), bracket);
      canvas.drawLine(origin, origin.translate(0, _bracket * dy), bracket);
    }

    corner(const Offset(inset, inset), 1, 1);
    corner(Offset(size.width - inset, inset), -1, 1);
    corner(Offset(inset, size.height - inset), 1, -1);
    corner(Offset(size.width - inset, size.height - inset), -1, -1);
  }

  @override
  bool shouldRepaint(_ConsoleBackdropPainter oldDelegate) =>
      oldDelegate.accent != accent ||
      oldDelegate.dark != dark ||
      oldDelegate.sweep != sweep;
}

/// 控制台区段标题：左侧发光短条 + 小字大字距标题 + 右侧插槽。
///
/// 与 UtenSectionHeader 的区别：那个是普通页面的章节标题（正常字号、实色条），
/// 这个是仪器面板的刻度标签，刻意压小、放开字距，把视觉重量让给数据本身。
class UtenConsoleHeader extends StatelessWidget {
  const UtenConsoleHeader({
    super.key,
    required this.title,
    this.subtitle,
    this.trailing,
    this.accentColor,
  });

  final String title;
  final String? subtitle;
  final Widget? trailing;
  final Color? accentColor;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final accent = accentColor ?? theme.colorScheme.primary;
    return Row(
      children: [
        Container(
          width: 3,
          height: 20,
          decoration: BoxDecoration(
            color: accent,
            borderRadius: BorderRadius.circular(2),
            boxShadow: [
              BoxShadow(color: accent.withValues(alpha: 0.6), blurRadius: 10),
            ],
          ),
        ),
        const SizedBox(width: UtenSpacing.s8),
        Flexible(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                title,
                style: theme.textTheme.titleSmall?.copyWith(
                  fontWeight: FontWeight.w800,
                  letterSpacing: 1.2,
                ),
              ),
              if (subtitle != null && subtitle!.isNotEmpty)
                Text(
                  subtitle!,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                    letterSpacing: 0.3,
                  ),
                ),
            ],
          ),
        ),
        if (trailing != null) ...[
          const SizedBox(width: UtenSpacing.s8),
          trailing!,
        ],
      ],
    );
  }
}

/// 巨型数字水印：把数值本身极淡地重复画在格子背景里，被格子裁切。
///
/// 这是高端仪表盘/杂志排版常用的一招——同一个数字出现两次（一次给人读、一次当图形），
/// 格子立刻有了"被设计过"的分量，而且**不引入任何假数据**（不像画条假趋势线）。
/// 透明度压到 7%/4.5%，纯背景层，不影响前景对比度。
///
/// **刻意用 CustomPainter 画，不用 Text**：它是纯装饰，同一个数字在 widget 树里出现两次的话
/// 读屏会把数值念两遍、长按选择会选到底纹、`find.text` 也会一个数匹配到两个 widget。
/// 画出来的字不进语义树、不进选择域，只当图形。顺带也天然免疫系统字号放大
/// ——它不该随字号一起长大把格子挤爆。
class UtenGhostNumeral extends StatelessWidget {
  const UtenGhostNumeral({super.key, required this.text, required this.color});

  final String text;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    return IgnorePointer(
      child: CustomPaint(
        painter: _GhostNumeralPainter(
          text: text,
          color: color.withValues(alpha: dark ? 0.07 : 0.045),
          textDirection: Directionality.of(context),
        ),
      ),
    );
  }
}

class _GhostNumeralPainter extends CustomPainter {
  _GhostNumeralPainter({
    required this.text,
    required this.color,
    required this.textDirection,
  });

  final String text;
  final Color color;
  final TextDirection textDirection;

  /// 偏右下并超出一点：被格子裁掉一角，才像"透出来的底纹"而不是另一个数字。
  static const Alignment _alignment = Alignment(1.35, 0.7);

  @override
  void paint(Canvas canvas, Size size) {
    if (text.isEmpty || size.isEmpty) return;
    final painter = TextPainter(
      text: TextSpan(
        text: text,
        style: TextStyle(
          fontSize: 88,
          height: 1,
          fontWeight: FontWeight.w900,
          color: color,
          fontFeatures: const [FontFeature.tabularFigures()],
        ),
      ),
      textDirection: textDirection,
      maxLines: 1,
    )..layout();
    // 与 Align 同一套算法：alongOffset 把 (size - textSize) 的余量按 alignment 分配，
    // 算出来就是 Align 会给的左上角坐标。
    final offset = _alignment.alongOffset(
      Offset(size.width - painter.width, size.height - painter.height),
    );
    canvas.save();
    canvas.clipRect(Offset.zero & size);
    painter.paint(canvas, offset);
    canvas.restore();
    painter.dispose();
  }

  @override
  bool shouldRepaint(_GhostNumeralPainter oldDelegate) =>
      oldDelegate.text != text ||
      oldDelegate.color != color ||
      oldDelegate.textDirection != textDirection;
}
