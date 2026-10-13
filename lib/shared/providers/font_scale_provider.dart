// 个人界面大小：所有设备整体缩放，默认 100%，本机按真实操作者记忆。
// 文档：docs/00-项目准则/04-字体与字号可调.md。

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'session_provider.dart';
import 'shared_providers.dart';

/// 字号档位
///
/// 因子经 UtenDisplayZoomBox 在所有屏幕作为整体缩放倍率生效；设置页提供
/// 85%～200%，旧 75% 只保留兼容恢复，窗口变化不降低用户选择。
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

  /// 新选择从 85% 起；旧 75% 仍能恢复且可显示为兼容档。
  static final List<FontScale> selectable = [
    for (final s in values)
      if (s != xSmall) s,
  ];

  /// 因子对应的档位（找不到返回 null）。
  static FontScale? ofFactor(double factor) {
    for (final s in values) {
      if ((s.factor - factor).abs() < 1e-9) return s;
    }
    return null;
  }
}

/// 用户的界面大小：自动(标准 100%)或手动档位。
class FontScaleChoice {
  const FontScaleChoice.auto() : manual = null;
  const FontScaleChoice.manual(FontScale this.manual);

  /// 手动档位；null = 自动。
  final FontScale? manual;

  bool get isAuto => manual == null;

  /// 交给整体缩放容器的因子；null = 自动。
  double? get factor => manual?.factor;

  static FontScaleChoice? fromPersistKey(String? key) {
    if (key == 'auto') return const FontScaleChoice.auto();
    for (final scale in FontScale.values) {
      if (scale.persistKey == key) return FontScaleChoice.manual(scale);
    }
    return null;
  }

  @override
  bool operator ==(Object other) =>
      other is FontScaleChoice && other.manual == manual;

  @override
  int get hashCode => manual.hashCode;
}

/// 个人偏好归属真实操作者，代操作不改变被模拟员工的设置。
/// 可单独 override，独立组件测试不需要启动登录/令牌恢复链路。
final fontScaleOwnerProvider = Provider<String?>((ref) {
  return ref.watch(
    sessionProvider.select(
      (session) => session.status == AuthStatus.authenticated
          ? (session.actor ?? session.user)?.id
          : null,
    ),
  );
});

/// 本机按账号隔离；旧无主键只迁移给第一个真实登录账号。
class FontScalePreferences {
  FontScalePreferences(this.preferences);

  final SharedPreferences preferences;
  static const legacyKey = 'fontScale';
  static const migrationKey = 'fontScale.legacyMigration';
  String? _claimedMigration;
  Future<void> _pendingWrites = Future<void>.value();

  static String keyFor(String userId) => 'fontScale.user.$userId';

  FontScaleChoice read(String userId) {
    final saved = FontScaleChoice.fromPersistKey(
      preferences.getString(keyFor(userId)),
    );
    var record = preferences.getString(migrationKey) ?? _claimedMigration;
    if (record == null) {
      final legacy = preferences.getString(legacyKey);
      if (FontScaleChoice.fromPersistKey(legacy) == null) {
        return saved ?? const FontScaleChoice.auto();
      }
      // 同一条记录同时保存归属和初值，避免部分迁移后把旧值分给第二人。
      record = jsonEncode({'owner': userId, 'choice': legacy});
      _claimedMigration = record;
      unawaited(_persistMigration(record));
    }
    if (saved != null) return saved;
    try {
      final decoded = jsonDecode(record);
      if (decoded is Map && decoded['owner'] == userId) {
        return FontScaleChoice.fromPersistKey(decoded['choice'] as String?) ??
            const FontScaleChoice.auto();
      }
    } on FormatException {
      // 损坏的迁移记录也不回读全局值，避免其他账号继承旧人的偏好。
    } on TypeError {
      // 同上。
    }
    return const FontScaleChoice.auto();
  }

  Future<void> _persistMigration(String record) async {
    try {
      if (!await preferences.setString(migrationKey, record)) {
        debugPrint('界面大小偏好迁移未保存；本次仍按账号隔离。');
      }
    } catch (_) {
      debugPrint('界面大小偏好迁移未保存；本次仍按账号隔离。');
    }
  }

  /// 按选择次序落盘，旧写入不能在新选择之后覆盖持久化值。
  Future<void> write(String userId, FontScaleChoice choice) {
    final write = _pendingWrites.then((_) async {
      final saved = await persistChoice(
        keyFor(userId),
        choice.manual?.persistKey ?? 'auto',
      );
      if (!saved) throw StateError('界面大小偏好未能保存');
    });
    _pendingWrites = write.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    return write;
  }

  @protected
  Future<bool> persistChoice(String key, String value) =>
      preferences.setString(key, value);
}

final fontScalePreferencesProvider = Provider<FontScalePreferences>((ref) {
  return FontScalePreferences(ref.watch(sharedPreferencesProvider));
});

class FontScaleNotifier extends Notifier<FontScaleChoice> {
  var _revision = 0;
  var _disposed = false;

  @override
  FontScaleChoice build() {
    _revision++;
    _disposed = false;
    ref.onDispose(() {
      _disposed = true;
      _revision++;
    });
    final owner = ref.watch(fontScaleOwnerProvider);
    final preferences = ref.watch(fontScalePreferencesProvider);
    return owner == null
        ? const FontScaleChoice.auto()
        : preferences.read(owner);
  }

  Future<void> set(FontScaleChoice choice) async {
    final owner = ref.read(fontScaleOwnerProvider);
    if (owner == null) return;
    final revision = ++_revision;
    await ref.read(fontScalePreferencesProvider).write(owner, choice);
    // 写入只属于开始操作的账号；换账号/登出/更新选择后的迟到结果不覆盖界面。
    if (!_disposed &&
        revision == _revision &&
        ref.read(fontScaleOwnerProvider) == owner) {
      state = choice;
    }
  }
}

final fontScaleProvider = NotifierProvider<FontScaleNotifier, FontScaleChoice>(
  FontScaleNotifier.new,
);
