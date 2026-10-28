import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/features/employee/models/employee_api_models.dart';
import 'package:uten_imp/features/employee/models/employee_duplicate_archive.dart';
import 'package:uten_imp/features/employee/repositories/employee_repository.dart';
import 'package:uten_imp/features/employee/widgets/employee_duplicate_archive_dialog.dart';

const preview = EmployeeDuplicateArchivePreview(
  sourceId: 'duplicate',
  sourceCode: 'D01',
  sourceName: '同名员工',
  sourceVersion: 3,
  retainedId: 'retained',
  retainedCode: 'R01',
  retainedName: '同名员工',
  retainedVersion: 7,
);

class _Repository extends Fake
    implements EmployeeRepository, EmployeeDuplicateArchiveRepository {
  EmployeeDuplicateArchivePreview result = preview;
  bool failWrite = false;
  int writes = 0, reads = 0;
  bool conflictAcknowledged = false;
  VoidCallback? onRead;
  @override
  Future<EmployeeDuplicateArchivePreview> previewDuplicateArchive(
    String id,
    String retainedCode,
  ) async => result;
  @override
  Future<String> archiveDuplicate(
    String id,
    EmployeeDuplicateArchivePreview preview,
    String reason, {
    bool documentConflictVerified = false,
  }) async {
    writes++;
    conflictAcknowledged = documentConflictVerified;
    if (failWrite) throw Exception('response lost');
    return 'retained';
  }

  @override
  Future<EmployeeProfile> getById(String id) async {
    reads++;
    onRead?.call();
    return EmployeeProfile(
      id: 'retained',
      code: 'R01',
      fullName: '同名员工',
      resolvedFromEmployeeId: id,
    );
  }
}

