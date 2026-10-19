import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/components/buttons/uten_button.dart';
import 'package:uten_imp/components/feedback/uten_dialog.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/core/network/api_exception.dart';
import 'package:uten_imp/core/network/server_config.dart';
import 'package:uten_imp/core/theme/dark_theme.dart';
import 'package:uten_imp/core/theme/light_theme.dart';
import 'package:uten_imp/features/basic_data/models/goods_operation_history.dart';
import 'package:uten_imp/features/basic_data/repositories/goods_operation_history_repository.dart';
import 'package:uten_imp/features/basic_data/widgets/goods_operation_history_panel.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/auth/session_snapshot_provider.dart';
import 'package:uten_imp/shared/providers/authenticated_scope_provider.dart';

final _permissions = StateProvider<Set<String>>((_) => {Perm.goodsDelete});
final _identity = StateProvider<AuthenticatedScope?>(
  (_) => const AuthenticatedScope(userId: 'reader'),
);
final _superAdmin = StateProvider<bool>((_) => false);

class _Snapshots extends SessionSnapshotNotifier {
  @override
  Future<SessionSnapshot?> build() async {
    return ref.watch(authenticatedScopeProvider) == null
        ? null
        : SessionSnapshot();
  }
}

class _History implements GoodsOperationHistoryRepository {
  GoodsOperationHistory value = GoodsOperationHistory(
    entries: [_entry('latest')],
  );
  final reads = <Completer<GoodsOperationHistory>>[];
  final undos = <(String, int)>[];
  final redos = <(String, int)>[];
  bool deferReads = false;
  Object? commandError;
  Completer<GoodsOperationHistory>? pendingCommand;

  @override
  Future<GoodsOperationHistory> list() {
    final read = Completer<GoodsOperationHistory>();
    reads.add(read);
    if (!deferReads) read.complete(value);
    return read.future;
  }

  Future<GoodsOperationHistory> _result(String id, bool redo) async {
    if (commandError != null) throw commandError!;
    if (pendingCommand != null) return pendingCommand!.future;
    value = GoodsOperationHistory(
      entries: [_entry(id, undone: !redo, canRedo: !redo, version: 8)],
      events: [
        GoodsOperationEvent(
          id: 'event',
          operationId: id,
          action: redo ? 'REDO' : 'UNDO',
          label: '删除货品',
          createdAt: '2026-10-16T02:00:00Z',
        ),
      ],
    );
    return value;
  }

  @override
  Future<GoodsOperationHistory> undo(
    String id, {
    required int expectedVersion,
  }) {
    undos.add((id, expectedVersion));
    return _result(id, false);
  }

  @override
  Future<GoodsOperationHistory> redo(
    String id, {
    required int expectedVersion,
  }) {
    redos.add((id, expectedVersion));
    return _result(id, true);
  }
}

GoodsOperationEntry _entry(
  String id, {
  bool undone = false,
  bool canRedo = false,
  bool canUndo = true,
  int version = 7,
}) => GoodsOperationEntry(
  id: id,
  operationType: 'GOODS_DELETE',
  label: '删除货品',
  summary: '$id: G001 socket, G002 switch',
  createdAt: '2026-10-16T00:00:00Z',
  state: undone ? 'UNDONE' : 'APPLIED',
  version: version,
  affectedCount: 2,
  canUndo: !undone && canUndo,
  canRedo: canRedo,
);

const _applyKey = ValueKey('goods-history-apply');
const _captureKey = ValueKey('goods-history-capture');

