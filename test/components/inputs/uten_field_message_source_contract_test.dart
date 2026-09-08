import 'dart:io';

import 'package:analyzer/dart/analysis/utilities.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/visitor.dart';
import 'package:flutter_test/flutter_test.dart';

const _adapterPath = 'lib/components/inputs/uten_input_decoration.dart';

String _callName(Expression expression) => switch (expression) {
  InstanceCreationExpression() => expression.constructorName.type.name2.lexeme,
  MethodInvocation() => expression.methodName.name,
  _ => '',
};

// These shared decorators preserve copyWith/applyDefaults and only add borders
// or autofill metadata. Follow their first argument, never an arbitrary helper.
bool _isAdaptedDecoration(Expression? expression) {
  if (expression == null) return false;
  if (_callName(expression) == 'UtenInputDecoration') return true;
  if (expression is MethodInvocation &&
      const {
        'applyRequiredEmpty',
        'applyAutofillHint',
      }.contains(expression.methodName.name)) {
    final arguments = expression.argumentList.arguments;
    return arguments.isNotEmpty && _isAdaptedDecoration(arguments.first);
  }
  return false;
}

class _FieldMessageContractVisitor extends RecursiveAstVisitor<void> {
  _FieldMessageContractVisitor(this.path);

  final String path;
  final violations = <String>[];
  var textFormFields = 0;
  var messageDecorations = 0;

  void _report(AstNode node, String message) {
    violations.add('$path:${node.offset}: $message');
  }

  bool _insideDecorationAdapter(AstNode node) {
    for (
      var ancestor = node.parent;
      ancestor != null;
      ancestor = ancestor.parent
    ) {
      if (ancestor is Expression &&
          _callName(ancestor) == 'UtenInputDecoration') {
        return true;
      }
      if (ancestor is Statement ||
          ancestor is FunctionBody ||
          ancestor is FunctionExpression) {
        return false;
      }
    }
    return false;
  }

  bool _hasFieldLabel(Expression expression) {
    final visitor = _FieldLabelVisitor();
    expression.accept(visitor);
    return visitor.found;
  }

  void _checkCall(Expression expression, ArgumentList arguments) {
    final name = _callName(expression);
    final named = <String, Expression>{
      for (final argument in arguments.arguments.whereType<NamedExpression>())
        argument.name.label.name: argument.expression,
    };
    if (name == 'TextFormField') {
      textFormFields++;
      final decoration = named['decoration'];
      if (!_isAdaptedDecoration(decoration)) {
        _report(expression, 'TextFormField requires UtenInputDecoration.');
      }
      final builder = named['errorBuilder'];
      if (builder is! SimpleIdentifier ||
          builder.name != 'utenTextFieldErrorBuilder') {
        _report(
          expression,
          'TextFormField requires utenTextFieldErrorBuilder.',
        );
      }
    }
    if (name == 'InputDecoration') {
      final label = named['label'];
      final hasMessage =
          named.keys.any(
            const {'helper', 'helperText', 'error', 'errorText'}.contains,
          ) ||
          (label != null && _hasFieldLabel(label));
      if (hasMessage) {
        messageDecorations++;
        if (!_insideDecorationAdapter(expression)) {
          _report(
            expression,
            'InputDecoration with messages or fieldLabel requires '
            'UtenInputDecoration.',
          );
        }
      }
    }
  }

  bool _isAdapterForwarding(NamedExpression node) {
    if (path != _adapterPath) return false;
    final name = node.name.label.name;
    final value = node.expression;
    if (value is! SimpleIdentifier || value.name != name) return false;
    final call = node.parent?.parent;
    if (call is! MethodInvocation || call.methodName.name != 'copyWith') {
      return false;
    }
    final target = call.target;
    if (target is! SimpleIdentifier || target.name != 'base') return false;
    final method = node.thisOrAncestorOfType<MethodDeclaration>();
    final owner = method?.thisOrAncestorOfType<ClassDeclaration>();
    return method?.name.lexeme == 'copyWith' &&
        owner?.name.lexeme == 'UtenInputDecoration';
  }

  @override
  void visitNamedExpression(NamedExpression node) {
    final name = node.name.label.name;
    if ((name == 'helperText' || name == 'errorText') &&
        !_isAdapterForwarding(node)) {
      _report(
        node,
        'Raw $name is forbidden; use info or UtenFieldMessage inside '
        'UtenInputDecoration.',
      );
    }
    super.visitNamedExpression(node);
  }

  @override
  void visitInstanceCreationExpression(InstanceCreationExpression node) {
    _checkCall(node, node.argumentList);
    super.visitInstanceCreationExpression(node);
  }

  @override
  void visitMethodInvocation(MethodInvocation node) {
    _checkCall(node, node.argumentList);
    super.visitMethodInvocation(node);
  }
}