Future<List<String?>> _open(
  WidgetTester tester,
  _Repository repository, {
  bool Function()? isCurrent,
}) async {
  final result = <String?>[];
  await tester.pumpWidget(
    MaterialApp(
      locale: const Locale('zh'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(
        body: Builder(
          builder: (context) => TextButton(
            onPressed: () async {
              result.add(
                await showDialog<String>(
                  context: context,
                  builder: (_) => EmployeeDuplicateArchiveDialog(
                    employeeId: 'duplicate',
                    employeeCode: 'D01',
                    repository: repository,
                    isCurrent: isCurrent ?? () => true,
                  ),
                ),
              );
            },
            child: const Text('打开'),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('打开'));
  await tester.pumpAndSettle();
  return result;
}

Future<void> inspect(WidgetTester tester) async {
  await tester.enterText(
    find.byKey(const ValueKey('duplicate-retained-code')),
    'R01',
  );
  await tester.pump();
  await tester.tap(find.text('核对两份档案'));
  await tester.pumpAndSettle();
}

Future<void> verify(WidgetTester tester) async {
  await tester.enterText(
    find.byKey(const ValueKey('duplicate-verification-reason')),
    '已核对本人证件原件与入职记录',
  );
  await tester.ensureVisible(
    find.byKey(const ValueKey('duplicate-identity-verified')),
  );
  await tester.tap(find.byKey(const ValueKey('duplicate-identity-verified')));
  await tester.pump();
}

void main() {
  testWidgets(
    'requires two reviewed identities and explicit verification before archive',
    (tester) async {
      final repository = _Repository();
      final result = await _open(tester, repository);
      expect(
        tester
            .widget<FilledButton>(
              find.byKey(const ValueKey('duplicate-archive-confirm')),
            )
            .onPressed,
        isNull,
      );
      await inspect(tester);
      expect(find.text('归档：同名员工（D01）'), findsOneWidget);
      expect(find.text('保留：同名员工（R01）'), findsOneWidget);
      expect(
        tester
            .widget<FilledButton>(
              find.byKey(const ValueKey('duplicate-archive-confirm')),
            )
            .onPressed,
        isNull,
      );
      await verify(tester);
      await tester.tap(find.byKey(const ValueKey('duplicate-archive-confirm')));
      await tester.pumpAndSettle();
      expect(repository.writes, 1);
      expect(result, ['retained']);
    },
  );
  testWidgets('live-account and responsibility blockers prevent confirmation', (
    tester,
  ) async {
    final repository = _Repository()
      ..result = const EmployeeDuplicateArchivePreview(
        sourceId: 'duplicate',
        sourceCode: 'D01',
        sourceName: '同名员工',
        sourceVersion: 3,
        retainedId: 'retained',
        retainedCode: 'R01',
        retainedName: '同名员工',
        retainedVersion: 7,
        blockers: ['当前档案仍有登录账号，请保留有账号的档案'],
      );
    await _open(tester, repository);
    await inspect(tester);
    expect(find.text('当前档案仍有登录账号，请保留有账号的档案'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('duplicate-identity-verified')),
      findsNothing,
    );
    expect(repository.writes, 0);
  });
  testWidgets(
    'lost response reads the archive result without replaying the write',
    (tester) async {
      final repository = _Repository()..failWrite = true;
      final result = await _open(tester, repository);
      await inspect(tester);
      await verify(tester);
      await tester.tap(find.byKey(const ValueKey('duplicate-archive-confirm')));
      await tester.pumpAndSettle();
      expect(find.text('核对归档结果'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('duplicate-archive-confirm')),
        findsNothing,
      );
      await tester.tap(find.text('核对归档结果'));
      await tester.pumpAndSettle();
      expect(repository.writes, 1);
      expect(repository.reads, 1);
      expect(result, ['retained']);
    },
  );
  testWidgets(
    'different format-valid document facts need their own original-document review',
    (tester) async {
      final repository = _Repository()
        ..result = const EmployeeDuplicateArchivePreview(
          sourceId: 'duplicate',
          sourceCode: 'D01',
          sourceName: '同名员工',
          sourceVersion: 3,
          retainedId: 'retained',
          retainedCode: 'R01',
          retainedName: '同名员工',
          retainedVersion: 7,
          documentConflict: true,
        );
      await _open(tester, repository);
      await inspect(tester);
      await verify(tester);
      expect(
        tester
            .widget<FilledButton>(
              find.byKey(const ValueKey('duplicate-archive-confirm')),
            )
            .onPressed,
        isNull,
      );
      await tester.ensureVisible(
        find.byKey(const ValueKey('duplicate-document-conflict-verified')),
      );
      await tester.tap(
        find.byKey(const ValueKey('duplicate-document-conflict-verified')),
      );
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('duplicate-archive-confirm')));
      await tester.pumpAndSettle();
      expect(repository.writes, 1);
      expect(repository.conflictAcknowledged, isTrue);
    },
  );
  testWidgets(
    'authorization refresh while checking a lost response closes the stale reader',
    (tester) async {
      var current = true;
      final repository = _Repository()
        ..failWrite = true
        ..onRead = () => current = false;
      final results = await _open(tester, repository, isCurrent: () => current);
      await inspect(tester);
      await verify(tester);
      await tester.tap(find.byKey(const ValueKey('duplicate-archive-confirm')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('核对归档结果'));
      await tester.pumpAndSettle();
      expect(repository.writes, 1);
      expect(repository.reads, 1);
      expect(results, [null]);
      expect(
        find.byKey(const ValueKey('employee-duplicate-archive-dialog')),
        findsNothing,
      );
    },
  );
  testWidgets(
    'operator change after review cannot submit the previous operation',
    (tester) async {
      var current = true;
      final repository = _Repository();
      await _open(tester, repository, isCurrent: () => current);
      await inspect(tester);
      await verify(tester);
      current = false;
      await tester.tap(find.byKey(const ValueKey('duplicate-archive-confirm')));
      await tester.pumpAndSettle();
      expect(repository.writes, 0);
    },
  );
}
