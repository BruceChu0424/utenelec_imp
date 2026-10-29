import 'dart:convert';
import 'dart:io';

import 'package:analyzer/dart/analysis/utilities.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/visitor.dart';
import 'package:crypto/crypto.dart';

const _buttons = {
  'TextButton',
  'OutlinedButton',
  'FilledButton',
  'ElevatedButton',
  'IconButton',
  'RawMaterialButton',
  'CupertinoButton',
  'CupertinoDialogAction',
  'UtenButton',
  'UtenActionButton',
  'UtenAppBarActionButton',
  'PopupMenuItem',
  'InkWell',
  'InkResponse',
  'GestureDetector',
};
const _unified = {
  'UtenCloseButton',
  'UtenWindowControlButton',
  'UtenWindowControls',
  'UtenDialogHeader',
  'UtenAlertDialog',
  'UtenPanelHeader',
  'UtenFloatingWindow',
};
const _rawCloseIcons = {
  'close',
  'close_rounded',
  'close_outlined',
  'close_sharp',
  'clear',
  'clear_rounded',
  'clear_outlined',
  'clear_sharp',
  'cancel',
  'cancel_rounded',
  'cancel_outlined',
  'cancel_sharp',
  'highlight_off',
  'highlight_off_rounded',
  'highlight_off_outlined',
  'xmark',
  'xmark_circle',
  'xmark_circle_fill',
  'clear_circled',
  'clear_circled_solid',
};
const _closeWords = {'关闭', 'close', '닫기'};
const _dismissWords = {'知道了', 'got it', '谢谢小优'};
const _glyphs = {'×', '✕', '✖', '✗', '╳'};

String normalizedWindowControlSource(AstNode node) =>
    node.toSource().replaceAll(RegExp(r'\s+'), ' ').trim();

class WindowControlFinding {
  WindowControlFinding({
    required this.kind,
    required this.path,
    required this.owner,
    required this.line,
    required this.source,
  }) : fingerprint = sha256.convert(utf8.encode(source)).toString();
  final String kind, path, owner, source, fingerprint;
  final int line;
  String get identity => '$kind|$path|$owner|$fingerprint';
  Map<String, Object> toJson() => {
    'kind': kind,
    'path': path,
    'owner': owner,
    'line': line,
    'fingerprint': fingerprint,
    'source': source,
  };
}

class WindowControlException {
  const WindowControlException({
    required this.kind,
    required this.path,
    required this.owner,
    required this.fingerprint,
    required this.count,
    required this.reason,
  });
  factory WindowControlException.fromJson(Map<String, dynamic> value) =>
      WindowControlException(
        kind: value['kind'] as String,
        path: value['path'] as String,
        owner: value['owner'] as String,
        fingerprint: value['fingerprint'] as String,
        count: value['count'] as int,
        reason: value['reason'] as String,
      );
  final String kind, path, owner, fingerprint, reason;
  final int count;
  String get identity => '$kind|$path|$owner|$fingerprint';
  Map<String, Object> toJson() => {
    'kind': kind,
    'path': path,
    'owner': owner,
    'fingerprint': fingerprint,
    'count': count,
    'reason': reason,
  };
}

class WindowControlAuditResult {
  WindowControlAuditResult({
    required this.findings,
    required this.inventory,
    required this.exceptions,
    required this.parseErrors,
    required this.sourceFileCount,
  });
  final List<WindowControlFinding> findings;
  final List<Map<String, Object?>> inventory;
  final List<WindowControlException> exceptions;
  final List<String> parseErrors;
  final int sourceFileCount;
  Map<String, List<WindowControlFinding>> get _grouped {
    final grouped = <String, List<WindowControlFinding>>{};
    for (final finding in findings) {
      grouped.putIfAbsent(finding.identity, () => []).add(finding);
    }
    return grouped;
  }

  List<WindowControlFinding> get violations {
    final approved = {for (final e in exceptions) e.identity: e};
    return [
      for (final entry in _grouped.entries)
        if (approved[entry.key]?.count != entry.value.length ||
            (approved[entry.key]?.reason.trim().isEmpty ?? true))
          ...entry.value,
    ];
  }

