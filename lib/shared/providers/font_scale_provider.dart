// 字号档位 Provider（自动 + 更小/小/标准/大/超大/特大/巨大/极大）
// 文档：docs/00-项目准则/04-字体与字号可调.md
//
// 2026-09-20 起档位因子是**整体缩放**倍率（core/responsive/display_zoom.dart）：
// 文字、图标、卡片、间距一起等比变化，不再只乘 textScaler（文字大了容器不跟）。
// 手机（窗口宽 < 600）沿用只放大文字。
//
// 2026-09-24 起档位按屏幕容量动态提供（core/responsive/display_capacity.dart）：
// 放得下才出现，每台机器选项数不同；默认「自动」，系统缩放开得大时自动收小一档。

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'shared_providers.dart';

/// 字号档位
///
/// 因子经 UtenDisplayZoomBox 作为整体缩放倍率生效（≥600 宽）；设置页只列出
/// 当前窗口放得下的档（UtenDisplayCapacity.maxFontFactor），手动档超出上限时按上限生效。
/// 老版本持久化的 small/medium/large/xLarge/xxLarge 键与因子保持不变。
enum FontScale {
  xSmall(0.75, 'xSmall', '更小'),
  small(0.85, 'small', '小'),
  medium(1.0, 'medium', '标准'),
  large(1.15, 'large', '大'),
  xLarge(1.3, 'xLarge', '超大'),
  xxLarge(1.5, 'xxLarge', '特大'),
  huge(1.75, 'huge', '巨大'),
  giant(2.0, 'giant', '极大');

  const FontScale(this.factor, this.persistKey, this.label);

  /// 相对基准的缩放因子
  final double factor;

  /// 持久化 key
  final String persistKey;

  /// 设置页标签
  final String label;

  /// 全部档位因子（自动档从中挑推荐值）
  static final List<double> ladder = [for (final s in values) s.factor];

  /// 因子对应的档位（找不到返回 null）。
  static FontScale? ofFactor(double factor) {
    for (final s in values) {
      if ((s.factor - factor).abs() < 1e-9) return s;
    }
    return null;
  }
}

/// 用户的字号选择：自动（按屏幕推荐）或手动档位。
class FontScaleChoice {
  const FontScaleChoice.auto() : manual = null;
  const FontScaleChoice.manual(FontScale this.manual);

  /// 手动档位；null = 自动。
  final FontScale? manual;

  bool get isAuto => manual == null;

  /// 交给整体缩放容器的因子；null = 自动。
  double? get factor => manual?.factor;

  @override
  bool operator ==(Object other) =>
      other is FontScaleChoice && other.manual == manual;

  @override
  int get hashCode => manual.hashCode;
}

class FontScaleNotifier extends Notifier<FontScaleChoice> {
  static const _key = 'fontScale';
  static const _autoKey = 'auto';

  @override
  FontScaleChoice build() {
    final prefs = ref.read(sharedPreferencesProvider);
    final saved = prefs.getString(_key);
    for (final s in FontScale.values) {
      if (s.persistKey == saved) return FontScaleChoice.manual(s);
    }
    // 未设置过（或存的是 auto）：按屏幕自动。
    return const FontScaleChoice.auto();
  }

  Future<void> set(FontScaleChoice choice) async {
    await ref
        .read(sharedPreferencesProvider)
        .setString(_key, choice.manual?.persistKey ?? _autoKey);
    state = choice;
  }
}

final fontScaleProvider = NotifierProvider<FontScaleNotifier, FontScaleChoice>(
  FontScaleNotifier.new,
);
