import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 前后端权限码对齐契约（权限体系总设计 §七：人工对齐无代码生成，本测试兜底漂移）。
///
/// 后端每个 @PreAuthorize 强制的权限码（含 Java 常量拼接形式），前端 Perm 常量表
/// 必须有同值常量——否则路由守卫/按钮过滤无法引用，页面会把「有权限却看不到入口」
/// 当 bug 报。只锁「后端强制 ⊆ 前端常量」方向：前端多余常量（未启用码）由孤儿码
/// 下线流程治理，不在此断言。历史上存在无冒号（finance_shipment_audit）与驼峰段
/// （batchApprove）等合法历史码形，故不做形状断言。
void main() {
  test(
    'every backend-enforced permission code has a frontend Perm constant',
    () {
      final serverRoot = Directory('server/src/main/java');
      expect(serverRoot.existsSync(), isTrue, reason: '需在仓库根目录运行');

      // 先收集 Java 字符串常量（name → value），用于解析 hasAuthority 的拼接表达式。
      final javaConstants = <String, String>{};
      final constantPattern = RegExp(
        r'static final String (\w+)\s*=\s*"([^"]+)"',
      );
      final authorityPattern = RegExp(r'hasAuthority\(\s*([^)]+)\)');
      final enforced = <String>{};

      String resolveAuthorityExpr(String expr) {
        if (!expr.contains('+')) {
          return expr.trim().replaceAll("'", '').replaceAll('"', '');
        }
        return expr.split('+').map((piece) => piece.trim()).map((piece) {
          if (piece.startsWith("'") || piece.startsWith('"')) {
            return piece.replaceAll("'", '').replaceAll('"', '');
          }
          // ConstClass.NAME → NAME → 常量表；查不到则保留原文让断言暴露。
          final simple = piece.split('.').last;
          return javaConstants[simple] ?? piece;
        }).join();
      }

      for (final entity in serverRoot.listSync(recursive: true)) {
        if (entity is! File || !entity.path.endsWith('.java')) continue;
        final source = entity.readAsStringSync();
        for (final match in constantPattern.allMatches(source)) {
          javaConstants[match.group(1)!] = match.group(2)!;
        }
      }
      for (final entity in serverRoot.listSync(recursive: true)) {
        if (entity is! File || !entity.path.endsWith('.java')) continue;
        final source = entity.readAsStringSync();
        for (final match in authorityPattern.allMatches(source)) {
          final raw = match.group(1)!.trim();
          // 裸标识符传参（如 access.hasAuthority(authority)）不定义单一码，跳过；
          // 常量引用（Const.NAME）经常量表解析后计入。
          final bareIdentifier = RegExp(r'^[A-Za-z_][\w.]*$').hasMatch(raw);
          if (bareIdentifier &&
              !javaConstants.containsKey(raw.split('.').last)) {
            continue;
          }
          final code = resolveAuthorityExpr(raw);
          // 跳过明显非字面量的动态表达式（如 containsAll/自定义 bean），它们不定义单一码。
          if (RegExp(r'^[a-z0-9_]+(:[a-zA-Z0-9_.-]+)?$').hasMatch(code)) {
            enforced.add(code);
          }
        }
      }
      expect(enforced, isNotEmpty, reason: '未扫描到任何 @PreAuthorize 权限码');

      final permSource = File(
        'lib/shared/auth/permissions.dart',
      ).readAsStringSync();
      final declared = <String>{};
      // \s* 兼容 dart format 把长常量折行（值与声明不同行）。
      for (final match in RegExp(
        r"static const \w+\s*=\s*'([a-z0-9_]+:[a-zA-Z0-9_.-]+)'",
      ).allMatches(permSource)) {
        declared.add(match.group(1)!);
      }
      // 无冒号的模块级码（如 finance_shipment_audit）也纳入前端声明集合。
      for (final match in RegExp(
        r"static const \w+\s*=\s*'([a-z0-9_]+)'",
      ).allMatches(permSource)) {
        declared.add(match.group(1)!);
      }

      final missing = enforced.difference(declared).toList()..sort();
      expect(
        missing,
        isEmpty,
        reason:
            '以下权限码被后端 @PreAuthorize 强制，但前端 permissions.dart 缺少同值 '
            'Perm 常量（新增页面/按钮将无法做权限过滤）：\n${missing.join('\n')}',
      );
    },
  );
}