  List<WindowControlException> get staleExceptions {
    final grouped = _grouped;
    return [
      for (final e in exceptions)
        if (grouped[e.identity]?.length != e.count || e.reason.trim().isEmpty)
          e,
    ];
  }

  bool get passed =>
      violations.isEmpty && staleExceptions.isEmpty && parseErrors.isEmpty;
  Map<String, Object?> toJson() => {
    'passed': passed,
    'sourceFileCount': sourceFileCount,
    'parseErrors': parseErrors,
    'violations': [for (final f in violations) f.toJson()],
    'exceptions': [for (final e in exceptions) e.toJson()],
    'staleExceptions': [for (final e in staleExceptions) e.toJson()],
    'inventory': inventory,
    'limits': [
      'Static source policy, not proof of visual position or runtime behavior.',
      'System-owned pickers and third-party internals are outside lib source.',
      'Dynamic labels and custom painting require manual review and UI tests.',
    ],
  };
}

({String type, String? constructor, ArgumentList arguments})? _call(
  AstNode node,
) {
  if (node is InstanceCreationExpression) {
    return (
      type: node.constructorName.type
          .toSource()
          .split('<')
          .first
          .split('.')
          .last,
      constructor: node.constructorName.name?.name,
      arguments: node.argumentList,
    );
  }
  if (node is MethodInvocation) {
    final target = node.target?.toSource();
    if (target != null && RegExp(r'^[A-Z]\w*(?:<.*>)?$').hasMatch(target)) {
      return (
        type: target.split('<').first,
        constructor: node.methodName.name,
        arguments: node.argumentList,
      );
    }
    return (
      type: node.methodName.name,
      constructor: null,
      arguments: node.argumentList,
    );
  }
  return null;
}

Map<String, Expression> _named(ArgumentList args) => {
  for (final arg in args.arguments.whereType<NamedExpression>())
    arg.name.label.name: arg.expression,
};

String _owner(AstNode node) {
  String? type, member;
  for (AstNode? p = node.parent; p != null; p = p.parent) {
    if (member == null && p is MethodDeclaration) member = p.name.lexeme;
    if (member == null && p is FunctionDeclaration) member = p.name.lexeme;
    if (p is ClassDeclaration) {
      type = p.name.lexeme;
      break;
    }
    if (p is MixinDeclaration) {
      type = p.name.lexeme;
      break;
    }
    if (p is ExtensionDeclaration) {
      type = p.name?.lexeme ?? 'extension';
      break;
    }
  }
  return [?type, ?member].join('.');
}

AstNode _visualContext(AstNode node) {
  AstNode? visual;
  for (AstNode? p = node.parent; p != null; p = p.parent) {
    if (p is Statement || p is MethodDeclaration || p is FunctionDeclaration) {
      break;
    }
    final call = _call(p);
    if (call != null) {
      visual ??= p;
      if (_buttons.contains(call.type)) return p;
    }
    if (p is SwitchExpressionCase || p is MapLiteralEntry) return visual ?? p;
  }
  return visual ?? node.parent ?? node;
}

class _Variables extends RecursiveAstVisitor<void> {
  final variables = <VariableDeclaration>[];
  @override
  void visitVariableDeclaration(VariableDeclaration node) {
    variables.add(node);
    super.visitVariableDeclaration(node);
  }
}

class _Placement {
  const _Placement({
    this.close = false,
    this.widget = false,
    this.unknown = false,
    this.bad = false,
    this.review = false,
    this.aligned = true,
  });
  final bool close, widget, unknown, bad, review, aligned;
}

class _Collector extends RecursiveAstVisitor<void> {
  _Collector(
    this.path,
    this.closeKeys,
    this.acknowledgementKeys,
    this.variables,
    this.line,
  );
  final String path;
  final Set<String> closeKeys;
  final Set<String> acknowledgementKeys;
  final List<VariableDeclaration> variables;
  final int Function(int) line;
  final findings = <WindowControlFinding>[];
  final inventory = <Map<String, Object?>>[];
  final _seen = <String>{};
  void add(String kind, AstNode node) {
    final context = kind == 'raw-close-icon' || kind == 'raw-cross-glyph'
        ? _visualContext(node)
        : node;
    final identity = '$kind:${context.offset}:${context.end}';
    if (!_seen.add(identity)) return;
    findings.add(
      WindowControlFinding(
        kind: kind,
        path: path,
        owner: _owner(context),
        line: line(context.offset),
        source: normalizedWindowControlSource(context),
      ),
    );
  }

