// 字号档位 Provider（小/中/大/超大）
// 文档：docs/00-项目准则/04-字体与字号可调.md

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'shared_providers.dart';

/// 字号档位
///
/// 通过乘以缩放因子应用到 textTheme：
/// - small: 0.85
/// - medium: 1.0（默认）
/// - large: 1.15
/// - xLarge: 1.3
enum FontScale {
  small(0.85, 'small'),
  medium(1.0, 'medium'),
  large(1.15, 'large'),
  xLarge(1.3, 'xLarge');

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
