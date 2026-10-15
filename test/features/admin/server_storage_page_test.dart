import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/shared/providers/shared_providers.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/features/admin/models/server_storage.dart';
import 'package:uten_imp/features/admin/pages/server_storage_page.dart';
import 'package:uten_imp/features/admin/providers/server_operations_access.dart';
import 'package:uten_imp/features/admin/providers/server_storage_request_store.dart';
import 'package:uten_imp/features/admin/repositories/server_storage_repository.dart';

void main() {
  testWidgets(
    'legacy uploads have a distinct readable category and protected original files',
    (tester) async {
      final repository = _Repository()..includeLegacy = true;
      await _pump(tester, repository);
      expect(find.text('当前上传目录'), findsOneWidget);
      expect(find.text('兼容旧上传目录'), findsOneWidget);
      await _open(tester, 'LEGACY_UPLOADS');
      expect(find.text('兼容旧上传目录'), findsNWidgets(2));
      expect(find.text('旧上传原件永不物理清理；目录可能同卷或重叠，不应与当前目录直接相加。'), findsOneWidget);
      expect(find.text('兼容旧上传原件永不物理清理'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('storage-select-legacy-original')),
        findsNothing,
      );
      expect(repository.previews, isEmpty);
      expect(repository.cleanups, isEmpty);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  test('new legacy label does not erase future server category labels', () {
    expect(
      ServerStorageCategory.fromJson({
        'kind': 'LEGACY_UPLOADS',
        'label': 'LEGACY_UPLOADS',
      }).displayLabel,
      '兼容旧上传目录',
    );
    expect(
      ServerStorageCategory.fromJson({
        'kind': 'UPLOADS',
        'label': '业务上传',
      }).displayLabel,
      '当前上传目录',
    );
    expect(
      ServerStorageCategory.fromJson({
        'kind': 'FUTURE_KIND',
        'label': '服务器新增分类',
      }).displayLabel,
      '服务器新增分类',
    );
  });

  testWidgets(
    'reopening the page recovers persisted request by GET without another cleanup',
    (tester) async {
      final repository = _Repository();
      const request = '11111111-2222-3333-4444-555555555555';
      await _pump(tester, repository, rememberedRequest: request);
      expect(repository.receiptReads, [request]);
      expect(repository.cleanups, isEmpty);
      expect(find.text('清理完成'), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'missing receipt is never treated as not executed and GET polling is bounded',
    (tester) async {
      final repository = _Repository()..receiptMissing = true;
      await _pump(
        tester,
        repository,
        rememberedRequest: '11111111-2222-3333-4444-555555555555',
      );
      for (var i = 0; i < 25; i++) {
        await tester.pump(const Duration(seconds: 5));
        await tester.pump();
      }
      final reads = repository.receiptReads.length;
      await tester.pump(const Duration(seconds: 30));
      await tester.pump();
      expect(repository.receiptReads.length, reads);
      expect(find.text('自动核对已暂停，请稍后手动核对或联系管理员。不会重新执行清理。'), findsOneWidget);
      expect(repository.cleanups, isEmpty);
      expect(find.text('清理完成'), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  test('unknown resource measurements are distinct from real zero', () {
    final summary = ServerStorageSummary.fromJson({
      'process': {'rssBytes': null, 'heapUsedBytes': 0},
      'database': {'sizeBytes': -1},
    });
    expect(summary.rssBytes, isNull);
    expect(summary.heapUsedBytes, 0);
    expect(summary.databaseBytes, isNull);
    expect(formatStorageBytes(null), '尚未确认');
    expect(formatStorageBytes(0), '0 B');
    expect(formatStorageBytes(1048576), '1.0 MiB');
  });

  testWidgets(
    'entry is read-only; protected rows explain why and cannot be selected',
    (tester) async {
      final repository = _Repository();
      await _pump(tester, repository);
      expect(repository.summaryCalls, 1);
      expect(repository.previews, isEmpty);
      await _open(tester, 'LOGS');
      expect(find.text('正在使用或受保留规则保护'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('storage-select-protected')),
        findsNothing,
      );
      expect(
        find.byKey(const ValueKey('storage-select-cleanable')),
        findsOneWidget,
      );
      expect(repository.cleanups, isEmpty);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'cleanup requires an authoritative preview and a second explicit confirmation',
    (tester) async {
      final repository = _Repository();
      await _pump(tester, repository);
      await _open(tester, 'LOGS');
      await tester.ensureVisible(
        find.byKey(const ValueKey('storage-select-cleanable')),
      );
      await tester.tap(find.byKey(const ValueKey('storage-select-cleanable')));
      await tester.pump();
      await tester.ensureVisible(
        find.byKey(const ValueKey('storage-cleanup-preview')),
      );
      await tester.tap(find.byKey(const ValueKey('storage-cleanup-preview')));
      await tester.pumpAndSettle();
      expect(repository.previews.single, ['cleanable']);
      expect(repository.cleanups, isEmpty);
      await tester.tap(find.byKey(const ValueKey('storage-cleanup-confirm')));
      await tester.pumpAndSettle();
      expect(repository.cleanups.single['previewId'], 'preview-1');
      expect(
        repository.cleanups.single['requestId'],
        matches(RegExp(r'^[0-9a-f-]{36}$')),
      );
      expect(find.text('清理完成'), findsOneWidget);
      expect(repository.summaryCalls, 2);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets('protected or substituted preview is rejected without execute', (
    tester,
  ) async {
    final repository = _Repository()..unsafePreview = true;
    await _pump(tester, repository);
    await _open(tester, 'LOGS');
    await tester.ensureVisible(
      find.byKey(const ValueKey('storage-select-cleanable')),
    );
    await tester.tap(find.byKey(const ValueKey('storage-select-cleanable')));
    await tester.pump();
    await tester.ensureVisible(
      find.byKey(const ValueKey('storage-cleanup-preview')),
    );
    await tester.tap(find.byKey(const ValueKey('storage-cleanup-preview')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('storage-cleanup-confirm')), findsNothing);
    expect(repository.cleanups, isEmpty);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
    'uncertain cleanup only queries the original receipt and never replays POST',
    (tester) async {
      final repository = _Repository()..failFirstCleanup = true;
      await _pump(tester, repository);
      await _open(tester, 'LOGS');
      await tester.ensureVisible(
        find.byKey(const ValueKey('storage-select-cleanable')),
      );
      await tester.tap(find.byKey(const ValueKey('storage-select-cleanable')));
      await tester.pump();
      await tester.ensureVisible(
        find.byKey(const ValueKey('storage-cleanup-preview')),
      );
      await tester.tap(find.byKey(const ValueKey('storage-cleanup-preview')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('storage-cleanup-confirm')));
      await tester.pumpAndSettle();
      expect(repository.cleanups, hasLength(1));
      await tester.ensureVisible(find.text('核对原请求'));
      await tester.tap(find.text('核对原请求'));
      await tester.pumpAndSettle();
      expect(repository.cleanups, hasLength(1));
      expect(
        repository.receiptReads.single,
        repository.cleanups.single['requestId'],
      );
      expect(repository.previews, hasLength(1));
      expect(find.text('清理完成'), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'changing inventory revision during paging clears stale selection and asks to reload',
    (tester) async {
      final repository = _Repository()..nextRevision = true;
      await _pump(tester, repository);
      await _open(tester, 'LOGS');
      await tester.ensureVisible(
        find.byKey(const ValueKey('storage-select-cleanable')),
      );
      await tester.tap(find.byKey(const ValueKey('storage-select-cleanable')));
      await tester.pump();
      await tester.ensureVisible(find.text('加载更多'));
      await tester.tap(find.text('加载更多'));
      await tester.pumpAndSettle();
      expect(find.text('存储内容已变化，请重新读取此分类后再选择。'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('storage-select-cleanable')),
        findsNothing,
      );
      expect(repository.previews, isEmpty);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets('late category response cannot replace the current category', (
    tester,
  ) async {
    final first = Completer<ServerStorageResources>();
    final repository = _Repository()..firstResources = first.future;
    await _pump(tester, repository);
    await tester.tap(find.byKey(const ValueKey('storage-category-LOGS')));
    await tester.pump();
    await tester.ensureVisible(
      find.byKey(const ValueKey('storage-category-DATABASE')),
    );
    await tester.tap(find.byKey(const ValueKey('storage-category-DATABASE')));
    await tester.pumpAndSettle();
    expect(find.text('数据库只读快照'), findsOneWidget);
    first.complete(_resources('LOGS'));
    await tester.pumpAndSettle();
    expect(find.text('数据库只读快照'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('storage-select-cleanable')),
      findsNothing,
    );
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
    'view-only access never exposes deletion and compact layout has no overflow',
    (tester) async {
      tester.view.physicalSize = const Size(390, 1100);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final repository = _Repository()..canCleanup = false;
      await _pump(tester, repository, scale: 1.4);
      await _open(tester, 'LOGS');
      expect(find.byType(Checkbox), findsNothing);
      expect(
        find.byKey(const ValueKey('storage-cleanup-preview')),
        findsNothing,
      );
      expect(tester.takeException(), isNull);
      expect(repository.cleanups, isEmpty);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}

Future<void> _open(WidgetTester tester, String kind) async {
  await tester.ensureVisible(find.byKey(ValueKey('storage-category-$kind')));
  await tester.tap(find.byKey(ValueKey('storage-category-$kind')));
  await tester.pumpAndSettle();
}

Future<void> _pump(
  WidgetTester tester,
  _Repository repository, {
  double scale = 1,
  String? rememberedRequest,
}) async {
  SharedPreferences.setMockInitialValues({
    'serverStorage.lastRequest.v1.company/operator': ?rememberedRequest,
  });
  final preferences = await SharedPreferences.getInstance();
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(preferences),
        serverStorageRequestOwnerProvider.overrideWithValue('company/operator'),
        serverOperationsOwnerProvider.overrideWithValue('company/operator'),
        serverOperationsVisibleProvider.overrideWithValue(true),
        serverOperationsWritableProvider.overrideWithValue(true),
        serverStorageRepositoryProvider.overrideWithValue(repository),
      ],
      child: MaterialApp(
        locale: const Locale('zh'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: TextScaler.linear(scale)),
          child: child!,
        ),
        home: const ServerStoragePage(),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Map<String, dynamic> _resource(
  String id, {
  bool canDelete = true,
  String kind = 'LOGS',
  String? label,
}) => {
  'id': id,
  'label': label ?? id,
  'kind': kind,
  'logicalBytes': 1024,
  'allocatedBytes': 4096,
  'reclaimableBytes': canDelete ? 4096 : 0,
  'canDelete': canDelete,
  'protectionReasons': canDelete ? <String>[] : ['正在使用或受保留规则保护'],
};
ServerStorageResources _resources(
  String kind, {
  String revision = 'r1',
  String? cursor = 'next',
}) => ServerStorageResources.fromJson({
  'revision': revision,
  'kind': kind,
  'nextCursor': cursor,
  'total': 2,
  'items': kind == 'LOGS'
      ? [_resource('cleanable'), _resource('protected', canDelete: false)]
      : [_resource('db', canDelete: false, kind: kind, label: '数据库只读快照')],
});

class _Repository implements ServerStorageRepository {
  bool includeLegacy = false;
  bool receiptMissing = false;
  bool canCleanup = true,
      unsafePreview = false,
      failFirstCleanup = false,
      nextRevision = false;
  Future<ServerStorageResources>? firstResources;
  int summaryCalls = 0;
  final previews = <List<String>>[], cleanups = <Map<String, String>>[];
  final receiptReads = <String>[];
  @override
  Future<ServerStorageSummary> summary() async {
    summaryCalls++;
    return ServerStorageSummary.fromJson({
      'revision': 'r1',
      'status': 'NORMAL',
      'capabilities': {'available': true, 'canCleanup': canCleanup},
      'process': {
        'rssBytes': 123456,
        'heapUsedBytes': 10000,
        'heapMaxBytes': 20000,
      },
      'categories': [
        if (includeLegacy)
          for (final kind in ['UPLOADS', 'LEGACY_UPLOADS'])
            {
              'kind': kind,
              'label': kind,
              'canList': true,
              'allocatedBytes': 4096,
              'logicalBytes': 1024,
              'count': 1,
              'reclaimableBytes': 0,
              'detail': '旧上传原件永不物理清理；目录可能同卷或重叠，不应与当前目录直接相加。',
            },
        for (final kind in ['LOGS', 'DATABASE'])
          {
            'kind': kind,
            'label': kind == 'LOGS' ? '日志' : '数据库',
            'canList': true,
            'count': 2,
            'allocatedBytes': 8192,
            'logicalBytes': 2048,
            'reclaimableBytes': 4096,
          },
      ],
    });
  }

  @override
  Future<ServerStorageResources> resources(
    String kind, {
    String? cursor,
  }) async {
    if (kind == 'LEGACY_UPLOADS') {
      return ServerStorageResources.fromJson({
        'revision': 'r1',
        'kind': kind,
        'total': 1,
        'items': [
          {
            'id': 'legacy-original',
            'kind': kind,
            'label': '历史附件原件',
            'canDelete': false,
            'protectionReasons': ['兼容旧上传原件永不物理清理'],
            'detail': '只读物理目录，不更改业务附件引用。',
          },
        ],
      });
    }
    if (kind == 'LOGS' && firstResources != null) return firstResources!;
    return _resources(
      kind,
      revision: cursor != null && nextRevision ? 'r2' : 'r1',
      cursor: cursor == null ? 'next' : null,
    );
  }

  @override
  Future<ServerStoragePreview> preview(List<String> resourceIds) async {
    previews.add(resourceIds);
    return ServerStoragePreview.fromJson({
      'previewId': 'preview-1',
      'revision': 'r1',
      'expiresAt': DateTime.now()
          .toUtc()
          .add(const Duration(minutes: 5))
          .toIso8601String(),
      'resources': [
        _resource(
          unsafePreview ? 'protected' : 'cleanable',
          canDelete: !unsafePreview,
        ),
      ],
      'totalReclaimableBytes': 4096,
      'confirmationText': '仅清理已闭合且不受引用的资源。',
      'warnings': <String>[],
    });
  }

  @override
  Future<ServerStorageCleanupReceipt> cleanup({
    required String previewId,
    required String requestId,
  }) async {
    cleanups.add({'previewId': previewId, 'requestId': requestId});
    if (failFirstCleanup && cleanups.length == 1) {
      throw StateError('response lost');
    }
    return ServerStorageCleanupReceipt.fromJson({
      'requestId': requestId,
      'status': 'SUCCEEDED',
      'deletedCount': 1,
      'reclaimedBytes': 4096,
    });
  }

  @override
  Future<ServerStorageCleanupReceipt> receipt(String requestId) async {
    receiptReads.add(requestId);
    if (receiptMissing) throw StateError('not found or response lost');
    return ServerStorageCleanupReceipt.fromJson({
      'requestId': requestId,
      'status': 'SUCCEEDED',
      'deletedCount': 1,
      'reclaimedBytes': 4096,
    });
  }
}