  bool labelIsClose(
    Expression? expression, {
    int depth = 0,
    bool acknowledgement = false,
  }) {
    if (expression == null || depth > 10) return false;
    if (expression is ParenthesizedExpression) {
      return labelIsClose(
        expression.expression,
        depth: depth + 1,
        acknowledgement: acknowledgement,
      );
    }
    if (expression is SimpleStringLiteral) {
      return (acknowledgement ? _dismissWords : _closeWords).contains(
            expression.value.trim().toLowerCase(),
          ) ||
          (!acknowledgement && _glyphs.contains(expression.value.trim()));
    }
    if (expression is ConditionalExpression) {
      return labelIsClose(
            expression.thenExpression,
            depth: depth + 1,
            acknowledgement: acknowledgement,
          ) ||
          labelIsClose(
            expression.elseExpression,
            depth: depth + 1,
            acknowledgement: acknowledgement,
          );
    }
    if (expression is BinaryExpression && expression.operator.lexeme == '??') {
      return labelIsClose(
            expression.leftOperand,
            depth: depth + 1,
            acknowledgement: acknowledgement,
          ) ||
          labelIsClose(
            expression.rightOperand,
            depth: depth + 1,
            acknowledgement: acknowledgement,
          );
    }
    final identifier = switch (expression) {
      final PrefixedIdentifier e => e.identifier.name,
      final PropertyAccess e => e.propertyName.name,
      final SimpleIdentifier e => e.name,
      _ => null,
    };
    if (identifier != null) {
      if ((acknowledgement ? acknowledgementKeys : closeKeys).contains(
        identifier,
      )) {
        return true;
      }
      if (expression is SimpleIdentifier) {
        final declarations = variables
            .where(
              (v) =>
                  v.name.lexeme == identifier &&
                  v.offset < expression.offset &&
                  _owner(v) == _owner(expression),
            )
            .toList();
        if (declarations.isNotEmpty) {
          return labelIsClose(
            declarations.last.initializer,
            depth: depth + 1,
            acknowledgement: acknowledgement,
          );
        }
      }
      return false;
    }
    final call = _call(expression);
    if (call == null) return false;
    // Nested dialogs, content or another button are not this button's label.
    if (_buttons.contains(call.type) || _unified.contains(call.type)) {
      return false;
    }
    final named = _named(call.arguments);
    final positional = call.arguments.arguments.where(
      (a) => a is! NamedExpression,
    );
    if (call.type == 'Text' || call.type == 'SelectableText') {
      return positional.isNotEmpty &&
          labelIsClose(
            positional.first,
            depth: depth + 1,
            acknowledgement: acknowledgement,
          );
    }
    if (call.type == 'TextSpan') {
      return labelIsClose(
        named['text'],
        depth: depth + 1,
        acknowledgement: acknowledgement,
      );
    }
    if ({
      'Padding',
      'Align',
      'Center',
      'SizedBox',
      'Container',
      'FittedBox',
      'DefaultTextStyle',
      'RichText',
    }.contains(call.type)) {
      return labelIsClose(
        named['child'] ?? named['text'],
        depth: depth + 1,
        acknowledgement: acknowledgement,
      );
    }
    if ({'Row', 'Wrap'}.contains(call.type)) {
      final children = named['children'];
      return children is ListLiteral &&
          children.elements.whereType<Expression>().any(
            (e) => labelIsClose(
              e,
              depth: depth + 1,
              acknowledgement: acknowledgement,
            ),
          );
    }
    // Localization helpers: r('close'), priceText(context,'close'), _t('close').
    if (expression is MethodInvocation) {
      bool helperTag(Expression argument) {
        if (argument is ConditionalExpression) {
          return helperTag(argument.thenExpression) ||
              helperTag(argument.elseExpression);
        }
        if (argument is! SimpleStringLiteral) return false;
        final value = argument.value.trim().toLowerCase();
        return (acknowledgement ? _dismissWords : _closeWords).contains(
              value,
            ) ||
            (acknowledgement && call.type == '_t' && value == 'infodone');
      }

      return positional.any(helperTag) ||
          (!acknowledgement &&
              RegExp(r'^_?close(?:Label|Text)?$').hasMatch(call.type));
    }
    return false;
  }

