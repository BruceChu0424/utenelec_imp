// 庆典粒子 / 彩屑动画场（纯 UI）。
// 文档：docs/00-项目准则/06-动画规范.md（循环动画按性能档关闭；控制器 dispose）。
//
// 分层：位于 components/，不依赖任何 feature / provider。是否启用循环动画由调用方
// 传入 animated（一般 = !performanceProvider.isLite），lite 档渲染静态散点。

import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../core/theme/uten_anim.dart';

/// 庆典彩屑粒子场：从顶部缓缓飘落的彩色碎片 + 轻微旋转。
///
/// [animated] 为 false（性能档 lite）时只画一帧静态散点，不创建循环控制器。
/// 控制器随 widget 卸载 dispose。
class CelebrationParticleField extends StatefulWidget {
  const CelebrationParticleField({
    super.key,
    this.animated = true,
    this.particleCount = 20,
    this.colors = const [
      Color(0xFFF43F5E),
      Color(0xFFF59E0B),
      Color(0xFF14B8A6),
      Color(0xFF8B5CF6),
      Color(0xFF38BDF8),
      Color(0xFFEC4899),
    ],
  });

  /// 是否启用循环动画（lite 档传 false）。
  final bool animated;

  /// 粒子数量。
  final int particleCount;

  /// 彩屑配色（循环取用）。
  final List<Color> colors;

  @override
  State<CelebrationParticleField> createState() =>
      _CelebrationParticleFieldState();
}

class _CelebrationParticleFieldState extends State<CelebrationParticleField>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final List<_Particle> _particles;

  @override
  void initState() {
    super.initState();
    final rnd = math.Random(20260806);
    _particles = List.generate(widget.particleCount, (i) {
      return _Particle(
        x: rnd.nextDouble(),
        y0: rnd.nextDouble(),
        fall: 0.18 + rnd.nextDouble() * 0.30, // 一个循环下落幅度
        drift: 0.02 + rnd.nextDouble() * 0.06,
        phase: rnd.nextDouble(),
        spin: 0.4 + rnd.nextDouble() * 0.9,
        radius: 3.5 + rnd.nextDouble() * 4.5,
        color: widget.colors[i % widget.colors.length],
      );
    });
    // 循环时长以 UtenAnim.slow 为基准（动画规范：不写裸 Duration）。
    _controller = AnimationController(
      vsync: this,
      duration: UtenAnim.slow * 8,
    );
    if (widget.animated) {
      _controller.repeat();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.animated) {
      return CustomPaint(
        size: Size.infinite,
        painter: _ConfettiPainter(_particles, 0.5),
      );
    }
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, _) => CustomPaint(
        size: Size.infinite,
        painter: _ConfettiPainter(_particles, _controller.value),
      ),
    );
  }
}

class _Particle {
  const _Particle({
    required this.x,
    required this.y0,
    required this.fall,
    required this.drift,
    required this.phase,
    required this.spin,
    required this.radius,
    required this.color,
  });

  final double x; // 横向基准（0..1）
  final double y0; // 纵向起点（0..1）
  final double fall; // 一个循环内的下落幅度
  final double drift; // 横向漂移幅度
  final double phase; // 相位偏移（让粒子错峰）
  final double spin; // 旋转速度
  final double radius; // 碎片尺寸
  final Color color;
}

class _ConfettiPainter extends CustomPainter {
  _ConfettiPainter(this.particles, this.t);

  final List<_Particle> particles;
  final double t; // 0..1 循环进度

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint();
    for (final p in particles) {
      final y = (p.y0 + t * p.fall) % 1.0;
      final x = (p.x + math.sin((t + p.phase) * 2 * math.pi) * p.drift) % 1.0;
      final cx = x * size.width;
      final cy = y * size.height;
      final rot = (t * p.spin + p.phase) * 2 * math.pi;
      canvas.save();
      canvas.translate(cx, cy);
      canvas.rotate(rot);
      paint.color = p.color.withValues(alpha: 0.85);
      final w = p.radius * 1.5;
      final h = p.radius * 0.8;
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromCenter(center: Offset.zero, width: w, height: h),
          Radius.circular(h / 2),
        ),
        paint,
      );
      canvas.restore();
    }
  }

  @override
  bool shouldRepaint(covariant _ConfettiPainter oldDelegate) =>
      oldDelegate.t != t;
}
