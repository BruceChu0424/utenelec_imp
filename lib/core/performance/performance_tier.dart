// 性能分级
// 文档：docs/00-项目准则/07-性能自适应.md
// 决策：ADR-003-性能分级三档.md

/// 性能档位
///
/// - [lite]：低端设备或省电模式。禁用模糊、动画压缩、骨架屏不闪烁
/// - [standard]：中端设备默认。标准动画、轻度模糊
/// - [rich]：高端设备。玻璃模糊、进场动画、数字滚动
enum PerformanceTier {
  /// 省电档：低端设备或用户主动选择省电
  lite,

  /// 标准档：中端设备默认
  standard,

  /// 极致档：高端设备、桌面端
  rich,
}

/// 用户偏好（可手动覆盖）
///
/// [auto] 时由 [DeviceScorer] 自动检测；其他值强制使用对应档位。
enum PerformancePreference {
  /// 自动检测（默认）
  auto,

  /// 强制省电
  lite,

  /// 强制标准
  standard,

  /// 强制极致
  rich,
}

extension PerformanceTierValue on PerformanceTier {
  /// 当前档是否为 lite
  bool get isLite => this == PerformanceTier.lite;

  /// 当前档是否为 standard
  bool get isStandard => this == PerformanceTier.standard;

  /// 当前档是否为 rich
  bool get isRich => this == PerformanceTier.rich;

  /// 是否至少为 standard（standard 或 rich）
  bool get atLeastStandard =>
      this == PerformanceTier.standard || this == PerformanceTier.rich;

  /// 是否启用玻璃模糊效果（rich 才启用）
  bool get enableBlur => isRich;

  /// 是否启用进场 stagger 动画（standard 及以上）
  bool get enableStagger => atLeastStandard;

  /// 是否启用骨架屏闪烁（standard 及以上）
  bool get enableSkeletonShimmer => atLeastStandard;

  /// 是否启用数字滚动动画（rich 才启用）
  bool get enableNumberAnimation => isRich;

  /// 是否启用 Hero 转场（standard 及以上）
  bool get enableHero => atLeastStandard;

  /// 动画时长缩放因子（lite 压缩到 50%）
  double get durationFactor => isLite ? 0.5 : 1.0;
}

extension PerformancePreferenceValue on PerformancePreference {
  /// 是否为自动模式
  bool get isAuto => this == PerformancePreference.auto;

  /// 转换为强制档位（auto 时返回 null）
  PerformanceTier? get forcedTier => switch (this) {
    PerformancePreference.auto => null,
    PerformancePreference.lite => PerformanceTier.lite,
    PerformancePreference.standard => PerformanceTier.standard,
    PerformancePreference.rich => PerformanceTier.rich,
  };
}
