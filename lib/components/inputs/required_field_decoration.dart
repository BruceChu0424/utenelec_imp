// 必填字段「空时红框」共享外观（红边框 + 红 *，无底色）。
//
// 全站表单字段（UtenDropdownField / UtenDateField / UtenInput / UtenEmployeePicker /
// ClientPickerField / MasterEditForm 等）统一调本文件，保证「必填且为空」时输入框描红边、
// 标签 * 变红；填好后红边消失、* 仍红。与主题 errorBorder 同色，但不带 errorText（无下方红字），
// 故与既有提交校验 errorText（红框+下方红字）并存：errorText 非空时由主题 errorBorder 接管。

import 'package:flutter/material.dart';

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
