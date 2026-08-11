// 中国居民身份证工具（与后端 IdCardUtil 对齐）：校验(GB11643)、反推生日/性别、脱敏。
import 'china_datetime.dart';

abstract final class IdCardUtils {
  static const _weights = [7, 9, 10, 5, 8, 4, 2, 1, 6, 3, 7, 9, 10, 5, 8, 4, 2];
  static const _check = ['1', '0', 'X', '9', '8', '7', '6', '5', '4', '3', '2'];

  static bool isValid(String? id) {
    final value = id?.trim().toUpperCase();
    if (value == null ||
        !RegExp(r'^\d{17}[\dX]$').hasMatch(value) ||
        value.startsWith('000000') ||
        value.substring(14, 17) == '000') {
      return false;
    }
    final birth = _parseBirthDate(value);
    if (birth == null ||
        birth.year < 1800 ||
        birth.isAfter(ChinaDateTime.today())) {
      return false;
    }
    int sum = 0;
    for (int i = 0; i < 17; i++) {
      final c = value.codeUnitAt(i);
      sum += (c - 0x30) * _weights[i];
    }
    final expected = _check[sum % 11];
    return expected == value.substring(17);
  }

  static DateTime? birthDate(String id) {
    final value = id.trim();
    return value.length == 18 ? _parseBirthDate(value) : null;
  }

  /// 第 17 位奇=男 偶=女。
  static String? gender(String id) {
    if (id.length != 18) return null;
    final seq = int.tryParse(id.substring(16, 17));
    if (seq == null) return null;
    return seq % 2 == 1 ? 'male' : 'female';
  }

  static String? mask(String? id) {
    if (id == null || id.length < 4) return id;
    return '****${id.substring(id.length - 4)}';
  }

  static DateTime? _parseBirthDate(String id) {
    final year = int.tryParse(id.substring(6, 10));
    final month = int.tryParse(id.substring(10, 12));
    final day = int.tryParse(id.substring(12, 14));
    if (year == null || month == null || day == null) return null;
    final value = DateTime.utc(year, month, day);
    if (value.year != year || value.month != month || value.day != day) {
      return null;
    }
    return value;
  }
}
