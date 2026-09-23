import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 前后端权限码对齐契约（权限体系总设计 §七：人工对齐无代码生成，本测试兜底漂移）。
///
/// 双向锁定(ADR-109 / permissions-06)：
/// 1. 后端每个 @PreAuthorize 强制的权限码(含 Java 常量拼接形式)，前端 Perm 常量表
///    必须有同值常量——否则路由守卫/按钮过滤无法引用；
/// 2. 前端每个 Perm 常量都必须在服务端代码里被引用(服务端契约测试再把服务端引用
///    与数据库目录做双向相等)，不允许「只有前端认」的码；访客端码不进员工码表。
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
          // 访客端码只属于访客会话(principal.visitor)，不进员工码表。
          if (RegExp(r'^[a-z0-9_]+(:[a-zA-Z0-9_.-]+)?$').hasMatch(code) &&
              !code.startsWith('visitor_portal:')) {
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
      // 无冒号的模块级码也纳入前端声明集合(V655 起目录码一律带冒号，这里只是兜底)。
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

  test('every frontend Perm constant is referenced by server code', () {
    final serverRoot = Directory('server/src/main/java');
    expect(serverRoot.existsSync(), isTrue, reason: '需在仓库根目录运行');
    final serverLiterals = <String>{};
    final literalPattern = RegExp(r'"([a-z0-9_]+:[a-zA-Z0-9_:.-]+)"');
    final guardPattern = RegExp(r"'([a-z0-9_]+:[a-zA-Z0-9_:.-]+)'");
    for (final entity in serverRoot.listSync(recursive: true)) {
      if (entity is! File || !entity.path.endsWith('.java')) continue;
      final source = entity.readAsStringSync();
      for (final match in literalPattern.allMatches(source)) {
        serverLiterals.add(match.group(1)!);
      }
      for (final match in guardPattern.allMatches(source)) {
        serverLiterals.add(match.group(1)!);
      }
    }

    final permSource = File(
      'lib/shared/auth/permissions.dart',
    ).readAsStringSync();
    final declared = [
      for (final match in RegExp(
        r"static const \w+\s*=\s*'([a-z0-9_]+:[a-zA-Z0-9_:.-]+)'",
      ).allMatches(permSource))
        match.group(1)!,
    ];
    expect(declared, isNotEmpty);

    final frontendOnly =
        declared.where((code) => !serverLiterals.contains(code)).toList()
          ..sort();
    expect(
      frontendOnly,
      isEmpty,
      reason:
          '以下 Perm 常量在服务端没有任何引用(只在前端生效的码必须删除，'
          '或在服务端补上强制)：\n${frontendOnly.join('\n')}',
    );
    expect(
      declared.where((code) => code.startsWith('visitor_portal:')),
      isEmpty,
      reason: '访客端码只属于访客会话，不能出现在员工权限码表里',
    );
  });
}
