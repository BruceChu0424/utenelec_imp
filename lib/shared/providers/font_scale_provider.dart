// 字号档位 Provider（小/标准/大/超大/超超大）
// 文档：docs/00-项目准则/04-字体与字号可调.md
//
// 2026-09-20 起档位因子是**整体缩放**倍率（core/responsive/display_zoom.dart）：
// 文字、图标、卡片、间距一起等比变化，不再只乘 textScaler（文字大了容器不跟）。
// 手机（窗口宽 < 600）沿用只放大文字。

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'shared_providers.dart';

/// 字号档位
///
/// 因子经 UtenDisplayZoomBox 作为整体缩放倍率生效（≥600 宽）：
/// - small: 0.85
/// - medium: 1.0（默认，UI 标签「标准」）
/// - large: 1.15
/// - xLarge: 1.3
/// - xxLarge: 1.5
enum FontScale {
  small(0.85, 'small'),
  medium(1.0, 'medium'),
  large(1.15, 'large'),
  xLarge(1.3, 'xLarge'),
  xxLarge(1.5, 'xxLarge');

  const FontScale(this.factor, this.persistKey);

  /// 相对基准的缩放因子
  final double factor;

  /// 持久化 key
  final String persistKey;
}

class FontScaleNotifier extends Notifier<FontScale> {
  static const _key = 'fontScale';

  @override
  FontScale build() {
    final prefs = ref.read(sharedPreferencesProvider);
    final saved = prefs.getString(_key);
    return FontScale.values.firstWhere(
      (s) => s.persistKey == saved,
      orElse: () => FontScale.medium,
    );
  }

  Future<void> set(FontScale scale) async {
    await ref.read(sharedPreferencesProvider).setString(_key, scale.persistKey);
    state = scale;
  }
}

final fontScaleProvider = NotifierProvider<FontScaleNotifier, FontScale>(
  FontScaleNotifier.new,
);
