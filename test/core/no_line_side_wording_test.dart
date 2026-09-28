// 「线边仓」改名「内料仓」的守门测试 (ADR-131 §4 / 实现规格 §4)。
//
// 车间自己的料架对员工一律叫「内料仓」。本测试扫描 lib/ 下全部 .dart 的字符串
// 字面量 (含插值字符串的文字段) 与 .arb 的显示文案，不允许再出现「线边仓」。
// 注释、类名、方法名、字段名这些内部标识不在范围内 (按 AST 只看字符串字面量)。
import 'dart:convert';
import 'dart:io';

import 'package:analyzer/dart/analysis/utilities.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/visitor.dart';
import 'package:flutter_test/flutter_test.dart';

const _oldWording = '线边仓';

class _StringLiteralVisitor extends RecursiveAstVisitor<void> {
  _StringLiteralVisitor(this.path, this.source);

  final String path;
  final String source;
  final hits = <String>[];

  void _check(AstNode node, String value) {
    if (!value.contains(_oldWording)) return;
    final line = '\n'.allMatches(source.substring(0, node.offset)).length + 1;
    hits.add('$path:$line: ${node.toSource()}');
  }

  @override
  void visitSimpleStringLiteral(SimpleStringLiteral node) {
    _check(node, node.value);
    super.visitSimpleStringLiteral(node);
  }

  @override
  void visitInterpolationString(InterpolationString node) {
    _check(node, node.value);
    super.visitInterpolationString(node);
  }
}

List<String> _scanDart(String source, {required String path}) {
  final parsed = parseString(
    content: source,
    path: path,
    throwIfDiagnostics: false,
  );
  final visitor = _StringLiteralVisitor(path, source);
  parsed.unit.accept(visitor);
  return visitor.hits;
}

/// arb 里给员工看的文案 (不含 @ 开头的翻译说明)。
List<String> _scanArb(String source, {required String path}) {
  final decoded = jsonDecode(source);
  if (decoded is! Map<String, dynamic>) return const [];
  return [
    for (final entry in decoded.entries)
      if (!entry.key.startsWith('@') &&
          entry.value is String &&
          (entry.value as String).contains(_oldWording))
        '$path: ${entry.key} = ${entry.value}',
  ];
}

void main() {
  test('scanner only looks at string literals, not comments or names', () {
    final hits = _scanDart('''
// 线边仓是旧叫法 (注释不算)
class LineSideWarehouse {
  /// 线边仓 (文档注释也不算)
  final isLineSide = true;
  String a() => '车间线边仓';
  String b(String n) => '\$n 的线边仓还有料';
  String c() => '内料仓';
}
''', path: 'lib/example.dart');
    expect(hits, hasLength(2));
    expect(hits.first, contains('lib/example.dart:5'));

    final arbHits = _scanArb(
      jsonEncode({
        'a': '车间线边仓',
        '@a': {'description': '线边仓 (说明不算)'},
        'b': '内料仓',
      }),
      path: 'lib/example.arb',
    );
    expect(arbHits, hasLength(1));
  });

  test('lib 下的界面文字不再出现「线边仓」 (统一叫「内料仓」)', () {
    final hits = <String>[];
    final files = Directory(
      'lib',
    ).listSync(recursive: true).whereType<File>().toList();
    var dartFiles = 0;
    var arbFiles = 0;
    for (final file in files) {
      final path = file.path.replaceAll(r'\', '/');
      if (path.endsWith('.dart')) {
        dartFiles++;
        hits.addAll(_scanDart(file.readAsStringSync(), path: path));
      } else if (path.endsWith('.arb')) {
        arbFiles++;
        hits.addAll(_scanArb(file.readAsStringSync(), path: path));
      }
    }
    expect(dartFiles, greaterThan(100));
    expect(arbFiles, greaterThanOrEqualTo(3));
    expect(
      hits,
      isEmpty,
      reason:
          '车间自己的料架对员工一律叫「内料仓」(ADR-131)，下列字符串还在用「线边仓」：\n'
          '${hits.join('\n')}',
    );
  });
}
