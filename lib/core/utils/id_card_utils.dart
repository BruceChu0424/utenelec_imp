// 中国居民身份证工具（与后端 IdCardUtil 对齐）：校验(GB11643)、反推生日/性别、取后六位、脱敏。
abstract final class IdCardUtils {
  static const _weights = [7, 9, 10, 5, 8, 4, 2, 1, 6, 3, 7, 9, 10, 5, 8, 4, 2];
  static const _check = ['1', '0', 'X', '9', '8', '7', '6', '5', '4', '3', '2'];

  static bool isValid(String? id) {
    if (id == null || id.length != 18) return false;
    int sum = 0;
    for (int i = 0; i < 17; i++) {
      final c = id.codeUnitAt(i);
      if (c < 0x30 || c > 0x39) return false;
      sum += (c - 0x30) * _weights[i];
    }
    final expected = _check[sum % 11];
    return expected == id.substring(17).toUpperCase();
  }

  static DateTime? birthDate(String id) {
    try {
      return DateTime.parse('${id.substring(6, 10)}-${id.substring(10, 12)}-${id.substring(12, 14)}');
    } catch (_) {
      return null;
    }
  }

  /// 第 17 位奇=男 偶=女。
  static String? gender(String id) {
    if (id.length != 18) return null;
    final seq = int.tryParse(id.substring(16, 17));
    if (seq == null) return null;
    return seq % 2 == 1 ? 'male' : 'female';
  }

  /// 后六位（用于派生默认密码）。
  static String last6(String id) => id.substring(12);

  static String? mask(String? id) {
    if (id == null || id.length < 4) return id;
    return '****${id.substring(id.length - 4)}';
  }
}
