import 'package:flutter_test/flutter_test.dart';

import '../../scripts/audit_window_controls.dart';

WindowControlAuditResult inspect(
  String source, {
  Set<String> closeKeys = const {'releaseNotesClose', 'clientUpdateClose'},
  List<WindowControlException> exceptions = const [],
}) => auditWindowControlSources(
  sources: {'lib/fixture.dart': source},
  closeKeys: closeKeys,
  exceptions: exceptions,
);

void main() {
  for (final label in [
    "const Text('关闭')",
    "const Text('Close')",
    "const Text('닫기')",
    'Text(l10n.clientUpdateClose)',
    "Text(locked ? '关闭' : '取消')",
    "Text(r('close'))",
    'Text(l10n.releaseNotesClose)',
  ]) {
    test('ordinary footer close is rejected for $label', () {
      final result = inspect('''
Widget build() => UtenAlertDialog(actions: [
  TextButton(onPressed: () => Navigator.pop(context), child: $label),
]);
''');
      expect(result.parseErrors, isEmpty);
      expect(
        result.violations.map((f) => f.kind),
        contains('semantic-close-button'),
      );
    });
  }

  test('raw constructor, raw cross icon and left close are rejected', () {
    final result = inspect('''
Widget build() => AppBar(
  leading: Padding(child: UtenCloseButton(onPressed: dismiss)),
  actions: [
    CloseButton(),
    IconButton(onPressed: dismiss, icon: const Icon(Icons.close_rounded)),
  ],
);
''');
    expect(
      result.violations.map((f) => f.kind),
      containsAll([
        'raw-close-constructor',
        'raw-close-icon',
        'left-close-control',
      ]),
    );
  });

  test('nested dialog content is not the outer action own label', () {
    final result = inspect('''
Widget build() => TextButton(
  onPressed: openSomething,
  child: UtenAlertDialog(content: const Text('关闭')),
);
''');
    expect(result.passed, isTrue);
  });

  test('private action wrappers cannot introduce ordinary close labels', () {
    final result = inspect('''
Widget build() => PrivateAction(onTap: dismiss,
  child: Text(r('close')));
''');
    expect(result.violations.single.kind, 'semantic-close-button');
  });

  test('Row collection branches preserve close as the last control', () {
    final bad = inspect('''
Widget build() => Row(children: [
  if (expanded) ...[UtenCloseButton(onPressed: dismiss)],
  TextButton(onPressed: download, child: const Text('下载')),
]);
''');
    expect(bad.violations.map((f) => f.kind), contains('close-not-rightmost'));
    final good = inspect('''
Widget build() => Row(children: [
  TextButton(onPressed: download, child: const Text('下载')),
  if (expanded) UtenCloseButton(onPressed: dismiss)
    else const Text('无预览'),
]);
''');
    expect(good.passed, isTrue);
  });

  test(
    'centered Column close requires alignment review; right aligned passes',
    () {
      final bad = inspect('''
Widget build() => Column(children: [UtenCloseButton(onPressed: dismiss)]);
''');
      expect(bad.violations.single.kind, 'close-alignment-review');
      final good = inspect('''
Widget build() => Column(children: [
  Align(alignment: Alignment.topRight,
    child: UtenCloseButton(onPressed: dismiss)),
]);
''');
      expect(good.passed, isTrue);
    },
  );

  test('choice helper close requires its explicit result-preserving flag', () {
    final bad = inspect('''
void showIt() => UtenNotify.alert(context,
  cancelLabel: l10n.clientUpdateClose, confirmLabel: '撤回');
''');
    expect(bad.violations.single.kind, 'semantic-close-helper-choice');
    final good = inspect('''
void showIt() => UtenNotify.alert(context,
  cancelLabel: l10n.clientUpdateClose, cancelAsClose: true,
  confirmLabel: '撤回');
''');
    expect(good.passed, isTrue);
    expect(good.inventory.single['kind'], 'close-choice-helper');
  });

  test(
    'localized acknowledgements and helper aliases cannot hide dismissers',
    () {
      for (final label in [
        'Text(l10n.celebrationDismiss)',
        "Text(_t(informationOnly ? 'infoDone' : 'confirm'))",
      ]) {
        final result = inspect('''
Widget build() => UtenButton(
  onPressed: () => Navigator.pop(context), child: $label);
''');
        expect(result.violations.single.kind, 'semantic-close-button');
      }
    },
  );

  test(
    'informational helper acknowledgement needs the explicit close role',
    () {
      final bad = inspect('''
void showIt() async {
  await UtenDialog.show(context, title: 'Guide',
    confirmLabel: l10n.wmSetupOpeningGuideOk);
}
''');
      expect(bad.violations.single.kind, 'semantic-close-helper-choice');
      final good = inspect('''
void showIt() async {
  await UtenDialog.show(context, title: 'Guide',
    confirmLabel: l10n.wmSetupOpeningGuideOk, confirmAsClose: true);
}
''');
      expect(good.passed, isTrue);
    },
  );

  test('business acknowledgement requires an exact side-effect exception', () {
    const source = '''
Widget build() => OutlinedButton(onPressed: markRead,
  child: const Text('知道了'));
''';
    final finding = inspect(source).findings.single;
    final exception = WindowControlException(
      kind: finding.kind,
      path: finding.path,
      owner: finding.owner,
      fingerprint: finding.fingerprint,
      count: 1,
      reason: 'Persists an explicit read receipt; it does not only dismiss.',
    );
    expect(inspect(source, exceptions: [exception]).passed, isTrue);
  });

  test('an exception count cannot cover another identical raw action', () {
    const source = '''
Widget build() => Row(children: [
  IconButton(onPressed: clearSearch, icon: const Icon(Icons.close)),
  IconButton(onPressed: clearSearch, icon: const Icon(Icons.close)),
]);
''';
    final findings = inspect(source).findings;
    expect(findings, hasLength(2));
    final finding = findings.first;
    final exception = WindowControlException(
      kind: finding.kind,
      path: finding.path,
      owner: finding.owner,
      fingerprint: finding.fingerprint,
      count: 1,
      reason: 'Only one reviewed search-clear action.',
    );
    final changed = inspect(source, exceptions: [exception]);
    expect(changed.violations, hasLength(2));
    expect(changed.staleExceptions, hasLength(1));
  });

  test('unified close guards are inventoried; Cancel remains a decision', () {
    final result = inspect('''
Widget build() => UtenAlertDialog(
  showCloseButton: true, closeEnabled: !busy, onClose: guardedClose,
  actions: [TextButton(onPressed: () => Navigator.pop(context, false),
    child: const Text('取消'))],
);
''');
    expect(result.passed, isTrue);
    final entry = result.inventory.single;
    expect((entry['guards'] as Map)['closeEnabled'], '!busy');
  });

  test('business close needs exact reviewed fingerprint and count', () {
    const source = '''
Widget build() => UtenButton(onPressed: closeAssetPeriod,
  child: const Text('关闭'));
''';
    final finding = inspect(source).findings.single;
    final exception = WindowControlException(
      kind: finding.kind,
      path: finding.path,
      owner: finding.owner,
      fingerprint: finding.fingerprint,
      count: 1,
      reason: 'Closes an accounting period; this is a business command.',
    );
    expect(inspect(source, exceptions: [exception]).passed, isTrue);
    final changed = inspect(
      source.replaceFirst('closeAssetPeriod', 'dismissWindow'),
      exceptions: [exception],
    );
    expect(changed.violations, hasLength(1));
    expect(changed.staleExceptions, hasLength(1));
  });

  test('new raw icons cannot hide behind a filepath exemption', () {
    const original = '''
Widget build() => IconButton(onPressed: clearSearch,
  icon: const Icon(Icons.close_rounded));
''';
    final finding = inspect(original).findings.single;
    final exception = WindowControlException(
      kind: finding.kind,
      path: finding.path,
      owner: finding.owner,
      fingerprint: finding.fingerprint,
      count: 1,
      reason: 'Clears a search field; it does not close a window.',
    );
    final changed = inspect(
      original.replaceFirst('clearSearch', 'dismissWindow'),
      exceptions: [exception],
    );
    expect(changed.passed, isFalse);
    expect(changed.violations, hasLength(1));
  });

  test('repository window close controls use the public source contract', () {
    final result = auditWindowControlsRepository();
    expect(result.parseErrors, isEmpty);
    expect(
      result.staleExceptions,
      isEmpty,
      reason: 'Remove or re-review changed/deleted exact exceptions.',
    );
    expect(
      result.violations.map((f) => f.toJson()).toList(),
      isEmpty,
      reason:
          'Use the public right-side red close control or a reviewed '
          'business/clear/remove exception with exact owner, AST and count.',
    );
  });
}
