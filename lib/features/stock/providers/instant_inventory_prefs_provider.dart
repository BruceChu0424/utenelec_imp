// 即时库存页偏好 Provider：「含不良品仓」开关，按账号服务端持久化。
// 实现：UtenPagePrefsNotifier 基类（lib/shared/providers/uten_page_prefs_notifier.dart），
// 三层策略（本地缓存即时渲染 → 登录后服务端同步 → 防抖 800ms 推送）全部继承，这里只声明序列化。
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../shared/providers/uten_page_prefs_notifier.dart';

class InstantInventoryPrefsNotifier extends UtenPagePrefsNotifier<bool> {
  /// 服务端偏好 key
  static const _prefKey = 'stock.instantInventory';

  @override
  String get prefKey => _prefKey;

  /// 保留旧缓存 key（迁移期兼容：旧值 "true"/"false" 本身是合法 JSON，decode 直接兼容）。
  @override
  String get cacheKey => 'instant_inventory_prefs_cache';

  /// 默认开 = 老系统口径（不良仓计入全部）。
  @override
  bool get defaultValue => true;

  @override
  bool? decode(Object? raw) {
    if (raw is bool) return raw;
    // 兼容 String 落库形态（后端允许任意 JSON value）
    if (raw is String) return raw != 'false';
    // 兼容 Map 包裹形态（早期实现曾以 {'includeDefective': bool} 写入）
    if (raw is Map && raw['includeDefective'] is bool) {
      return raw['includeDefective'] as bool;
    }
    return null;
  }

  @override
  Object? encode(bool state) => state;

  /// 切换「含不良品仓」（语义化入口，等同 update(v)）。
  void setIncludeDefective(bool v) => update(v);
}

final instantInventoryPrefsProvider =
    NotifierProvider<InstantInventoryPrefsNotifier, bool>(
      InstantInventoryPrefsNotifier.new,
    );
