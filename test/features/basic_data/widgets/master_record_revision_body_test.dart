import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/components/feedback/uten_dialog.dart';
import 'package:uten_imp/components/feedback/uten_busy_overlay.dart';
import 'package:uten_imp/components/inputs/uten_search_bar.dart';
import 'package:uten_imp/components/layout/uten_content_scrollbar.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/network/server_config.dart';
import 'package:uten_imp/core/theme/dark_theme.dart';
import 'package:uten_imp/core/theme/light_theme.dart';
import 'package:uten_imp/features/basic_data/repositories/master_record_history_repository.dart';
import 'package:uten_imp/features/basic_data/widgets/master_record_revision_body.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/auth/session_snapshot_provider.dart';
import 'package:uten_imp/shared/providers/authenticated_scope_provider.dart';

final _identity = StateProvider<AuthenticatedScope?>(
  (_) => const AuthenticatedScope(userId: 'reader'),
);

class _Snapshots extends SessionSnapshotNotifier {
  @override
  Future<SessionSnapshot?> build() async =>
      ref.watch(authenticatedScopeProvider) == null ? null : SessionSnapshot();
}

const _revision = MasterRecordRevision(
  id: '8',
  entityType: 'colors',
  recordCode: 'V001',
  recordLabel: '塑胶件',
  action: 'EDIT',
  actorName: '张师傅',
  summary: '修改基础资料',
  recordedAt: '2026-10-22T14:00:00Z',
  expectedHead: '2:12',
  affectedCount: 1,
  changes: [MasterRecordChange('名称', '旧名称', '新名称')],
  canRestoreBefore: true,
  canRestoreAfter: true,
);

class _Repository extends MasterRecordHistoryRepository {
  _Repository({this.revision = _revision}) : super(ApiClient(Dio()));
  final MasterRecordRevision revision;
  final commands = <bool>[];
  final restored = <MasterRecordRevision>[];
  int reads = 0;
  Completer<MasterRecordRevision>? pending;
  Completer<void>? pendingRestore;
  @override
  Future<MasterRecordRevision> detail({
    required String entityType,
    required String id,
  }) async {
    reads++;
    return pending == null ? revision : pending!.future;
  }

  @override
  Future<void> restore({
    required String entityType,
    required MasterRecordRevision revision,
    required bool before,
  }) async {
    commands.add(before);
    restored.add(revision);
    if (pendingRestore != null) await pendingRestore!.future;
  }
}

Future<ProviderContainer> _pump(
  WidgetTester tester,
  _Repository repository, {
  Size size = const Size(900, 900),
  bool dark = false,
  double scale = 1,
  bool settle = true,
  ValueChanged<bool>? onBusyChanged,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        masterRecordHistoryRepositoryProvider.overrideWithValue(repository),
        authenticatedScopeProvider.overrideWith((ref) => ref.watch(_identity)),
        currentPermissionsProvider.overrideWithValue({
          Perm.colorView,
          Perm.colorEdit,
        }),
        apiBaseUrlProvider.overrideWithValue('https://company.invalid/api'),
        sessionSnapshotProvider.overrideWith(_Snapshots.new),
      ],
      child: MaterialApp(
        theme: dark ? buildDarkTheme() : buildLightTheme(),
        locale: const Locale('zh'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: TextScaler.linear(scale)),
          child: child!,
        ),
        home: Scaffold(
          body: MasterRecordRevisionBody(
            entityType: 'colors',
            id: '8',
            onChanged: () {},
            onBusyChanged: onBusyChanged,
          ),
        ),
      ),
    ),
  );
  if (settle) {
    await tester.pumpAndSettle();
  } else {
    await tester.pump();
    await tester.pump();
  }
  return ProviderScope.containerOf(
    tester.element(find.byType(MasterRecordRevisionBody)),
  );
}

