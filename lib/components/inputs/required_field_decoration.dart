// 必填字段「空时红框」共享外观（红边框 + 红 *，无底色）。
//
// 全站表单字段（UtenDropdownField / UtenDateField / UtenInput / UtenEmployeePicker /
// ClientPickerField / MasterEditForm 等）统一调本文件，保证「必填且为空」时输入框描红边、
// Required fields retain their red marker. UtenInputDecoration keeps validation
// borders and discloses error details inside the field without a bottom row.
//
// 另有「预填黄框」autofillHintBorder/applyAutofillHint：字段值来自系统学习/主档带入
// （如按客户记忆上次条款、按上次登记预选仓库）时描黄边提醒核对。
// 优先级：errorText（errorBorder）> 必填空（红）> 预填提醒（黄）。
//
// fieldLabel：全站「字段说明收进 ⓘ」约定的渲染位（见函数注释）。

import 'package:flutter/material.dart';

import '../../core/theme/uten_colors.dart';
import 'uten_field_label.dart';
import 'uten_input_decoration.dart';

export 'uten_field_label.dart';

/// 必填且为空时的红色描边（与主题 errorBorder 同色，宽度 1.5；聚焦 2）。
OutlineInputBorder requiredEmptyBorder(
  ThemeData theme, {
  bool focused = false,
}) {
  return OutlineInputBorder(
    borderRadius: const BorderRadius.all(Radius.circular(10)),
    borderSide: BorderSide(
      color: theme.colorScheme.error,
      width: focused ? 2 : 1.5,
    ),
  );
}

/// 给 [base] 叠加「必填空」红框：仅当 [requiredEmpty] 为真时改写 enabled/focused 边框为红色。
/// 不改 fill / errorText。当 [base] 自带 errorText 时，InputDecorator 会自动走 errorBorder，
/// 这两个边框被忽略，故提交校验优先级不变。
InputDecoration applyRequiredEmpty(
  InputDecoration base,
  ThemeData theme, {
  required bool requiredEmpty,
}) {
  if (!requiredEmpty) return base;
  return base.copyWith(
    enabledBorder: requiredEmptyBorder(theme),
    focusedBorder: requiredEmptyBorder(theme, focused: true),
  );
}

/// 「预填默认值」黄色提醒描边（值来自学习/主档带入，语义 warning 色；宽度 1.5，聚焦 2）。
OutlineInputBorder autofillHintBorder(ThemeData theme, {bool focused = false}) {
  return OutlineInputBorder(
    borderRadius: const BorderRadius.all(Radius.circular(10)),
    borderSide: BorderSide(color: UtenColors.warning, width: focused ? 2 : 1.5),
  );
}

/// Marks a prefilled value with a yellow border, tint and in-field disclosure.
/// 与 [applyRequiredEmpty] 组合时先套本函数再套必填红（后者 copyWith 覆盖前者的边框），
/// 保证「必填空(红) > 预填(黄)」；errorText 仍由主题 errorBorder 最高优先接管。
InputDecoration applyAutofillHint(
  InputDecoration base,
  ThemeData theme, {
  required bool autofilled,
}) {
  if (!autofilled) return base;
  final outlined = base.copyWith(
    enabledBorder: autofillHintBorder(theme),
    focusedBorder: autofillHintBorder(theme, focused: true),
    disabledBorder: autofillHintBorder(theme),
    filled: true,
    fillColor: Color.alphaBlend(
      UtenColors.warning.withValues(alpha: 0.10),
      base.fillColor ?? theme.colorScheme.surface,
    ),
  );
  return outlined is UtenInputDecoration
      ? outlined.copyWith(autofilled: true)
      : UtenInputDecoration(outlined, autofilled: true);
}

/// 带「红色 *」的标签：[required] 时在文案后追加红色加粗 `*`，否则原样。
///
/// - 用作 floating label：传给 `InputDecoration(label: requiredLabel(...))`；
/// - 用作行外标签：直接放进 Column。
/// [base] 为标签基础样式（可空）。
Widget requiredLabel(
  String label,
  ThemeData theme, {
  required bool required,
  TextStyle? base,
}) {
  if (!required) return Text(label, style: base);
  return Text.rich(
    TextSpan(
      text: label,
      style: base,
      children: [
        TextSpan(
          text: ' *',
          style: (base ?? const TextStyle()).copyWith(
            color: theme.colorScheme.error,
            fontWeight: FontWeight.w700,
          ),
        ),
      ],
    ),
  );
}

/// Carries label text and help separately for in-field disclosure.
Widget fieldLabel(
  String label,
  ThemeData theme, {
  bool required = false,
  String? info,
  TextStyle? base,
}) {
  final text = requiredLabel(label, theme, required: required, base: base);
  if (info == null || info.isEmpty) return text;
  return UtenFieldLabel(labelWithoutInfo: text, info: info);
}
