// ignore_for_file: deprecated_member_use

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';

import 'uten_field_hint_icon.dart';
import 'uten_field_label.dart';
import 'uten_field_message.dart';

/// Moves field guidance and validation messages into one in-field disclosure.
///
/// Keeping the original decoration intact allows native [TextFormField] to add
/// validator errors through [copyWith] after [applyDefaults]. Neither the form
/// state nor the text controller is replaced, and no bottom message slot is
/// allocated by [InputDecorator].
class UtenInputDecoration extends InputDecoration {
  const UtenInputDecoration(this.base, {this.info, this.autofilled = false});

  final InputDecoration base;
  final String? info;
  final bool autofilled;

  static String? _messageText(Widget? widget) => switch (widget) {
    UtenFieldMessage(:final message) => message,
    Text(:final data, :final textSpan) => data ?? textSpan?.toPlainText(),
    RichText(:final text) => text.toPlainText(),
    _ => null,
  };

  String? get _errorMessage => base.errorText ?? _messageText(base.error);

  String? get _autofillMessage => switch (base.helper) {
    UtenFieldMessage(kind: UtenFieldMessageKind.autofill, :final message) =>
      message,
    _ => null,
  };

  String? get _infoMessage {
    final originalLabel = base.label;
    final messages = <String>{
      if (info?.isNotEmpty ?? false) info!,
      if (originalLabel is UtenFieldLabel && originalLabel.info.isNotEmpty)
        originalLabel.info,
      if (base.helperText?.isNotEmpty ?? false) base.helperText!,
      if (_autofillMessage == null &&
          (_messageText(base.helper)?.isNotEmpty ?? false))
        _messageText(base.helper)!,
    };
    return messages.isEmpty ? null : messages.join('\n\n');
  }

  bool get _hasError => base.error != null || base.errorText != null;

  bool get _hasMessage =>
      autofilled ||
      (_errorMessage?.isNotEmpty ?? false) ||
      (_autofillMessage?.isNotEmpty ?? false) ||
      (_infoMessage?.isNotEmpty ?? false);

  @override
  Widget? get label {
    final original = base.label;
    return original is UtenFieldLabel ? original.labelWithoutInfo : original;
  }

  @override
  Widget? get helper => null;

  @override
  String? get helperText => null;

  @override
  Widget? get error => null;

  @override
  String? get errorText => null;

  InputBorder? _errorBorder({required bool focused}) {
    final explicit = focused
        ? base.focusedErrorBorder ?? base.errorBorder
        : base.errorBorder;
    if (explicit != null) return explicit;
    final normal =
        (focused ? base.focusedBorder : base.enabledBorder) ?? base.border;
    final color = base.errorStyle?.color;
    return normal == null || color == null
        ? normal
        : normal.copyWith(borderSide: normal.borderSide.copyWith(color: color));
  }

  @override
  InputBorder? get enabledBorder =>
      _hasError ? _errorBorder(focused: false) : base.enabledBorder;

  @override
  InputBorder? get focusedBorder =>
      _hasError ? _errorBorder(focused: true) : base.focusedBorder;

  @override
  InputBorder? get disabledBorder =>
      _hasError ? _errorBorder(focused: false) : base.disabledBorder;

  Widget? _businessAdornment(Widget? child) {
    if (child == null || base.enabled) return child;
    return ExcludeFocus(child: AbsorbPointer(child: child));
  }