  bool _directClose(Expression? expression) {
    if (expression is ConditionalExpression) {
      return _directClose(expression.thenExpression) ||
          _directClose(expression.elseExpression);
    }
    if (expression == null) return false;
    final call = _call(expression);
    if (call == null) return false;
    if ({'UtenCloseButton', 'UtenWindowControls'}.contains(call.type)) {
      return true;
    }
    if ({
      'Padding',
      'Align',
      'Center',
      'SizedBox',
      'Container',
      'Flexible',
      'Expanded',
      'Tooltip',
      'Semantics',
    }.contains(call.type)) {
      return _directClose(_named(call.arguments)['child']);
    }
    return false;
  }

  bool _rightAligned(Expression expression) {
    if (!_directClose(expression)) return true;
    if (expression is ConditionalExpression) {
      return _rightAligned(expression.thenExpression) &&
          _rightAligned(expression.elseExpression);
    }
    final call = _call(expression)!;
    final named = _named(call.arguments);
    if ({'Align', 'Container'}.contains(call.type) &&
        RegExp(
          r'(?:topRight|centerRight|bottomRight|topEnd|centerEnd|bottomEnd)$',
        ).hasMatch(named['alignment']?.toSource() ?? '')) {
      return true;
    }
    final child = named['child'];
    return child != null && _rightAligned(child);
  }

  _Placement _element(CollectionElement element) {
    if (element is Expression) {
      return _Placement(
        close: _directClose(element),
        widget: true,
        aligned: _rightAligned(element),
      );
    }
    if (element is IfElement) {
      final yes = _element(element.thenElement);
      final no = element.elseElement == null
          ? const _Placement()
          : _element(element.elseElement!);
      return _Placement(
        close: yes.close || no.close,
        widget: yes.widget || no.widget,
        unknown: yes.unknown || no.unknown,
        bad: yes.bad || no.bad,
        review: yes.review || no.review,
        aligned: yes.aligned && no.aligned,
      );
    }
    if (element is SpreadElement) {
      final value = element.expression;
      if (value is ListLiteral) return _sequence(value.elements);
      return const _Placement(widget: true, unknown: true);
    }
    if (element is ForElement) {
      final body = _element(element.body);
      return _Placement(
        close: body.close,
        widget: true,
        unknown: true,
        bad: body.bad,
        review: body.close || body.review,
        aligned: body.aligned,
      );
    }
    return const _Placement(widget: true, unknown: true);
  }

  _Placement _sequence(Iterable<CollectionElement> elements) {
    var close = false, hasWidget = false, unknown = false;
    var bad = false, review = false, aligned = true;
    for (final element in elements) {
      final next = _element(element);
      bad = bad || next.bad || (close && next.widget && !next.unknown);
      review = review || next.review || (close && next.unknown);
      close = close || next.close;
      hasWidget = hasWidget || next.widget;
      unknown = unknown || next.unknown;
      aligned = aligned && next.aligned;
    }
    return _Placement(
      close: close,
      widget: hasWidget,
      unknown: unknown,
      bad: bad,
      review: review,
      aligned: aligned,
    );
  }

