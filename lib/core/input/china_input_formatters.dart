import 'package:flutter/services.dart';

/// 不打断中文输入法 composing 区的中国常用证件/号码格式化器。
///
/// 姓名、单位、地址等自然语言字段不应套此格式化器，以免拦截生僻字、少数民族
/// 姓名分隔符或中文输入法的中间组合文本。
abstract final class ChinaInputFormatters {
  static final phone = <TextInputFormatter>[
    _AsciiFilterFormatter(RegExp(r'[0-9]'), maxLength: 11),
  ];

  static final smsCode = <TextInputFormatter>[
    _AsciiFilterFormatter(RegExp(r'[0-9]'), maxLength: 6),
  ];

  static final residentId = <TextInputFormatter>[
    _AsciiFilterFormatter(RegExp(r'[0-9Xx]'), maxLength: 18, uppercase: true),
  ];
}

class _AsciiFilterFormatter extends TextInputFormatter {
  _AsciiFilterFormatter(
    this.allowed, {
    required this.maxLength,
    this.uppercase = false,
  });

  final RegExp allowed;
  final int maxLength;
  final bool uppercase;

  @override
  TextEditingValue formatEditUpdate(
    TextEditingValue oldValue,
    TextEditingValue newValue,
  ) {
    // 中文 IME 正在组词时原样放行；提交组合文本后再执行 ASCII 字段约束。
    if (!newValue.composing.isCollapsed) return newValue;

    String filter(String value) {
      final buffer = StringBuffer();
      for (final rune in value.runes) {
        var character = String.fromCharCode(rune);
        if (!allowed.hasMatch(character)) continue;
        if (uppercase) character = character.toUpperCase();
        if (buffer.length >= maxLength) break;
        buffer.write(character);
      }
      return buffer.toString();
    }

    final filtered = filter(newValue.text);
    final base = filter(
      newValue.text.substring(
        0,
        newValue.selection.baseOffset.clamp(0, newValue.text.length),
      ),
    ).length;
    final extent = filter(
      newValue.text.substring(
        0,
        newValue.selection.extentOffset.clamp(0, newValue.text.length),
      ),
    ).length;

    return TextEditingValue(
      text: filtered,
      selection: TextSelection(
        baseOffset: base.clamp(0, filtered.length),
        extentOffset: extent.clamp(0, filtered.length),
        affinity: newValue.selection.affinity,
        isDirectional: newValue.selection.isDirectional,
      ),
    );
  }
}