  @override
  Widget? get suffixIcon {
    if (!_hasMessage) return _businessAdornment(base.suffixIcon);
    final hint = UtenFieldHintIcon(
      info: _infoMessage,
      errorMessage: _errorMessage,
      autofillMessage: _autofillMessage,
      autofilled: autofilled,
    );
    final original = _businessAdornment(base.suffixIcon);
    if (original == null) return hint;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        hint,
        ConstrainedBox(
          constraints:
              base.suffixIconConstraints ??
              const BoxConstraints(minWidth: 48, minHeight: 48),
          child: original,
        ),
      ],
    );
  }

  @override
  BoxConstraints? get suffixIconConstraints {
    final original = base.suffixIconConstraints;
    if (!_hasMessage || original == null || !original.hasBoundedWidth) {
      return original;
    }
    // A fixed suffix width must also make room for the disclosure button.
    return original.copyWith(
      minWidth: original.minWidth + 44,
      maxWidth: original.maxWidth + 44,
    );
  }

  @override
  Widget? get icon => _businessAdornment(base.icon);

  @override
  Color? get iconColor => base.iconColor;

  @override
  String? get labelText => base.labelText;

  @override
  TextStyle? get labelStyle => base.labelStyle;

  @override
  TextStyle? get floatingLabelStyle => base.floatingLabelStyle;

  @override
  TextStyle? get helperStyle => base.helperStyle;

  @override
  int? get helperMaxLines => base.helperMaxLines;

  @override
  String? get hintText => base.hintText;

  @override
  Widget? get hint => base.hint;

  @override
  TextStyle? get hintStyle => base.hintStyle;

  @override
  TextDirection? get hintTextDirection => base.hintTextDirection;

  @override
  int? get hintMaxLines => base.hintMaxLines;

  @override
  Duration? get hintFadeDuration => base.hintFadeDuration;

  @override
  bool get maintainHintHeight => base.maintainHintHeight;

  @override
  bool get maintainHintSize => base.maintainHintSize;

  @override
  bool get maintainLabelSize => base.maintainLabelSize;

  @override
  TextStyle? get errorStyle => base.errorStyle;

  @override
  int? get errorMaxLines => base.errorMaxLines;

  @override
  FloatingLabelBehavior? get floatingLabelBehavior =>
      base.floatingLabelBehavior;

  @override
  FloatingLabelAlignment? get floatingLabelAlignment =>
      base.floatingLabelAlignment;

  @override
  bool? get isDense => base.isDense;

  @override
  EdgeInsetsGeometry? get contentPadding => base.contentPadding;

  @override
  bool? get isCollapsed => base.isCollapsed;

  @override
  Widget? get prefixIcon => _businessAdornment(base.prefixIcon);

  @override
  BoxConstraints? get prefixIconConstraints => base.prefixIconConstraints;

  @override
  Widget? get prefix => _businessAdornment(base.prefix);

  @override
  String? get prefixText => base.prefixText;

  @override
  TextStyle? get prefixStyle => base.prefixStyle;

  @override
  Color? get prefixIconColor => base.prefixIconColor;

  @override
  Widget? get suffix => _businessAdornment(base.suffix);

  @override
  String? get suffixText => base.suffixText;

  @override
  TextStyle? get suffixStyle => base.suffixStyle;

  @override
  Color? get suffixIconColor => base.suffixIconColor;

  @override
  String? get counterText => base.counterText;

  @override
  Widget? get counter => base.counter;

  @override
  TextStyle? get counterStyle => base.counterStyle;

  @override
  bool? get filled => base.filled;

  @override
  Color? get fillColor => base.fillColor;

  @override
  Color? get focusColor => base.focusColor;

  @override
  Color? get hoverColor => base.hoverColor;

  @override
  InputBorder? get errorBorder => base.errorBorder;

  @override
  InputBorder? get focusedErrorBorder => base.focusedErrorBorder;

  @override
  InputBorder? get border => base.border;

  @override
  bool get enabled => base.enabled;

  @override
  String? get semanticCounterText => base.semanticCounterText;

  @override
  bool? get alignLabelWithHint => base.alignLabelWithHint;

  @override
  BoxConstraints? get constraints => base.constraints;

  @override
  VisualDensity? get visualDensity => base.visualDensity;

  @override
  UtenInputDecoration copyWith({
    bool? autofilled,
    Widget? icon,
    Color? iconColor,
    Widget? label,
    String? labelText,
    TextStyle? labelStyle,
    TextStyle? floatingLabelStyle,
    Widget? helper,
    String? helperText,
    TextStyle? helperStyle,
    int? helperMaxLines,
    String? hintText,
    Widget? hint,
    TextStyle? hintStyle,
    TextDirection? hintTextDirection,
    Duration? hintFadeDuration,
    int? hintMaxLines,
    bool? maintainHintHeight,
    bool? maintainHintSize,
    bool? maintainLabelSize,
    Widget? error,
    String? errorText,
    TextStyle? errorStyle,
    int? errorMaxLines,
    FloatingLabelBehavior? floatingLabelBehavior,
    FloatingLabelAlignment? floatingLabelAlignment,
    bool? isCollapsed,
    bool? isDense,
    EdgeInsetsGeometry? contentPadding,
    Widget? prefixIcon,
    Widget? prefix,
    String? prefixText,
    BoxConstraints? prefixIconConstraints,
    TextStyle? prefixStyle,
    Color? prefixIconColor,
    Widget? suffixIcon,
    Widget? suffix,
    String? suffixText,
    TextStyle? suffixStyle,
    Color? suffixIconColor,
    BoxConstraints? suffixIconConstraints,
    Widget? counter,
    String? counterText,
    TextStyle? counterStyle,
    bool? filled,
    Color? fillColor,
    Color? focusColor,
    Color? hoverColor,
    InputBorder? errorBorder,
    InputBorder? focusedBorder,
    InputBorder? focusedErrorBorder,
    InputBorder? disabledBorder,
    InputBorder? enabledBorder,
    InputBorder? border,
    bool? enabled,
    String? semanticCounterText,
    bool? alignLabelWithHint,
    BoxConstraints? constraints,
    VisualDensity? visualDensity,
    SemanticsService? semanticsService,
  }) {
    return UtenInputDecoration(
      base.copyWith(
        icon: icon,
        iconColor: iconColor,
        label: label,
        labelText: labelText,
        labelStyle: labelStyle,
        floatingLabelStyle: floatingLabelStyle,
        helper: helper,
        helperText: helperText,
        helperStyle: helperStyle,
        helperMaxLines: helperMaxLines,
        hintText: hintText,
        hint: hint,
        hintStyle: hintStyle,
        hintTextDirection: hintTextDirection,
        hintFadeDuration: hintFadeDuration,
        hintMaxLines: hintMaxLines,
        maintainHintHeight: maintainHintHeight,
        maintainHintSize: maintainHintSize,
        maintainLabelSize: maintainLabelSize,
        error: error,
        errorText: errorText,
        errorStyle: errorStyle,
        errorMaxLines: errorMaxLines,
        floatingLabelBehavior: floatingLabelBehavior,
        floatingLabelAlignment: floatingLabelAlignment,
        isCollapsed: isCollapsed,
        isDense: isDense,
        contentPadding: contentPadding,
        prefixIcon: prefixIcon,
        prefix: prefix,
        prefixText: prefixText,
        prefixIconConstraints: prefixIconConstraints,
        prefixStyle: prefixStyle,
        prefixIconColor: prefixIconColor,
        suffixIcon: suffixIcon,
        suffix: suffix,
        suffixText: suffixText,
        suffixStyle: suffixStyle,
        suffixIconColor: suffixIconColor,
        suffixIconConstraints: suffixIconConstraints,
        counter: counter,
        counterText: counterText,
        counterStyle: counterStyle,
        filled: filled,
        fillColor: fillColor,
        focusColor: focusColor,
        hoverColor: hoverColor,
        errorBorder: errorBorder,
        focusedBorder: focusedBorder,
        focusedErrorBorder: focusedErrorBorder,
        disabledBorder: disabledBorder,
        enabledBorder: enabledBorder,
        border: border,
        enabled: enabled,
        semanticCounterText: semanticCounterText,
        alignLabelWithHint: alignLabelWithHint,
        constraints: constraints,
        visualDensity: visualDensity,
      ),
      info: info,
      autofilled: autofilled ?? this.autofilled,
    );
  }

  @override
  UtenInputDecoration applyDefaults(Object inputDecorationTheme) =>
      UtenInputDecoration(
        base.applyDefaults(inputDecorationTheme),
        info: info,
        autofilled: autofilled,
      );

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is UtenInputDecoration &&
          other.base == base &&
          other.info == info &&
          other.autofilled == autofilled;

  @override
  int get hashCode => Object.hash(runtimeType, base, info, autofilled);
}
