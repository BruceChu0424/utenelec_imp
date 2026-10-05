// 颜色 -> 中文颜色名 / 共享色调 的反查(ADR-150 状态图例)。
//
// AI 助手读页面时, 表格单元格最终底色和状态组件的色调要换成人能说的颜色名
// (「绿 = 可开工」)。先按 UtenColors 令牌精确反查(实底、浅底、深字、暗色主题
// 的半透明叠加都认), 查不到再按色相归档。颜色名是给 AI 的页面资料(中文固定词,
// 与 docs/02-组件库/AiPageContext.md 的色名表一致), 不是界面文案。
import 'package:flutter/painting.dart';

import '../../core/theme/uten_colors.dart';
import 'uten_status_badge.dart';

export 'uten_status_badge.dart' show UtenStatusBadgeType;

typedef UtenNamedColor = ({String name, UtenStatusBadgeType tone});

final Map<int, UtenNamedColor> _tokens = {
  for (final c in [
    UtenColors.success,
    UtenColors.successBg,
    UtenColors.successText,
    UtenColors.successOnDark,
    UtenColors.catEmerald,
  ])
    _rgb(c): (name: '绿', tone: UtenStatusBadgeType.success),
  for (final c in [UtenColors.warning, UtenColors.warningStrong])
    _rgb(c): (name: '琥珀', tone: UtenStatusBadgeType.warning),
  for (final c in [
    UtenColors.warningBg,
    UtenColors.warningText,
    UtenColors.warningOnDark,
    UtenColors.catAmber,
  ])
    _rgb(c): (name: '黄', tone: UtenStatusBadgeType.warning),
  for (final c in [
    UtenColors.info,
    UtenColors.infoBg,
    UtenColors.infoText,
    UtenColors.infoOnDark,
    UtenColors.onInfoContainer,
    UtenColors.infoContainerDark,
    UtenColors.catSky,
  ])
    _rgb(c): (name: '蓝', tone: UtenStatusBadgeType.info),
  for (final c in [
    UtenColors.error,
    UtenColors.errorBg,
    UtenColors.errorText,
    UtenColors.errorOnDark,
    UtenColors.dangerStrong,
    UtenColors.docDanger,
  ])
    _rgb(c): (name: '红', tone: UtenStatusBadgeType.danger),
  for (final c in [
    UtenColors.fuchsia,
    UtenColors.fuchsiaBg,
    UtenColors.fuchsiaText,
    UtenColors.fuchsiaOnDark,
    UtenColors.catPink,
  ])
    _rgb(c): (name: '品红', tone: UtenStatusBadgeType.fuchsia),
  for (final c in [
    UtenColors.violet,
    UtenColors.violetBg,
    UtenColors.violetText,
    UtenColors.violetOnDark,
  ])
    _rgb(c): (name: '紫', tone: UtenStatusBadgeType.violet),
  for (final c in [UtenColors.teal300, UtenColors.teal400])
    _rgb(c): (name: '青', tone: UtenStatusBadgeType.accent),
  for (final c in [
    UtenColors.teal50,
    UtenColors.teal100,
    UtenColors.teal500,
    UtenColors.teal600,
    UtenColors.teal700,
    UtenColors.tableSelectedRow,
  ])
    _rgb(c): (name: '青绿', tone: UtenStatusBadgeType.accent),
  for (final c in [
    UtenColors.slate300,
    UtenColors.slate400,
    UtenColors.slate500,
    UtenColors.surfaceMid,
    UtenColors.surfaceHigh,
    UtenColors.textSecondary,
  ])
    _rgb(c): (name: '灰', tone: UtenStatusBadgeType.neutral),
};

int _rgb(Color color) => color.toARGB32() & 0x00FFFFFF;

/// Chinese colour name and shared tone of a semantic colour. Exact token match
/// first (alpha ignored, so dark-theme overlays resolve too), then hue buckets.
UtenNamedColor? utenNamedColor(Color? color) {
  if (color == null || color.a == 0) return null;
  final token = _tokens[_rgb(color)];
  if (token != null) return token;
  final hsl = HSLColor.fromColor(color.withValues(alpha: 1));
  if (hsl.saturation < 0.15 || hsl.lightness > 0.97 || hsl.lightness < 0.08) {
    return (name: '灰', tone: UtenStatusBadgeType.neutral);
  }
  final hue = hsl.hue;
  if (hue < 15 || hue >= 345) {
    return (name: '红', tone: UtenStatusBadgeType.danger);
  }
  if (hue < 40) return (name: '琥珀', tone: UtenStatusBadgeType.warning);
  if (hue < 65) return (name: '黄', tone: UtenStatusBadgeType.warning);
  if (hue < 160) return (name: '绿', tone: UtenStatusBadgeType.success);
  if (hue < 190) return (name: '青绿', tone: UtenStatusBadgeType.accent);
  if (hue < 250) return (name: '蓝', tone: UtenStatusBadgeType.info);
  if (hue < 290) return (name: '紫', tone: UtenStatusBadgeType.violet);
  return (name: '品红', tone: UtenStatusBadgeType.fuchsia);
}

/// Chinese colour name of [color] (灰/蓝/绿/黄/琥珀/红/品红/紫/青/青绿), or null.
String? utenColorName(Color? color) => utenNamedColor(color)?.name;
