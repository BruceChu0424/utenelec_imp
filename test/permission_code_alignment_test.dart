import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 前后端权限码对齐契约（权限体系总设计 §七：人工对齐无代码生成，本测试兜底漂移）。
///
/// 双向锁定(ADR-109 / permissions-06)：
/// 1. 后端每个 @PreAuthorize 强制的权限码(含 Java 常量拼接形式)，前端 Perm 常量表
///    必须有同值常量——否则路由守卫/按钮过滤无法引用；
/// 2. 前端每个 Perm 常量都必须在服务端代码里被引用(服务端契约测试再把服务端引用
///    与数据库目录做双向相等)，不允许「只有前端认」的码；访客端码不进员工码表。
String? _resolveAuthorityExpr(
  String expr,
  Map<String, String> constants, {
  String? owner,
  Map<String, String> aliases = const {},
}) {
  final parts = <String>[];
  for (final raw in expr.split('+')) {
    final piece = raw.trim();
    if (piece.startsWith("'") || piece.startsWith('"')) {
      parts.add(piece.replaceAll("'", '').replaceAll('"', ''));
    } else {
      final qualified = piece.split('.');
      final key = qualified.length > 1
          ? qualified.skip(qualified.length - 2).join('.')
          : null;
      final value =
          constants[piece] ??
          (key == null ? null : constants[key]) ??
          (owner == null ? null : constants['$owner.$piece']) ??
          constants[aliases[piece]];
      // A runtime identifier is not a literal prefix. Never manufacture a
      // plausible permission such as prefix_order:view from its variable name.
      if (value == null) return null;
      parts.add(value);
    }
  }
  return parts.join();
}