Future<ProviderContainer> _pump(
  WidgetTester tester,
  _History history, {
  bool preferRedo = false,
  VoidCallback? onChanged,
  Set<String> permissions = const {Perm.goodsDelete},
  bool readOnly = false,
  Size size = const Size(640, 900),
  double scale = 1,
  String locale = 'zh',
  bool dark = false,
  bool superAdmin = false,
  bool showAsOverlay = false,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        goodsOperationHistoryRepositoryProvider.overrideWithValue(history),
        _permissions.overrideWith((_) => permissions),
        currentPermissionsProvider.overrideWith(
          (ref) => ref.watch(_permissions),
        ),
        _identity.overrideWith(
          (_) => AuthenticatedScope(userId: 'reader', readOnly: readOnly),
        ),
        authenticatedScopeProvider.overrideWith((ref) => ref.watch(_identity)),
        _superAdmin.overrideWith((_) => superAdmin),
        isSuperAdminProvider.overrideWith((ref) => ref.watch(_superAdmin)),
        apiBaseUrlProvider.overrideWithValue('https://company.invalid/api'),
        sessionSnapshotProvider.overrideWith(_Snapshots.new),
      ],
      child: MaterialApp(
        theme: dark ? buildDarkTheme() : buildLightTheme(),
        locale: Locale(locale),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: TextScaler.linear(scale)),
          child: child!,
        ),
        home: RepaintBoundary(
          key: _captureKey,
          child: Scaffold(
            body: showAsOverlay
                ? Builder(
                    builder: (context) => TextButton(
                      onPressed: () => showGoodsOperationHistory(
                        context,
                        preferRedo: preferRedo,
                        onChanged: onChanged ?? () {},
                      ),
                      child: const Text('Open operation history'),
                    ),
                  )
                : GoodsOperationHistoryPanel(
                    preferRedo: preferRedo,
                    onChanged: onChanged ?? () {},
                  ),
          ),
        ),
      ),
    ),
  );
  await tester.pump();
  await tester.pump();
  if (showAsOverlay) {
    await tester.tap(find.text('Open operation history'));
    await tester.pump();
    await tester.pump();
  }
  if (!history.deferReads) await tester.pumpAndSettle();
  return ProviderScope.containerOf(
    tester.element(find.byType(GoodsOperationHistoryPanel)),
  );
}

Future<void> _confirm(WidgetTester tester, String label) async {
  await tester.tap(find.widgetWithText(FilledButton, label));
  await tester.pump();
}

Future<void> _capture(WidgetTester tester, String name) async {
  if (Platform.environment['GOODS_HISTORY_SCREENSHOTS'] != '1') return;
  final boundary = tester.renderObject<RenderRepaintBoundary>(
    find.byKey(_captureKey),
  );
  await tester.runAsync(() async {
    final image = await boundary.toImage();
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    final file = File('output/goods-history/$name.png');
    await file.parent.create(recursive: true);
    await file.writeAsBytes(bytes!.buffer.asUint8List());
    image.dispose();
  });
}