  void visitCall(AstNode node) {
    final call = _call(node);
    if (call == null) return;
    final named = _named(call.arguments);
    if (_unified.contains(call.type)) {
      inventory.add({
        'kind': 'unified-control',
        'path': path,
        'owner': _owner(node),
        'line': line(node.offset),
        'component': call.type,
        'constructor': call.constructor,
        'guards': {
          for (final entry in named.entries)
            if ({
              'onClose',
              'onPressed',
              'showCloseButton',
              'closeEnabled',
              'closeButtonKey',
              'showMinimize',
              'showExpand',
            }.contains(entry.key))
              entry.key: normalizedWindowControlSource(entry.value),
        },
      });
    }
    if ({
      'CloseButton',
      'CloseButtonIcon',
      'CupertinoCloseButton',
    }.contains(call.type)) {
      add('raw-close-constructor', node);
    }
    if (!_unified.contains(call.type) &&
        (_buttons.contains(call.type) ||
            named.containsKey('onPressed') ||
            named.containsKey('onTap') ||
            named.containsKey('onAction'))) {
      final label =
          named['label'] ??
          named['child'] ??
          (call.type == 'IconButton' ? named['tooltip'] : null);
      if (labelIsClose(label) || labelIsClose(label, acknowledgement: true)) {
        add('semantic-close-button', node);
      }
    }
    final children = named['children'];
    if ({'Row', 'Column'}.contains(call.type) &&
        children is ListLiteral &&
        _owner(node).split('.').first != 'UtenWindowControls') {
      final sequence = _sequence(children.elements);
      if (call.type == 'Row' && sequence.bad) {
        add('close-not-rightmost', node);
      } else if (sequence.review ||
          (call.type == 'Column' && sequence.close && !sequence.aligned) ||
          (call.type == 'Row' &&
              sequence.close &&
              named['mainAxisAlignment']?.toSource() ==
                  'MainAxisAlignment.center')) {
        add('close-alignment-review', node);
      }
    }
    if (node is MethodInvocation &&
        {'alert', 'show', 'notifyAlert'}.contains(node.methodName.name)) {
      for (final role in ['confirm', 'cancel']) {
        final label = named['${role}Label'];
        if ((labelIsClose(label) ||
                labelIsClose(label, acknowledgement: true)) &&
            named['${role}AsClose']?.toSource() != 'true') {
          add('semantic-close-helper-choice', node);
        }
      }
      if (named.containsKey('confirmAsClose') ||
          named.containsKey('cancelAsClose')) {
        inventory.add({
          'kind': 'close-choice-helper',
          'path': path,
          'owner': _owner(node),
          'line': line(node.offset),
          'confirmAsClose': named['confirmAsClose']?.toSource(),
          'cancelAsClose': named['cancelAsClose']?.toSource(),
        });
      }
    }
  }

  @override
  void visitInstanceCreationExpression(InstanceCreationExpression node) {
    visitCall(node);
    super.visitInstanceCreationExpression(node);
  }

  @override
  void visitMethodInvocation(MethodInvocation node) {
    visitCall(node);
    super.visitMethodInvocation(node);
  }

  @override
  void visitNamedExpression(NamedExpression node) {
    if (node.name.label.name == 'leading') {
      final visitor = _LeadingClose();
      node.expression.accept(visitor);
      if (visitor.found) add('left-close-control', node);
    }
    super.visitNamedExpression(node);
  }

  @override
  void visitPrefixedIdentifier(PrefixedIdentifier node) {
    if ({'Icons', 'Symbols', 'CupertinoIcons'}.contains(node.prefix.name) &&
        _rawCloseIcons.contains(node.identifier.name)) {
      add('raw-close-icon', node);
    }
    super.visitPrefixedIdentifier(node);
  }

  @override
  void visitPropertyAccess(PropertyAccess node) {
    if (RegExp(
          r'(?:^|\.)(?:Icons|Symbols|CupertinoIcons)$',
        ).hasMatch(node.target?.toSource() ?? '') &&
        _rawCloseIcons.contains(node.propertyName.name)) {
      add('raw-close-icon', node);
    }
    super.visitPropertyAccess(node);
  }

  @override
  void visitSimpleStringLiteral(SimpleStringLiteral node) {
    if (_glyphs.contains(node.value.trim())) add('raw-cross-glyph', node);
    super.visitSimpleStringLiteral(node);
  }
}

class _LeadingClose extends RecursiveAstVisitor<void> {
  bool found = false;
  void check(AstNode node) {
    if ({
      'UtenCloseButton',
      'UtenWindowControls',
      'CloseButton',
      'CupertinoCloseButton',
    }.contains(_call(node)?.type)) {
      found = true;
    }
  }

  @override
  void visitInstanceCreationExpression(InstanceCreationExpression node) {
    check(node);
    super.visitInstanceCreationExpression(node);
  }

  @override
  void visitMethodInvocation(MethodInvocation node) {
    check(node);
    super.visitMethodInvocation(node);
  }
}

