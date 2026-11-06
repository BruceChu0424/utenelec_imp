// AST inventory of async dependencies; findings require semantic review/tests.
import 'dart:convert';
import 'dart:io';

import 'package:analyzer/dart/analysis/utilities.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/visitor.dart';

void main(List<String> arguments) {
  final output = File(
    arguments.isEmpty ? 'build/page-read-dependencies.json' : arguments.first,
  );
  final files = Directory('lib/features')
      .listSync(recursive: true)
      .whereType<File>()
      .where((file) => file.path.endsWith('.dart'));
  final rows = <Map<String, Object?>>[];
  for (final file in files) {
    final source = file.readAsStringSync();
    if (!source.contains('MasterDataTableView') &&
        !source.contains('UtenFilterToolbar') &&
        !source.contains('UtenSegmentBadgeLabel')) {
      continue;
    }
    final parsed = parseString(content: source, throwIfDiagnostics: false);
    final methods = _Methods(file.path.replaceAll('\\', '/'), source, rows);
    parsed.unit.accept(methods);
  }
  output.parent.createSync(recursive: true);
  output.writeAsStringSync(
    const JsonEncoder.withIndent('  ').convert({
      'baseline':
          (Process.runSync('git', ['rev-parse', 'HEAD']).stdout as String)
              .trim(),
      'interpretation':
          'AST dependency inventory, not proof of a defect or runtime acceptance',
      'methods': rows,
    }),
  );
  for (final row in rows) {
    if (row['needsReview'] == true) {
      stdout.writeln(
        '${row['source']}:${row['line']} ${row['method']} '
        '${row['awaits']}',
      );
    }
  }
}

class _Methods extends RecursiveAstVisitor<void> {
  _Methods(this.path, this.source, this.rows);
  final String path;
  final String source;
  final List<Map<String, Object?>> rows;
  @override
  void visitMethodDeclaration(MethodDeclaration node) {
    if (!RegExp(
      r'load|refresh|initState|didUpdateWidget',
      caseSensitive: false,
    ).hasMatch(node.name.lexeme)) {
      return;
    }
    final work = _Awaits();
    node.body.accept(work);
    if (work.expressions.isEmpty) return;
    rows.add({
      'source': path,
      'line': '\n'.allMatches(source.substring(0, node.offset)).length + 1,
      'method': node.name.lexeme,
      'awaits': work.expressions,
      'needsReview':
          work.expressions.length > 1 ||
          work.expressions.any(
            (value) => RegExp(
              r'Future.wait|ensureLoaded|load.*Names|Count|count',
            ).hasMatch(value),
          ),
    });
  }
}

class _Awaits extends RecursiveAstVisitor<void> {
  final expressions = <String>[];
  @override
  void visitAwaitExpression(AwaitExpression node) {
    final text = node.expression.toSource().replaceAll(RegExp(r'\s+'), ' ');
    expressions.add(text.length > 220 ? '${text.substring(0, 220)}…' : text);
    super.visitAwaitExpression(node);
  }
}
