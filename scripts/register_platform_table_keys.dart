// One-time AST-guided registration; use --write to apply only missing keys.
import 'dart:io';
import 'dart:convert';
import 'package:analyzer/dart/analysis/utilities.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/visitor.dart';

const supported = {
  'MasterDataTableView',
  'UtenEditableGrid',
  'UtenRevisionTable',
};
const canonical = <String, String>{
  'features/sales/pages/sales_doc_edit_page.dart':
      r"'sales.${widget.docType.name}.items'",
  'features/sales/pages/sales_doc_detail_page.dart':
      r"'sales.${widget.docType.name}.items'",
  'features/sales/pages/sales_doc_list_page.dart':
      r"'sales.${widget.docType.name}.list'",
  'features/purchase/pages/purchase_doc_edit_page.dart':
      r"'purchase.${widget.docType.name}.items'",
  'features/purchase/pages/purchase_doc_detail_page.dart':
      r"'purchase.${widget.docType.name}.items'",
  'features/purchase/pages/purchase_doc_list_page.dart':
      r"'purchase.${widget.docType.name}.list'",
  'features/purchase/pages/purchase_order_edit_page.dart':
      "'purchase.order.items'",
  'features/subcontract/pages/subcontract_doc_edit_page.dart':
      r"'subcontract.${widget.docType.name}.items'",
  'features/subcontract/pages/subcontract_doc_detail_page.dart':
      r"'subcontract.${widget.docType.name}.items'",
  'features/subcontract/pages/subcontract_order_edit_page.dart':
      "'subcontract.order.items'",
  'features/finance/pages/finance_doc_edit_page.dart':
      r"'finance.${widget.docType.name}.items'",
  'features/finance/pages/finance_doc_detail_page.dart':
      r"'finance.${widget.docType.name}.items'",
  'features/finance/pages/finance_doc_list_page.dart':
      r"'finance.${widget.docType.name}.list'",
  'features/finance/pages/finance_quote_review_page.dart':
      "'sales.quote.items'",
  'features/finance/pages/finance_sales_order_review_page.dart':
      "'sales.order.items'",
  'features/finance/pages/finance_sales_order_confirmation_page.dart':
      "'sales.order.items'",
  'features/warehouse/pages/stock_doc_edit_page.dart':
      r"'warehouse.${widget.docType.name}.items'",
  'features/warehouse/pages/stock_doc_detail_page.dart':
      r"'warehouse.${widget.docType.name}.items'",
  'features/warehouse/pages/stock_doc_list_page.dart':
      r"'warehouse.${widget.docType.name}.list'",
  'features/production/pages/production_plan_edit_page.dart':
      "'production.plan.items'",
  'features/production/pages/production_plan_list_page.dart':
      "'production.plan.list'",
  'features/production/pages/production_daily_report_edit_page.dart':
      "'production.daily.items'",
  'features/production/pages/production_daily_report_detail_page.dart':
      "'production.daily.items'",
  'features/production/pages/production_daily_report_list_page.dart':
      "'production.daily.list'",
};

class Register extends RecursiveAstVisitor<void> {
  Register(this.path, this.source);
  final String path, source;
  final edits = <(int, String)>[];
  final counts = <String, int>{};

  void inspect(AstNode node, String type, ArgumentList args) {
    if (!supported.contains(type)) return;
    if (args.arguments.whereType<NamedExpression>().any(
      (a) => a.name.label.name == 'tableKey',
    )) {
      return;
    }
    String owner = 'table';
    String member = 'build';
    for (AstNode? p = node.parent; p != null; p = p.parent) {
      if (p is MethodDeclaration && member == 'build') member = p.name.lexeme;
      if (p is FunctionDeclaration && member == 'build') member = p.name.lexeme;
      if (p is ClassDeclaration) {
        owner = p.name.lexeme;
        break;
      }
    }
    final family = '$owner.$member.$type';
    final ordinal = counts.update(family, (n) => n + 1, ifAbsent: () => 1);
    final fallback =
        '${path.replaceAll('.dart', '').replaceAll('/', '.')}.${owner.replaceAll('_', '')}.$member.$ordinal';
    // Comparison/history tables are a separate projection, never a live-record editor.
    final key = type != 'UtenRevisionTable' && ordinal == 1
        ? canonical[path] ?? "'$fallback'"
        : "'$fallback'";
    final offset = args.leftParenthesis.end;
    final lineStart = source.lastIndexOf('\n', node.offset) + 1;
    final indent = RegExp(
      r'^\s*',
    ).firstMatch(source.substring(lineStart, node.offset))!.group(0)!;
    edits.add((offset, '\n$indent  tableKey: $key,'));
  }

  @override
  void visitInstanceCreationExpression(InstanceCreationExpression node) {
    inspect(
      node,
      node.constructorName.type.toSource().split('<').first.split('.').last,
      node.argumentList,
    );
    super.visitInstanceCreationExpression(node);
  }

  @override
  void visitMethodInvocation(MethodInvocation node) {
    inspect(node, node.methodName.name, node.argumentList);
    super.visitMethodInvocation(node);
  }
}

void main(List<String> args) {
  var changed = 0;
  final patches = <Map<String, Object>>[];
  for (final file in Directory(
    'lib',
  ).listSync(recursive: true).whereType<File>()) {
    final path = file.path.replaceAll('\\', '/');
    if (!path.endsWith('.dart') ||
        path.startsWith('lib/components/') ||
        path.endsWith('/master_data_table_view.dart') ||
        path.startsWith('lib/shared/platform_tables/')) {
      continue;
    }
    final text = file.readAsStringSync();
    final parsed = parseString(
      content: text,
      path: path,
      throwIfDiagnostics: false,
    );
    final registration = Register(path.substring(4), text);
    parsed.unit.accept(registration);
    if (registration.edits.isEmpty) continue;
    var next = text;
    registration.edits.sort((a, b) => b.$1.compareTo(a.$1));
    for (final edit in registration.edits) {
      next = next.replaceRange(edit.$1, edit.$1, edit.$2);
    }
    if (args.contains('--write')) file.writeAsStringSync(next);
    if (args.contains('--patches')) {
      patches.add({'path': path, 'before': text, 'after': next});
    }
    changed += registration.edits.length;
    if (!args.contains('--patches')) {
      stdout.writeln('$path: ${registration.edits.length}');
    }
  }
  if (args.contains('--patches')) {
    stdout.write(jsonEncode(patches));
  } else {
    stdout.writeln(
      'Registered $changed table keys${args.contains('--write') ? '' : ' (dry run)'}.',
    );
  }
}
