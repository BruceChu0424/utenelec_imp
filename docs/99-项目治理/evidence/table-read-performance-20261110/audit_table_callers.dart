import 'dart:convert';
import 'dart:io';
import 'package:analyzer/dart/analysis/utilities.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/visitor.dart';

class Calls extends RecursiveAstVisitor<void> {
  Calls(this.path, this.lines, this.output);
  final String path;
  final int Function(int) lines;
  final List<Map<String, Object?>> output;
  @override
  void visitMethodInvocation(MethodInvocation node) {
    if (node.methodName.name == 'MasterDataTableView' && node.target == null) {
      record(
        node.offset,
        'MasterDataTableView${node.typeArguments?.toSource() ?? ''}',
        node.argumentList,
      );
    }
    super.visitMethodInvocation(node);
  }

  @override
  void visitInstanceCreationExpression(InstanceCreationExpression node) {
    final type = node.constructorName.type.toSource();
    if (type.split('<').first == 'MasterDataTableView') {
      record(node.offset, type, node.argumentList);
    }
    super.visitInstanceCreationExpression(node);
  }

  void record(int offset, String type, ArgumentList arguments) {
    final args = <String, String>{};
    for (final arg in arguments.arguments.whereType<NamedExpression>()) {
      final name = arg.name.label.name;
      if (const {
        'items',
        'immutableRows',
        'presentationRevision',
        'rowKeyOf',
        'idOf',
        'rowVisible',
        'unpagedItems',
        'leadingGroups',
        'filterContextRows',
        'unfilteredRows',
        'rowsController',
      }.contains(name)) {
        args[name] = arg.expression.toSource().replaceAll(RegExp(r'\s+'), ' ');
      }
    }
    output.add({
      'path': path,
      'line': lines(offset),
      'type': type,
      'sharedBaseChanges': true,
      'parameters': args,
      'incrementalContract': args.containsKey('immutableRows')
          ? 'explicit-gated'
          : 'conservative-pending-owner-contract-review',
    });
  }
}

void main() {
  final root = Directory.current.path.replaceAll('\\', '/');
  final output = <Map<String, Object?>>[];
  final files =
      Directory('lib')
          .listSync(recursive: true)
          .whereType<File>()
          .where((file) => file.path.endsWith('.dart'))
          .toList()
        ..sort((a, b) => a.path.compareTo(b.path));
  for (final file in files) {
    final source = file.readAsStringSync();
    if (!source.contains('MasterDataTableView')) continue;
    final parsed = parseString(
      content: source,
      path: file.path,
      throwIfDiagnostics: false,
    );
    parsed.unit.accept(
      Calls(
        file.path.replaceAll('\\', '/'),
        (offset) => parsed.lineInfo.getLocation(offset).lineNumber,
        output,
      ),
    );
  }
  final folder = Directory(
    'docs/99-项目治理/evidence/table-read-performance-20261110',
  )..createSync(recursive: true);
  File('${folder.path}/master-table-callers.json').writeAsStringSync(
    const JsonEncoder.withIndent('  ').convert({
      'baseline': '69e35d96bf0ddd9c8ba7992bf0a609ee9191ef98',
      'root': root,
      'method':
          'Dart analyzer AST instance creation and unresolved constructor invocation, lib/**/*.dart',
      'count': output.length,
      'calls': output,
    }),
  );
  final table = StringBuffer('# 公共表格构造调用清单\n\n')
    ..writeln('AST扫描 lib/**/*.dart，排除注释/类型声明；当前共 ${output.length} 个构造调用。')
    ..writeln('全部自动共用公共基础优化。未声明不可变合同不等于不适用；详细审定/未完成项见主回执。\n')
    ..writeln('| 调用位置 | 行类型 | 增量声明 |')
    ..writeln('|---|---|---|');
  for (final row in output) {
    final args = row['parameters'] as Map<String, String>;
    table.writeln(
      '| `${row['path']}:${row['line']}` | `${row['type']}` | '
      '${args.containsKey('immutableRows') ? '显式条件启用' : '保守路径，待所属owner合同核对'} |',
    );
  }
  File(
    '${folder.path}/master-table-callers.md',
  ).writeAsStringSync(table.toString());
  stdout.writeln(
    'callers=${output.length}, explicit=${output.where((row) => (row['parameters'] as Map).containsKey('immutableRows')).length}',
  );
}