WindowControlAuditResult auditWindowControlSources({
  required Map<String, String> sources,
  Set<String> closeKeys = const {'releaseNotesClose'},
  Set<String> acknowledgementKeys = const {
    'celebrationDismiss',
    'aiChatInfoDone',
    'wmSetupOpeningGuideOk',
  },
  List<WindowControlException> exceptions = const [],
}) {
  final findings = <WindowControlFinding>[];
  final inventory = <Map<String, Object?>>[];
  final errors = <String>[];
  for (final entry in sources.entries) {
    final path = entry.key.replaceAll('\\', '/');
    final parsed = parseString(
      content: entry.value,
      path: path,
      throwIfDiagnostics: false,
    );
    if (parsed.errors.any((e) => e.errorCode.errorSeverity.name == 'ERROR')) {
      errors.add(path);
    }
    if (path.contains('/l10n/gen/')) {
      inventory.add({'kind': 'generated-translations', 'path': path});
      continue;
    }
    final declarations = _Variables();
    parsed.unit.accept(declarations);
    final collector = _Collector(
      path,
      closeKeys,
      acknowledgementKeys,
      declarations.variables,
      (offset) => parsed.lineInfo.getLocation(offset).lineNumber,
    );
    parsed.unit.accept(collector);
    findings.addAll(collector.findings);
    inventory.addAll(collector.inventory);
  }
  return WindowControlAuditResult(
    findings: findings,
    inventory: inventory,
    exceptions: exceptions,
    parseErrors: errors,
    sourceFileCount: sources.length,
  );
}

WindowControlAuditResult auditWindowControlsRepository({
  String root = 'lib',
  String exceptionPath = 'scripts/window_controls_exceptions.json',
}) {
  final closeKeys = <String>{'releaseNotesClose'};
  final acknowledgementKeys = <String>{};
  for (final file in Directory('lib/core/l10n').listSync().whereType<File>()) {
    if (!file.path.endsWith('.arb')) continue;
    final messages =
        jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
    for (final entry in messages.entries) {
      if (!entry.key.startsWith('@') &&
          entry.value is String &&
          _closeWords.contains((entry.value as String).trim().toLowerCase())) {
        closeKeys.add(entry.key);
      }
      if (!entry.key.startsWith('@') &&
          entry.value is String &&
          _dismissWords.contains(
            (entry.value as String).trim().toLowerCase(),
          )) {
        acknowledgementKeys.add(entry.key);
      }
    }
  }
  final exceptions = File(exceptionPath).existsSync()
      ? (jsonDecode(File(exceptionPath).readAsStringSync()) as List)
            .cast<Map<String, dynamic>>()
            .map(WindowControlException.fromJson)
            .toList()
      : <WindowControlException>[];
  final sources = <String, String>{};
  final files =
      Directory(root)
          .listSync(recursive: true)
          .whereType<File>()
          .where((f) => f.path.endsWith('.dart'))
          .toList()
        ..sort((a, b) => a.path.compareTo(b.path));
  for (final file in files) {
    sources[file.path] = file.readAsStringSync();
  }
  return auditWindowControlSources(
    sources: sources,
    closeKeys: closeKeys,
    acknowledgementKeys: acknowledgementKeys,
    exceptions: exceptions,
  );
}

void main(List<String> args) {
  stdout.encoding = utf8;
  String? value(String flag) {
    final index = args.indexOf(flag);
    return index >= 0 && index + 1 < args.length ? args[index + 1] : null;
  }

  final result = auditWindowControlsRepository(
    root: value('--root') ?? 'lib',
    exceptionPath:
        value('--exceptions') ?? 'scripts/window_controls_exceptions.json',
  );
  final output = const JsonEncoder.withIndent('  ').convert(result.toJson());
  final target = value('--json');
  if (target != null) {
    File(target).parent.createSync(recursive: true);
    File(target).writeAsStringSync('$output\n');
  }
  stdout.writeln(
    'Window controls: ${result.sourceFileCount} source files, '
    '${result.violations.length} unclassified controls, '
    '${result.staleExceptions.length} stale exceptions, '
    '${result.parseErrors.length} parse errors.',
  );
  if (target == null) stdout.writeln(output);
  exitCode = result.passed ? 0 : 1;
}
