import 'dart:convert';
import 'dart:io';
import 'package:analyzer/dart/analysis/results.dart';
import 'package:analyzer/dart/analysis/utilities.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/visitor.dart';

const tableTypes = {
  'MasterDataTableView',
  'UtenEditableGrid',
  'UtenRevisionTable',
  'DataTable',
  'PaginatedDataTable',
  'DataTable2',
  'PaginatedDataTable2',
  'Table',
  'TableView',
  'UtenPrintTable',
  '_CsvBody',
};
String brief(AstNode node) =>
    node.toSource().replaceAll(RegExp(r'\s+'), ' ').trim();
String? owner(AstNode node, bool member) {
  for (AstNode? p = node.parent; p != null; p = p.parent) {
    if (member && p is MethodDeclaration) return p.name.lexeme;
    if (member && p is FunctionDeclaration) return p.name.lexeme;
    if (!member && p is ClassDeclaration) return p.name.lexeme;
    if (!member && p is MixinDeclaration) return p.name.lexeme;
    if (!member && p is ExtensionDeclaration) return p.name?.lexeme;
  }
  return null;
}

class Collector extends RecursiveAstVisitor<void> {
  Collector(this.path, this.result);
  final String path;
  final ParseStringResult result;
  final List<Map<String, Object?>> tables = [];
  final List<Map<String, Object?>> columns = [];
  final List<Map<String, Object?>> prefs = [];
  int line(AstNode node) => result.lineInfo.getLocation(node.offset).lineNumber;
  @override
  void visitInstanceCreationExpression(InstanceCreationExpression node) {
    final source = node.constructorName.type.toSource();
    final rawType = source.split('<').first;
    final component = rawType.split('.').last;
    final arguments = <String, Object?>{};
    for (final arg
        in node.argumentList.arguments.whereType<NamedExpression>()) {
      arguments[arg.name.label.name] = brief(arg.expression);
    }
    if (tableTypes.contains(component)) {
      tables.add({
        'path': path,
        'line': line(node),
        'endLine': result.lineInfo.getLocation(node.end).lineNumber,
        'component': component,
        'qualifiedType': source,
        'ownerClass': owner(node, false),
        'ownerMember': owner(node, true),
        'arguments': arguments,
      });
    }
    if (component == 'MasterColumnDef' ||
        component == 'EditableGridColumn' ||
        component == 'DataColumn') {
      columns.add({
        'path': path,
        'line': line(node),
        'ownerClass': owner(node, false),
        'ownerMember': owner(node, true),
        'component': component,
        'arguments': arguments,
      });
    }
    super.visitInstanceCreationExpression(node);
  }

  @override
  void visitMethodInvocation(MethodInvocation node) {
    var component = node.methodName.name;
    String prefix = node.target?.toSource() ?? '';
    if (tableTypes.contains(prefix) &&
        {'builder', 'fromTextArray', 'custom'}.contains(component)) {
      component = prefix;
      prefix = '';
    }
    final source =
        '${prefix.isEmpty ? '' : '$prefix.'}$component${node.typeArguments?.toSource() ?? ''}';
    final arguments = <String, Object?>{};
    for (final arg
        in node.argumentList.arguments.whereType<NamedExpression>()) {
      arguments[arg.name.label.name] = brief(arg.expression);
    }
    if (tableTypes.contains(component)) {
      tables.add({
        'path': path,
        'line': line(node),
        'endLine': result.lineInfo.getLocation(node.end).lineNumber,
        'component': component,
        'qualifiedType': source,
        'ownerClass': owner(node, false),
        'ownerMember': owner(node, true),
        'arguments': arguments,
      });
    }
    if (component == 'MasterColumnDef' ||
        component == 'EditableGridColumn' ||
        component == 'DataColumn') {
      columns.add({
        'path': path,
        'line': line(node),
        'ownerClass': owner(node, false),
        'ownerMember': owner(node, true),
        'component': component,
        'arguments': arguments,
      });
    }
    super.visitMethodInvocation(node);
  }

  @override
  void visitNamedExpression(NamedExpression node) {
    if ({
      'prefKey',
      'resourceScope',
      'businessScope',
      'scope',
      'resource',
      'tableScope',
    }.contains(node.name.label.name)) {
      prefs.add({
        'line': line(node),
        'ownerClass': owner(node, false),
        'name': node.name.label.name,
        'value': brief(node.expression),
      });
    }
    super.visitNamedExpression(node);
  }
}

void main(List<String> args) {
  stdout.encoding = utf8;
  final root = Directory(args.isEmpty ? 'lib' : args.first);
  final all = <Map<String, Object?>>[];
  final files =
      root
          .listSync(recursive: true)
          .whereType<File>()
          .where((file) => file.path.endsWith('.dart'))
          .toList()
        ..sort((a, b) => a.path.compareTo(b.path));
  final errors = <String>[];
  for (final file in files) {
    final path = file.path.replaceAll('\\', '/');
    final result = parseString(
      content: file.readAsStringSync(),
      path: path,
      throwIfDiagnostics: false,
    );
    final collector = Collector(path, result);
    result.unit.accept(collector);
    if (result.errors.any((e) => e.errorCode.errorSeverity.name == 'ERROR')) {
      errors.add(path);
    }
    for (final table in collector.tables) {
      table['fileColumns'] = collector.columns;
      table['filePreferences'] = collector.prefs;
      all.add(table);
    }
  }
  stdout.write(
    jsonEncode({
      'sourceFileCount': files.length,
      'parseErrorFiles': errors,
      'calls': all,
    }),
  );
}