String _javaOwner(String path) =>
    path.replaceAll(r'\', '/').split('/').last.replaceFirst('.java', '');

({Map<String, String> values, Map<String, String> aliases}) _javaConstants(
  Map<String, String> sources,
) {
  final expressions = <String, String>{};
  final byName = <String, List<String>>{};
  for (final entry in sources.entries) {
    final owner = _javaOwner(entry.key);
    for (final match in RegExp(
      r'static\s+final\s+String\s+(\w+)\s*=\s*([^;]+);',
    ).allMatches(entry.value)) {
      final key = '$owner.${match.group(1)!}';
      expressions[key] = match.group(2)!.trim();
      byName.putIfAbsent(match.group(1)!, () => []).add(key);
    }
  }
  // A bare shared name is usable only when its declaration is unambiguous.
  // Class-qualified aliases such as Result.VIEW must keep their own identity.
  final aliases = {
    for (final entry in byName.entries)
      if (entry.value.length == 1) entry.key: entry.value.single,
  };
  final values = <String, String>{};
  for (var pass = 0; pass < expressions.length; pass++) {
    final before = values.length;
    for (final entry in expressions.entries) {
      if (values.containsKey(entry.key)) continue;
      final resolved = _resolveAuthorityExpr(
        entry.value,
        values,
        owner: entry.key.split('.').first,
        aliases: aliases,
      );
      if (resolved != null) values[entry.key] = resolved;
    }
    if (values.length == before) break;
  }
  return (values: values, aliases: aliases);
}

Map<String, String> _procurementPrefixes(String source) {
  final values = <String, String>{
    for (final match in RegExp(r'case "(\w+)" -> "(\w+)";').allMatches(source))
      match.group(1)!: match.group(2)!,
  };
  expect(values, {'PURCHASE': 'purchase', 'SUBCONTRACT': 'subcontract'});
  expect(source, contains('default -> throw new IllegalArgumentException'));
  return values;
}

void main() {
  test(
    'authority expressions resolve constants without inventing runtime codes',
    () {
      expect(_resolveAuthorityExpr("'client:finance'", {}), 'client:finance');
      expect(
        _resolveAuthorityExpr('Guard.PREFIX + "_order:view"', {
          'Guard.PREFIX': 'purchase',
        }),
        'purchase_order:view',
      );
      expect(_resolveAuthorityExpr('prefix + "_order:view"', {}), isNull);
      expect(_resolveAuthorityExpr('otherPrefix + "_order:view"', {}), isNull);
      expect(_resolveAuthorityExpr('authority', {}), isNull);
      expect(
        _resolveAuthorityExpr("'goods:price_analysis:view'", {}),
        'goods:price_analysis:view',
      );
    },
  );

  test(
    'Java permission aliases retain class scope and resolve forward references',
    () {
      final catalog = _javaConstants({
        'Result.java': 'static final String STOCK_IN_VIEW = StockIn.VIEW;',
        'StockIn.java':
            'static final String VIEW = "warehouse_iqc_stock_in:view";',
        'Customer.java': 'static final String VIEW = "client:view";',
      });
      expect(
        catalog.values['Result.STOCK_IN_VIEW'],
        'warehouse_iqc_stock_in:view',
      );
      expect(catalog.values['Customer.VIEW'], 'client:view');
      expect(catalog.aliases.containsKey('VIEW'), isFalse);
      expect(
        _resolveAuthorityExpr(
          'VIEW',
          catalog.values,
          owner: 'Customer',
          aliases: catalog.aliases,
        ),
        'client:view',
      );
      expect(
        _resolveAuthorityExpr('VIEW', catalog.values, aliases: catalog.aliases),
        isNull,
      );
    },
  );

  test('every backend-enforced permission code has a frontend Perm constant', () {
    final serverRoot = Directory('server/src/main/java');
    expect(serverRoot.existsSync(), isTrue, reason: '需在仓库根目录运行');

    // 先收集 Java 字符串常量（name → value），用于解析 hasAuthority 的拼接表达式。
    final javaSources = <String, String>{};
    final authorityPattern = RegExp(
      r'(?:hasAuthority|hasAnyAuthority|hasAllAuthorities)\(\s*([^)]+)\)',
    );
    final enforced = <String>{};
    final unresolvedConcatenations = <String>[];

    for (final entity in serverRoot.listSync(recursive: true)) {
      if (entity is! File || !entity.path.endsWith('.java')) continue;
      javaSources[entity.path] = entity.readAsStringSync();
    }
    final catalog = _javaConstants(javaSources);
    final javaConstants = catalog.values;
    for (final entity in serverRoot.listSync(recursive: true)) {
      if (entity is! File || !entity.path.endsWith('.java')) continue;
      final source = entity.readAsStringSync();
      for (final match in authorityPattern.allMatches(source)) {
        for (final argument in match.group(1)!.split(',')) {
          final raw = argument.trim();
          // 裸标识符传参（如 access.hasAuthority(authority)）不定义单一码，跳过；
          // 常量引用（Const.NAME）经常量表解析后计入。
          final codes = <String>[];
          final literal = _resolveAuthorityExpr(
            raw,
            javaConstants,
            owner: _javaOwner(entity.path),
            aliases: catalog.aliases,
          );
          if (literal != null) {
            codes.add(literal);
          } else if (entity.path
                  .replaceAll(r'\', '/')
                  .endsWith(
                    '/common/finance/ProcurementDeliveryDifferenceRead.java',
                  ) &&
              RegExp(r'^prefix\s*\+\s*"_order:view"$').hasMatch(raw)) {
            // This runtime expression has a closed, validated switch domain.
            // Check both real permissions instead of omitting the shared guard.
            for (final prefix in _procurementPrefixes(source).values) {
              codes.add(_resolveAuthorityExpr(raw, {'prefix': prefix})!);
            }
          } else if (raw.contains('+')) {
            unresolvedConcatenations.add('${entity.path}: $raw');
          }
          // 跳过明显非字面量的动态表达式（如 containsAll/自定义 bean），它们不定义单一码。
          // 访客端码只属于访客会话(principal.visitor)，不进员工码表。
          for (final code in codes) {
            if (RegExp(r'^[a-z0-9_]+(:[a-zA-Z0-9_:.-]+)?$').hasMatch(code) &&
                !code.startsWith('visitor_portal:')) {
              enforced.add(code);
            }
          }
        }
      }
    }
    expect(
      unresolvedConcatenations,
      isEmpty,
      reason: '动态权限拼接必须审查其真实取值，不能用变量名伪造权限码',
    );
    expect(enforced, isNotEmpty, reason: '未扫描到任何 @PreAuthorize 权限码');

    final permSource = File(
      'lib/shared/auth/permissions.dart',
    ).readAsStringSync();
    final declared = <String>{};
    // \s* 兼容 dart format 把长常量折行（值与声明不同行）。
    for (final match in RegExp(
      r"static const \w+\s*=\s*'([a-z0-9_]+:[a-zA-Z0-9_:.-]+)'",
    ).allMatches(permSource)) {
      declared.add(match.group(1)!);
    }
    // 无冒号的模块级码也纳入前端声明集合(V677 起目录码一律带冒号，这里只是兜底)。
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
  });

  test('ADR-135 stock:weight:manage is one shared constant on both sides', () {
    // 单重管理码: 前端只认 Perm.stockWeightManage (共享层 weight_params 也引用它,
    // 不再各写一份字面量); 后端 StockWeightController 用同值强制。
    final permSource = File(
      'lib/shared/auth/permissions.dart',
    ).readAsStringSync();
    expect(
      permSource,
      contains("static const stockWeightManage = 'stock:weight:manage';"),
    );
    final weightParams = File(
      'lib/shared/measurement/weight_params.dart',
    ).readAsStringSync();
    expect(weightParams, contains('Perm.stockWeightManage'));
    expect(weightParams, isNot(contains("'stock:weight:manage'")));
    final controller = File(
      'server/src/main/java/com/uten/imp/features/stock/weight/'
      'StockWeightController.java',
    ).readAsStringSync();
    expect(controller, contains("hasAuthority('stock:weight:manage')"));
  });

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