void main() {
  MasterRecordRevision manyChanges([int count = 60]) => MasterRecordRevision(
    id: '9',
    entityType: 'colors',
    recordCode: 'V001',
    recordLabel: '塑胶件',
    action: 'EDIT',
    actorName: '张师傅',
    summary: '调整组装信息与仓库',
    recordedAt: '2026-10-22T14:00:00Z',
    expectedHead: '2:12',
    affectedCount: count,
    changes: [
      for (var i = 0; i < count - 1; i++)
        MasterRecordChange('字段 $i', '旧值', '新值'),
      const MasterRecordChange('仓库', '原 A', '新 B'),
    ],
    canRestoreBefore: true,
    canRestoreAfter: true,
  );

  testWidgets(
    'restoration clearance follows actual actions without forcing page overflow',
    (tester) async {
      await _pump(tester, _Repository(revision: manyChanges(12)));
      UtenContentScrollbar scrollbar() => tester.widget<UtenContentScrollbar>(
        find.byKey(const Key('master-revision-scrollbar')),
      );
      expect(scrollbar().bottomInset, lessThan(100));
      expect(scrollbar().controller.position.maxScrollExtent, 0);
      tester.view.physicalSize = const Size(320, 900);
      await tester.pumpAndSettle();
      expect(
        scrollbar().bottomInset,
        greaterThan(100),
        reason: 'Wrapped actions still reserve their complete height',
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'search covers every snapshot field without reloading or narrowing restoration',
    (tester) async {
      final revision = manyChanges();
      final repository = _Repository(revision: revision);
      await _pump(tester, repository);
      expect(
        find.text('仓库'),
        findsNothing,
        reason: 'Rows outside the viewport stay lazy',
      );
      final search = find.descendant(
        of: find.byType(UtenSearchBar),
        matching: find.byType(TextField),
      );
      await tester.enterText(search, '仓库 原 A');
      await tester.pump(const Duration(milliseconds: 350));
      expect(find.text('仓库'), findsOneWidget);
      expect(find.text('原 A'), findsOneWidget);
      expect(find.text('新 B'), findsOneWidget);
      expect(find.text('1 / 60 项'), findsOneWidget);
      expect(repository.reads, 1);
      await tester.tap(find.text('恢复到此次修改前'));
      await tester.pumpAndSettle();
      expect(find.textContaining('涉及 60 条资料与关联记录'), findsWidgets);
      await tester.tap(
        find.descendant(
          of: find.byType(UtenAlertDialog),
          matching: find.byType(FilledButton),
        ),
      );
      await tester.pumpAndSettle();
      expect(repository.restored.single, same(revision));
      expect(repository.restored.single.changes, hasLength(60));
      await tester.enterText(search, '不存在');
      await tester.pump(const Duration(milliseconds: 350));
      expect(
        find.byKey(const Key('master-revision-empty-changes')),
        findsOneWidget,
      );
      expect(find.text('0 / 60 项'), findsOneWidget);
      await tester.enterText(search, '');
      await tester.pump(const Duration(milliseconds: 350));
      expect(find.text('60 项'), findsOneWidget);
      expect(find.text('字段 0'), findsOneWidget);
      expect(
        repository.reads,
        2,
        reason: 'Only the restoration refresh reloads the snapshot',
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'desktop comparison is compact and its visible scrollbar can be dragged',
    (tester) async {
      await _pump(tester, _Repository(revision: manyChanges()));
      expect(
        find.byKey(const Key('master-revision-comparison-header')),
        findsOneWidget,
      );
      expect(
        find.text('修改前'),
        findsOneWidget,
        reason: 'A shared header replaces per-row labels',
      );
      final row0 = tester.getTopLeft(find.text('字段 0')).dy;
      final row1 = tester.getTopLeft(find.text('字段 1')).dy;
      expect(
        row1 - row0,
        lessThan(54),
        reason: 'Ordinary one-line changes no longer consume multiple lines',
      );
      final scrollbar = tester.widget<UtenContentScrollbar>(
        find.byKey(const Key('master-revision-scrollbar')),
      );
      expect(scrollbar.controller.offset, 0);
      final rect = tester.getRect(
        find.byKey(const Key('master-revision-scrollbar')),
      );
      final gesture = await tester.startGesture(
        Offset(rect.right - 8, rect.top + 12),
        kind: PointerDeviceKind.mouse,
      );
      await gesture.moveBy(const Offset(0, 260));
      await tester.pump();
      await gesture.up();
      await tester.pumpAndSettle();
      expect(scrollbar.controller.offset, greaterThan(500));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('blocked reason is visible before a long list of differences', (
    tester,
  ) async {
    final repository = _Repository(
      revision: MasterRecordRevision(
        id: '9',
        entityType: 'colors',
        recordCode: 'V001',
        recordLabel: '塑胶件',
        action: 'EDIT',
        actorName: '张师傅',
        recordedAt: '2026-10-22T14:00:00Z',
        expectedHead: '2:12',
        affectedCount: 1,
        changes: List.generate(
          60,
          (index) => MasterRecordChange('字段 $index', '旧值', '新值'),
        ),
        canRestoreBefore: false,
        canRestoreAfter: false,
        blockedReason: '当前资料已被引用，请先核对关联业务。',
      ),
    );
    await _pump(tester, repository);
    final reason = find.byKey(const Key('master-revision-blocked-reason'));
    expect(reason.hitTestable(), findsOneWidget);
    expect(tester.getTopLeft(reason).dy, lessThan(600));
    expect(find.text('字段 59'), findsNothing);
  });
  testWidgets('restoring before creation explicitly confirms deletion in red', (
    tester,
  ) async {
    final repository = _Repository(
      revision: const MasterRecordRevision(
        id: '9',
        entityType: 'colors',
        recordCode: 'V001',
        recordLabel: '塑胶件',
        action: 'CREATE',
        actorName: '张师傅',
        recordedAt: '2026-10-22T14:00:00Z',
        expectedHead: '1:9',
        affectedCount: 1,
        changes: [MasterRecordChange('名称', '', '塑胶件')],
        canRestoreBefore: true,
        canRestoreAfter: false,
      ),
    );
    await _pump(tester, repository);
    await tester.tap(find.text('恢复到此次修改前'));
    await tester.pumpAndSettle();
    expect(find.textContaining('资料或关联记录将被删除'), findsOneWidget);
    final confirm = find.descendant(
      of: find.byType(UtenAlertDialog),
      matching: find.byType(FilledButton),
    );
    final button = tester.widget<FilledButton>(confirm);
    expect(
      button.style?.backgroundColor?.resolve({}),
      Theme.of(tester.element(confirm)).colorScheme.error,
    );
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(repository.commands, isEmpty);
  });
  testWidgets(
    'revision shows the operator and exact old/new values; cancellation sends no request',
    (tester) async {
      final repository = _Repository();
      await _pump(tester, repository);
      expect(find.text('张师傅'), findsOneWidget);
      expect(find.textContaining('旧名称'), findsOneWidget);
      expect(find.textContaining('新名称'), findsOneWidget);
      await tester.tap(find.text('恢复到此次修改前'));
      await tester.pumpAndSettle();
      expect(find.byType(UtenAlertDialog), findsOneWidget);
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(repository.commands, isEmpty);
    },
  );
  testWidgets(
    'confirmation restores the explicit side once and reports write busy only',
    (tester) async {
      final repository = _Repository(), busy = <bool>[];
      await _pump(tester, repository, onBusyChanged: busy.add);
      expect(busy.contains(true), isFalse);
      await tester.tap(find.text('恢复到此次修改后'));
      await tester.pumpAndSettle();
      expect(busy.last, isTrue);
      await tester.tap(
        find.descendant(
          of: find.byType(UtenAlertDialog),
          matching: find.byType(FilledButton),
        ),
      );
      await tester.pumpAndSettle();
      expect(repository.commands, [false]);
      expect(busy.last, isFalse);
    },
  );
  testWidgets('identity changes discard a pending revision response', (
    tester,
  ) async {
    final repository = _Repository()..pending = Completer();
    final container = await _pump(tester, repository, settle: false);
    container.read(_identity.notifier).state = null;
    await tester.pump();
    repository.pending!.complete(_revision);
    await tester.pumpAndSettle();
    expect(find.textContaining('旧名称'), findsNothing);
    expect(find.text('张师傅'), findsNothing);
  });
  testWidgets(
    'compact dark large text remains readable with floating recovery controls',
    (tester) async {
      await _pump(
        tester,
        _Repository(),
        size: const Size(390, 900),
        dark: true,
        scale: 1.5,
      );
      expect(tester.takeException(), isNull);
      expect(find.text('恢复到此次修改前'), findsOneWidget);
    },
  );
  testWidgets(
    'recovery uses the shared busy overlay only during its write request',
    (tester) async {
      final repository = _Repository()..pendingRestore = Completer();
      await _pump(tester, repository);
      expect(find.byType(UtenBusyOverlay), findsNothing);
      await tester.tap(find.text('恢复到此次修改前'));
      await tester.pumpAndSettle();
      await tester.tap(
        find.descendant(
          of: find.byType(UtenAlertDialog),
          matching: find.byType(FilledButton),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.byType(UtenBusyOverlay), findsOneWidget);
      repository.pendingRestore!.complete();
      await tester.pumpAndSettle();
      expect(find.byType(UtenBusyOverlay), findsNothing);
    },
  );
}