void main() {
  setUpAll(() async {
    final loader = FontLoader('NotoSansSC')
      ..addFont(rootBundle.load('assets/fonts/NotoSansSC.ttf'));
    await loader.load();
  });

  test('history entry is available for every supported write permission', () {
    expect(canOpenGoodsOperationHistory({Perm.goodsView}), isFalse);
    expect(canOpenGoodsOperationHistory({Perm.goodsDelete}), isTrue);
    expect(canOpenGoodsOperationHistory({Perm.goodsNameEnEdit}), isTrue);
    expect(canOpenGoodsOperationHistory({Perm.goodsBomAudit}), isTrue);
    expect(canOpenGoodsOperationHistory({Perm.materialCategoryDelete}), isTrue);
  });

  testWidgets('select any operation, cancel confirmation, then confirm once', (
    tester,
  ) async {
    final history = _History()
      ..value = GoodsOperationHistory(
        entries: [_entry('latest'), _entry('older')],
      );
    var changes = 0;
    await _pump(tester, history, onChanged: () => changes++);
    await tester.tap(find.byKey(const ValueKey('goods-history-entry-older')));
    await tester.pump();
    await tester.tap(find.byKey(_applyKey));
    await tester.pumpAndSettle();
    expect(find.byType(UtenAlertDialog), findsOneWidget);
    expect(
      find.descendant(
        of: find.byType(UtenAlertDialog),
        matching: find.text('older: G001 socket, G002 switch'),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: find.byType(UtenAlertDialog),
        matching: find.text('2026-10-16 08:00'),
      ),
      findsOneWidget,
    );
    expect(find.text('撤回“删除货品”，影响 2 条资料。确认撤回？'), findsOneWidget);
    expect(history.undos, isEmpty);
    await tester.tap(find.widgetWithText(TextButton, '取消'));
    await tester.pumpAndSettle();
    expect(history.undos, isEmpty);
    expect(changes, 0);

    await tester.tap(find.byKey(_applyKey));
    await tester.pumpAndSettle();
    await _confirm(tester, '撤回');
    await tester.pumpAndSettle();
    expect(history.undos, [('older', 7)]);
    expect(changes, 1);
    expect(find.text('已撤回'), findsOneWidget);
    expect(find.text('撤回：删除货品'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'redo also confirms and uses the last undo chosen by the server',
    (tester) async {
      final history = _History()
        ..value = GoodsOperationHistory(
          entries: [
            _entry('latest'),
            _entry('last-undo', undone: true, canRedo: true, version: 9),
          ],
        );
      var changes = 0;
      await _pump(
        tester,
        history,
        preferRedo: true,
        onChanged: () => changes++,
      );
      await tester.tap(find.byKey(_applyKey));
      await tester.pumpAndSettle();
      expect(find.text('取消上次对“删除货品”的撤回，恢复 2 条资料。确认取消撤回？'), findsOneWidget);
      expect(history.redos, isEmpty);
      await tester.tap(find.widgetWithText(TextButton, '取消'));
      await tester.pumpAndSettle();
      expect(history.redos, isEmpty);
      await tester.tap(find.byKey(_applyKey));
      await tester.pumpAndSettle();
      await _confirm(tester, '取消撤回');
      await tester.pumpAndSettle();
      expect(history.redos, [('last-undo', 9)]);
      expect(changes, 1);
      expect(find.text('取消撤回：删除货品'), findsOneWidget);
    },
  );

  testWidgets('pending command disables repeat submissions and refresh', (
    tester,
  ) async {
    final history = _History()
      ..pendingCommand = Completer<GoodsOperationHistory>();
    await _pump(tester, history);
    await tester.tap(find.byKey(_applyKey));
    await tester.pumpAndSettle();
    await _confirm(tester, '撤回');
    await tester.pump(const Duration(milliseconds: 300));
    expect(history.undos, [('latest', 7)]);
    expect(tester.widget<UtenButton>(find.byKey(_applyKey)).onPressed, isNull);
    expect(
      tester
          .widget<TextButton>(
            find.byKey(const ValueKey('goods-history-refresh')),
          )
          .onPressed,
      isNull,
    );
    history.pendingCommand!.complete(
      GoodsOperationHistory(
        entries: [_entry('latest', undone: true, canRedo: true)],
      ),
    );
    await tester.pumpAndSettle();
    expect(history.undos, hasLength(1));
  });

  testWidgets('redo entry does not offer undo when no undo can be redone', (
    tester,
  ) async {
    final history = _History();
    await _pump(tester, history, preferRedo: true);
    expect(
      find.descendant(of: find.byKey(_applyKey), matching: find.text('取消撤回')),
      findsOneWidget,
    );
    expect(tester.widget<UtenButton>(find.byKey(_applyKey)).onPressed, isNull);
    expect(find.text('已选中'), findsNothing);
  });

  testWidgets('failure retains history and requires refresh before retry', (
    tester,
  ) async {
    final history = _History()
      ..commandError = ApiException('CONFLICT', '资料已被修改');
    await _pump(tester, history);
    await tester.tap(find.byKey(_applyKey));
    await tester.pumpAndSettle();
    await _confirm(tester, '撤回');
    await tester.pumpAndSettle();
    expect(find.text('latest: G001 socket, G002 switch'), findsOneWidget);
    expect(find.textContaining('资料已被修改'), findsWidgets);
    expect(tester.widget<UtenButton>(find.byKey(_applyKey)).onPressed, isNull);
    history.commandError = null;
    await tester.tap(find.byKey(const ValueKey('goods-history-refresh')));
    await tester.pumpAndSettle();
    expect(
      tester.widget<UtenButton>(find.byKey(_applyKey)).onPressed,
      isNotNull,
    );
    expect(history.undos, hasLength(1));
    expect(history.reads, hasLength(2));
  });

  testWidgets('late history from an old identity cannot replace new history', (
    tester,
  ) async {
    final history = _History()..deferReads = true;
    final container = await _pump(tester, history);
    expect(history.reads, hasLength(1));
    container.read(_identity.notifier).state = const AuthenticatedScope(
      userId: 'other',
    );
    await tester.pump();
    await tester.pump();
    await tester.pump();
    expect(history.reads, hasLength(2));
    history.reads.last.complete(
      GoodsOperationHistory(entries: [_entry('new-reader')]),
    );
    await tester.pumpAndSettle();
    history.reads.first.complete(
      GoodsOperationHistory(entries: [_entry('old-reader')]),
    );
    await tester.pumpAndSettle();
    expect(find.text('new-reader: G001 socket, G002 switch'), findsOneWidget);
    expect(find.text('old-reader: G001 socket, G002 switch'), findsNothing);
  });

  testWidgets(
    'permission revocation during confirmation prevents the command',
    (tester) async {
      final history = _History();
      final container = await _pump(tester, history);
      await tester.tap(find.byKey(_applyKey));
      await tester.pumpAndSettle();
      container.read(_permissions.notifier).state = {Perm.goodsView};
      await tester.pumpAndSettle();
      expect(find.widgetWithText(FilledButton, '撤回'), findsNothing);
      expect(find.text('操作权限已更新'), findsWidgets);
      expect(history.undos, isEmpty);
    },
  );

  testWidgets(
    'read-only identity cannot submit an otherwise reversible entry',
    (tester) async {
      final history = _History();
      await _pump(tester, history, readOnly: true);
      expect(
        tester.widget<UtenButton>(find.byKey(_applyKey)).onPressed,
        isNull,
      );
      expect(history.undos, isEmpty);
    },
  );

  testWidgets(
    'revoking one write permission fences history while another remains',
    (tester) async {
      final history = _History();
      final container = await _pump(
        tester,
        history,
        permissions: {Perm.goodsDelete, Perm.goodsEdit},
      );
      history.deferReads = true;
      container.read(_permissions.notifier).state = {Perm.goodsEdit};
      await tester.pump();
      await tester.pump();
      expect(find.text('latest: G001 socket, G002 switch'), findsNothing);
      expect(
        tester.widget<UtenButton>(find.byKey(_applyKey)).onPressed,
        isNull,
      );
      expect(history.reads, hasLength(2));
      history.reads.last.complete(
        GoodsOperationHistory(entries: [_entry('rechecked', canUndo: false)]),
      );
      await tester.pumpAndSettle();
      expect(find.text('rechecked: G001 socket, G002 switch'), findsOneWidget);
      expect(
        tester.widget<UtenButton>(find.byKey(_applyKey)).onPressed,
        isNull,
      );
      expect(history.undos, isEmpty);
    },
  );

  testWidgets('no write permission does not fetch operation history', (
    tester,
  ) async {
    final history = _History();
    await _pump(tester, history, permissions: {Perm.goodsView});
    expect(history.reads, isEmpty);
    expect(find.text('当前没有可查看的货品操作权限。'), findsOneWidget);
  });

  testWidgets(
    'partial permission revocation invalidates an open confirmation',
    (tester) async {
      final history = _History();
      final container = await _pump(
        tester,
        history,
        permissions: {Perm.goodsDelete, Perm.goodsEdit},
      );
      await tester.tap(find.byKey(_applyKey));
      await tester.pumpAndSettle();
      history.value = GoodsOperationHistory(
        entries: [_entry('rechecked', canUndo: false)],
      );
      container.read(_permissions.notifier).state = {Perm.goodsEdit};
      await tester.pumpAndSettle();
      expect(find.widgetWithText(FilledButton, '撤回'), findsNothing);
      expect(find.text('操作权限已更新'), findsWidgets);
      expect(history.undos, isEmpty);
      expect(history.reads, hasLength(2));
    },
  );

  testWidgets('partial permission revocation drops a pending POST response', (
    tester,
  ) async {
    final history = _History()
      ..pendingCommand = Completer<GoodsOperationHistory>();
    var changes = 0;
    final container = await _pump(
      tester,
      history,
      permissions: {Perm.goodsDelete, Perm.goodsEdit},
      onChanged: () => changes++,
    );
    await tester.tap(find.byKey(_applyKey));
    await tester.pumpAndSettle();
    await _confirm(tester, '撤回');
    history.value = GoodsOperationHistory(
      entries: [_entry('rechecked', canUndo: false)],
    );
    container.read(_permissions.notifier).state = {Perm.goodsEdit};
    await tester.pumpAndSettle();
    history.pendingCommand!.complete(
      GoodsOperationHistory(
        entries: [_entry('old-command-result', undone: true, canRedo: true)],
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('rechecked: G001 socket, G002 switch'), findsOneWidget);
    expect(
      find.text('old-command-result: G001 socket, G002 switch'),
      findsNothing,
    );
    expect(find.text('所选操作已撤回，已记录本次撤回。'), findsNothing);
    expect(changes, 0);
    expect(history.undos, hasLength(1));
  });

  testWidgets('switching A to B while confirming closes the old confirmation', (
    tester,
  ) async {
    final history = _History();
    final container = await _pump(tester, history);
    await tester.tap(find.byKey(_applyKey));
    await tester.pumpAndSettle();
    history.value = GoodsOperationHistory(entries: [_entry('user-B')]);
    container.read(_identity.notifier).state = const AuthenticatedScope(
      userId: 'B',
    );
    await tester.pumpAndSettle();
    expect(find.widgetWithText(FilledButton, '撤回'), findsNothing);
    expect(find.text('latest: G001 socket, G002 switch'), findsNothing);
    expect(find.text('user-B: G001 socket, G002 switch'), findsOneWidget);
    expect(history.undos, isEmpty);
  });

  testWidgets(
    'switching A to B during POST cannot replace B history or notify B',
    (tester) async {
      final history = _History()
        ..pendingCommand = Completer<GoodsOperationHistory>();
      var changes = 0;
      final container = await _pump(
        tester,
        history,
        onChanged: () => changes++,
      );
      await tester.tap(find.byKey(_applyKey));
      await tester.pumpAndSettle();
      await _confirm(tester, '撤回');
      history.value = GoodsOperationHistory(entries: [_entry('user-B')]);
      container.read(_identity.notifier).state = const AuthenticatedScope(
        userId: 'B',
      );
      await tester.pumpAndSettle();
      history.pendingCommand!.complete(
        GoodsOperationHistory(
          entries: [_entry('user-A-result', undone: true, canRedo: true)],
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('user-B: G001 socket, G002 switch'), findsOneWidget);
      expect(
        find.text('user-A-result: G001 socket, G002 switch'),
        findsNothing,
      );
      expect(find.text('所选操作已撤回，已记录本次撤回。'), findsNothing);
      expect(changes, 0);
      expect(history.undos, hasLength(1));
    },
  );

  testWidgets(
    'logout and login to the same account reject the pre-logout read',
    (tester) async {
      final history = _History()..deferReads = true;
      final container = await _pump(tester, history);
      expect(history.reads, hasLength(1));
      container.read(_identity.notifier).state = null;
      await tester.pump();
      await tester.pump();
      expect(find.text('当前登录身份无效，原页面信息已隐藏'), findsOneWidget);
      container.read(_identity.notifier).state = const AuthenticatedScope(
        userId: 'reader',
      );
      await tester.pump();
      await tester.pump();
      await tester.pump();
      expect(history.reads, hasLength(2));
      history.reads.last.complete(
        GoodsOperationHistory(entries: [_entry('after-login')]),
      );
      await tester.pumpAndSettle();
      history.reads.first.complete(
        GoodsOperationHistory(entries: [_entry('before-logout')]),
      );
      await tester.pumpAndSettle();
      expect(
        find.text('after-login: G001 socket, G002 switch'),
        findsOneWidget,
      );
      expect(
        find.text('before-logout: G001 socket, G002 switch'),
        findsNothing,
      );
    },
  );

  testWidgets(
    'same account losing superadmin status rechecks its capabilities',
    (tester) async {
      final history = _History();
      final container = await _pump(tester, history, superAdmin: true);
      await tester.tap(find.byKey(_applyKey));
      await tester.pumpAndSettle();
      history.value = GoodsOperationHistory(
        entries: [_entry('ordinary-user', canUndo: false)],
      );
      container.read(_superAdmin.notifier).state = false;
      await tester.pumpAndSettle();
      expect(find.widgetWithText(FilledButton, '撤回'), findsNothing);
      expect(find.text('操作权限已更新'), findsWidgets);
      expect(history.undos, isEmpty);
      expect(history.reads, hasLength(2));
    },
  );

  testWidgets(
    'superadmin switching to read-only ordinary identity loses its confirmation',
    (tester) async {
      final history = _History();
      final container = await _pump(tester, history, superAdmin: true);
      await tester.tap(find.byKey(_applyKey));
      await tester.pumpAndSettle();
      history.value = GoodsOperationHistory(entries: [_entry('ordinary-user')]);
      container.read(_identity.notifier).state = const AuthenticatedScope(
        userId: 'ordinary',
        actorId: 'admin',
        readOnly: true,
      );
      container.read(_superAdmin.notifier).state = false;
      await tester.pumpAndSettle();
      expect(find.widgetWithText(FilledButton, '撤回'), findsNothing);
      expect(
        find.text('ordinary-user: G001 socket, G002 switch'),
        findsOneWidget,
      );
      expect(
        tester.widget<UtenButton>(find.byKey(_applyKey)).onPressed,
        isNull,
      );
      expect(history.undos, isEmpty);
    },
  );

  testWidgets(
    'two refreshes completed in reverse order keep the newest history',
    (tester) async {
      final history = _History();
      await _pump(tester, history);
      history.deferReads = true;
      final refresh = tester
          .widget<TextButton>(
            find.byKey(const ValueKey('goods-history-refresh')),
          )
          .onPressed!;
      refresh();
      refresh();
      await tester.pump();
      expect(history.reads, hasLength(3));
      history.reads[2].complete(
        GoodsOperationHistory(entries: [_entry('newest-refresh')]),
      );
      await tester.pumpAndSettle();
      history.reads[1].complete(
        GoodsOperationHistory(entries: [_entry('stale-refresh')]),
      );
      await tester.pumpAndSettle();
      expect(
        find.text('newest-refresh: G001 socket, G002 switch'),
        findsOneWidget,
      );
      expect(
        find.text('stale-refresh: G001 socket, G002 switch'),
        findsNothing,
      );
    },
  );

  testWidgets(
    'timeout waits for readback and does not replay a committed undo',
    (tester) async {
      final history = _History()..commandError = NetworkTimeoutException();
      await _pump(tester, history);
      await tester.tap(find.byKey(_applyKey));
      await tester.pumpAndSettle();
      await _confirm(tester, '撤回');
      await tester.pumpAndSettle();
      expect(history.undos, hasLength(1));
      expect(
        tester.widget<UtenButton>(find.byKey(_applyKey)).onPressed,
        isNull,
      );
      history.value = GoodsOperationHistory(
        entries: [_entry('latest', undone: true, canRedo: true, version: 8)],
      );
      await tester.tap(find.byKey(const ValueKey('goods-history-refresh')));
      await tester.pumpAndSettle();
      expect(history.undos, hasLength(1));
      expect(history.redos, isEmpty);
      expect(find.text('已撤回'), findsOneWidget);
      expect(
        find.descendant(of: find.byKey(_applyKey), matching: find.text('取消撤回')),
        findsOneWidget,
      );
      expect(
        tester.widget<UtenButton>(find.byKey(_applyKey)).onPressed,
        isNotNull,
      );
    },
  );

  testWidgets('rapid repeated confirmation does not pop the history panel', (
    tester,
  ) async {
    final history = _History();
    await _pump(tester, history, showAsOverlay: true);
    final openConfirmation = tester
        .widget<UtenButton>(find.byKey(_applyKey))
        .onPressed!;
    openConfirmation();
    openConfirmation();
    await tester.pumpAndSettle();
    expect(find.byType(UtenAlertDialog), findsOneWidget);
    final confirm = tester
        .widget<FilledButton>(find.widgetWithText(FilledButton, '撤回'))
        .onPressed!;
    confirm();
    confirm();
    await tester.pumpAndSettle();
    expect(history.undos, hasLength(1));
    expect(find.byType(GoodsOperationHistoryPanel), findsOneWidget);
    expect(find.text('已撤回'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('equivalent permission sets do not discard accepted history', (
    tester,
  ) async {
    final history = _History();
    final container = await _pump(tester, history);
    container.read(_permissions.notifier).state = {Perm.goodsDelete};
    await tester.pumpAndSettle();
    expect(history.reads, hasLength(1));
    expect(find.text('latest: G001 socket, G002 switch'), findsOneWidget);
    expect(
      tester.widget<UtenButton>(find.byKey(_applyKey)).onPressed,
      isNotNull,
    );
  });

  testWidgets('wide history keeps descriptive text and action layout', (
    tester,
  ) async {
    final history = _History()
      ..value = GoodsOperationHistory(
        entries: [
          _entry('latest'),
          _entry('older', undone: true, canRedo: true),
        ],
      );
    await _pump(tester, history);
    expect(find.text('影响 2 条'), findsNWidgets(2));
    expect(tester.takeException(), isNull);
    await _capture(tester, 'wide-zh');
  });

  testWidgets('events outside the ten operation entries keep English labels', (
    tester,
  ) async {
    final history = _History()
      ..value = GoodsOperationHistory(
        entries: [_entry('latest')],
        events: const [
          GoodsOperationEvent(
            id: 'old-event',
            operationId: 'outside-window',
            action: 'REDO',
            operationType: 'GOODS_PURCHASE_POLICY',
            label: '修改货品采购收货方式',
            createdAt: '2026-10-15T00:00:00Z',
          ),
        ],
      );
    await _pump(tester, history, locale: 'en');
    expect(
      find.text('Redo last undo: Edit goods purchase receipt policy'),
      findsOneWidget,
    );
    expect(find.text('修改货品采购收货方式'), findsNothing);
  });

  for (final locale in ['zh', 'en']) {
    testWidgets(
      '$locale narrow 320px at 200 percent supports scrolling and confirmation',
      (tester) async {
        final history = _History()
          ..value = GoodsOperationHistory(
            entries: [_entry('latest'), _entry('older')],
          );
        await _pump(
          tester,
          history,
          size: const Size(320, 800),
          scale: 2,
          locale: locale,
          dark: locale == 'en',
        );
        expect(tester.takeException(), isNull);
        await _capture(tester, 'narrow-200-$locale');
        await tester.tap(find.byKey(_applyKey));
        await tester.pumpAndSettle();
        expect(find.byType(UtenAlertDialog), findsOneWidget);
        expect(tester.takeException(), isNull);
        await tester.tap(
          find.widgetWithText(TextButton, locale == 'en' ? 'Cancel' : '取消'),
        );
        await tester.pumpAndSettle();
        expect(history.undos, isEmpty);
      },
    );
  }
}
