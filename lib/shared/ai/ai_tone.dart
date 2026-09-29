// AI 程序界面的语义前景色(浅色/深色主题各取一档)。
//
// 浅色主题用深一档的 UtenColors.*Text(白底上够对比度), 深色主题用亮一档的 *OnDark;
// 直接把 *Text 常量用在深色底上会发暗看不清。「次要」取文字三级色, 不借用边框色
// (深色主题的 outline 是边框色, 当文字/图标几乎看不见)。
import 'package:flutter/material.dart';

import '../../core/theme/uten_colors.dart';

abstract final class AiTone {
  static bool _dark(ThemeData theme) => theme.brightness == Brightness.dark;

  static Color success(ThemeData theme) =>
      _dark(theme) ? UtenColors.successOnDark : UtenColors.successText;

  static Color warning(ThemeData theme) =>
      _dark(theme) ? UtenColors.warningOnDark : UtenColors.warningText;

  static Color error(ThemeData theme) =>
      _dark(theme) ? UtenColors.errorOnDark : UtenColors.errorText;

  static Color info(ThemeData theme) =>
      _dark(theme) ? UtenColors.infoOnDark : UtenColors.infoText;

  /// 次要前景: 还没轮到的步骤、说明性小字与图标。
  static Color muted(ThemeData theme) =>
      _dark(theme) ? UtenColors.darkTextTertiary : UtenColors.textTertiary;
}