class _FieldLabelVisitor extends RecursiveAstVisitor<void> {
  var found = false;

  @override
  void visitMethodInvocation(MethodInvocation node) {
    if (const {'fieldLabel', 'UtenFieldLabel'}.contains(node.methodName.name)) {
      found = true;
    }
    super.visitMethodInvocation(node);
  }

  @override
  void visitInstanceCreationExpression(InstanceCreationExpression node) {
    if (_callName(node) == 'UtenFieldLabel') found = true;
    super.visitInstanceCreationExpression(node);
  }
}

_FieldMessageContractVisitor _inspect(String source, {required String path}) {
  final parsed = parseString(content: source, path: path);
  final visitor = _FieldMessageContractVisitor(path);
  parsed.unit.accept(visitor);
  return visitor;
}

void main() {
  test('known decorators retain the adapter requirement', () {
    final accepted = _inspect('''
      Widget build() => TextFormField(
        errorBuilder: utenTextFieldErrorBuilder,
        decoration: applyRequiredEmpty(
          applyAutofillHint(UtenInputDecoration(InputDecoration()), theme,
            autofilled: true), theme, requiredEmpty: false));
    ''', path: 'lib/example.dart');
    expect(accepted.violations, isEmpty);
    final rejected = _inspect('''
      Widget build() => TextFormField(
        errorBuilder: utenTextFieldErrorBuilder,
        decoration: applyRequiredEmpty(InputDecoration(), theme,
          requiredEmpty: false));
    ''', path: 'lib/example.dart');
    expect(rejected.violations, hasLength(1));
  });

  test('all lib form fields keep guidance and errors inside the field', () {
    final violations = <String>[];
    var textFormFields = 0;
    var messageDecorations = 0;
    final dartFiles = Directory('lib')
        .listSync(recursive: true)
        .whereType<File>()
        .where((file) => file.path.endsWith('.dart'));

    for (final file in dartFiles) {
      final visitor = _inspect(
        file.readAsStringSync(),
        path: file.path.replaceAll(r'\', '/'),
      );
      violations.addAll(visitor.violations);
      textFormFields += visitor.textFormFields;
      messageDecorations += visitor.messageDecorations;
    }

    expect(textFormFields, greaterThan(0));
    expect(messageDecorations, greaterThan(0));
    expect(
      violations,
      isEmpty,
      reason:
          'Every TextFormField needs UtenInputDecoration and '
          'utenTextFieldErrorBuilder. InputDecoration with helper/error or '
          'fieldLabel must be inside UtenInputDecoration. Raw helperText/errorText '
          'is allowed only for exact adapter copyWith forwarding.\n'
          '${violations.join('\n')}',
    );
  });

  test('contract detects omissions per call without counting comments', () {
    final visitor = _inspect('''
      void build() {
        // TextFormField(errorBuilder: utenTextFieldErrorBuilder)
        final description = 'helperText: TextFormField(';
        TextFormField();
        TextFormField(
          decoration: InputDecoration(),
          errorBuilder: utenTextFieldErrorBuilder,
        );
      }
    ''', path: 'lib/example.dart');
    expect(visitor.textFormFields, 2);
    expect(visitor.violations, hasLength(3));
  });

  test(
    'contract requires wrappers for fieldLabel and helper/error messages',
    () {
      final visitor = _inspect('''
      void build() {
        InputDecoration(label: fieldLabel('Amount', theme, info: 'Help'));
        InputDecoration(helper: UtenFieldMessage.autofill('Check'));
        InputDecoration(error: utenFieldError(message));
        UtenInputDecoration(
          applyRequiredEmpty(
            InputDecoration(label: fieldLabel('Amount', theme), error: error),
            theme,
            requiredEmpty: true,
          ),
        );
        TextFormField(
          decoration: const UtenInputDecoration(InputDecoration()),
          errorBuilder: utenTextFieldErrorBuilder,
        );
      }
    ''', path: 'lib/example.dart');
      expect(visitor.messageDecorations, 4);
      expect(visitor.violations, hasLength(3));
    },
  );

  test(
    'adapter raw forwarding is a precise exception without page exemptions',
    () {
      const source = '''
      class UtenInputDecoration {
        copyWith({String? helperText, String? errorText}) {
          return base.copyWith(helperText: helperText, errorText: errorText);
        }
        build() {
          // uten-field-message-exception: raw-message - legacy exception
          return InputDecoration(errorText: 'Error');
        }
      }
    ''';
      final adapter = _inspect(source, path: _adapterPath);
      expect(adapter.violations, hasLength(2));
      final page = _inspect(source, path: 'lib/example.dart');
      expect(page.violations, hasLength(4));
    },
  );
}
