// 前端输入校验器（体验层；后端为权威）。文档：docs/00-项目准则/10-安全准则.md §3.2
import '../utils/id_card_utils.dart';

abstract final class InputValidators {
  static String? required(String? v, {String label = '此项'}) {
    if (v == null || v.trim().isEmpty) return '$label不能为空';
    return null;
  }

  static String? minLength(String? v, int min, {String label = '此项'}) {
    if (v == null || v.length < min) return '$label至少 $min 位';
    return null;
  }

  static String? idNumber(String? v, {String type = '身份证'}) {
    if (v == null || v.trim().isEmpty) return '证件号码不能为空';
    if (type == '身份证' && !IdCardUtils.isValid(v.trim())) {
      return '身份证号格式不正确';
    }
    return null;
  }

  static String? phone(String? v) {
    if (v == null || v.trim().isEmpty) return '手机号不能为空';
    if (!RegExp(r'^1[3-9]\d{9}$').hasMatch(v.trim())) {
      return '手机号格式不正确';
    }
    return null;
  }

  /// 中国大陆手机号或带区号座机，可带 1～6 位分机号。
  static String? telephone(String? v) {
    if (v == null || v.trim().isEmpty) return null;
    final normalized = v.trim().replaceAll(' ', '');
    if (!RegExp(r'^(?:1[3-9]\d{9}|0\d{2,3}-?\d{7,8}(?:-\d{1,6})?)$')
        .hasMatch(normalized)) {
      return '请输入正确的手机号或座机号';
    }
    return null;
  }

  static String? email(String? v) {
    if (v == null || v.trim().isEmpty) return null; // 邮箱选填
    if (!RegExp(r'^[\w.+-]+@[\w-]+\.[\w.-]+$').hasMatch(v.trim())) {
      return '邮箱格式不正确';
    }
    return null;
  }

  /// 密码强度：≥8 位 + 字母 + 数字（与后端一致）。
  static String? password(String? v) {
    if (v == null || v.isEmpty) return '密码不能为空';
    if (v.length < 8) return '密码至少 8 位';
    if (!RegExp(r'[A-Za-z]').hasMatch(v) || !RegExp(r'\d').hasMatch(v)) {
      return '密码需同时包含字母和数字';
    }
    return null;
  }
}
