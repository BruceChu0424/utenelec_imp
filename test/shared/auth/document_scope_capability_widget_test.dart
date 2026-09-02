import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/shared/auth/document_scope_capability.dart';
import 'package:uten_imp/shared/auth/document_scope_write_notice.dart';

void main() {
  testWidgets('write action stays hidden while capability is loading', (
    tester,
  ) async {
    final pending = Completer<DocumentScopeCapability>();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          documentScopeCapabilityProvider(DocumentDataScope.finance)
              .overrideWith((ref) => pending.future),
        ],
        child: const _CapabilitySurface(ownerId: 'owner-1'),
      ),
    );

    expect(find.text('只读'), findsOneWidget);
    expect(find.text('修改'), findsNothing);

    pending.complete(
      const DocumentScopeCapability(
        scope: 'finance',
        writeAll: false,
        writableOwnerIds: {'owner-1'},
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('修改'), findsOneWidget);
  });

  testWidgets('manual visible owner remains read-only in the action surface', (
    tester,
  ) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          documentScopeCapabilityProvider(DocumentDataScope.finance)
              .overrideWith(
                (ref) async => const DocumentScopeCapability(
                  scope: 'finance',
                  writeAll: false,
                  writableOwnerIds: {'different-owner'},
                ),
              ),
        ],
        child: const _CapabilitySurface(ownerId: 'manual-visible-owner'),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('只读'), findsOneWidget);
    expect(find.text('修改'), findsNothing);
  });

  testWidgets('notice distinguishes loading with text and progress', (
    tester,
  ) async {
    await tester.pumpWidget(
      _noticeApp(
        capability: const AsyncLoading<DocumentScopeCapability>(),
        ownerId: 'owner-1',
      ),
    );

    expect(
      find.byKey(const ValueKey('document-scope-write-notice-loading')),
      findsOneWidget,
    );
    expect(find.text('正在确认操作范围'), findsOneWidget);
    expect(find.text('确认完成前，本页保持只读。'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(find.text('重试'), findsNothing);
  });

  testWidgets('notice error explains fail-closed state and retries', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(375, 700);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    var retries = 0;
    await tester.pumpWidget(
      _noticeApp(
        capability: AsyncError<DocumentScopeCapability>(
          StateError('offline'),
          StackTrace.current,
        ),
        ownerId: 'owner-1',
        onRetry: () => retries++,
      ),
    );

    expect(
      find.byKey(const ValueKey('document-scope-write-notice-error')),
      findsOneWidget,
    );
    expect(find.text('无法确认操作范围，当前仅查看'), findsOneWidget);
    expect(find.textContaining('请检查网络后重试'), findsOneWidget);
    await tester.tap(
      find.byKey(const ValueKey('document-scope-write-notice-retry')),
    );
    expect(retries, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('notice explains manually visible owner and formal handover', (
    tester,
  ) async {
    await tester.pumpWidget(
      _noticeApp(
        capability: const AsyncData<DocumentScopeCapability>(
          DocumentScopeCapability(
            scope: 'finance',
            writeAll: false,
            writableOwnerIds: {'different-owner'},
          ),
        ),
        ownerId: 'manual-visible-owner',
      ),
    );

    expect(
      find.byKey(const ValueKey('document-scope-write-notice-readonly')),
      findsOneWidget,
    );
    expect(find.text('此单据通过额外查看范围显示，仅可查看'), findsOneWidget);
    expect(find.textContaining('正式数据交接'), findsOneWidget);
  });

  testWidgets('legacy ownerless notice wins even for writeAll', (tester) async {
    await tester.pumpWidget(
      _noticeApp(
        capability: const AsyncData<DocumentScopeCapability>(
          DocumentScopeCapability(
            scope: 'finance',
            writeAll: true,
            writableOwnerIds: <String>{},
          ),
        ),
        ownerId: null,
      ),
    );

    expect(
      find.byKey(const ValueKey('document-scope-write-notice-legacy')),
      findsOneWidget,
    );
    expect(find.text('历史单据未维护负责人，当前只读'), findsOneWidget);
    expect(find.textContaining('先补充负责人'), findsOneWidget);
  });

  testWidgets('writable capability renders no notice copy', (tester) async {
    await tester.pumpWidget(
      _noticeApp(
        capability: const AsyncData<DocumentScopeCapability>(
          DocumentScopeCapability(
            scope: 'finance',
            writeAll: false,
            writableOwnerIds: {'owner-1'},
          ),
        ),
        ownerId: 'owner-1',
      ),
    );

    expect(find.text('正在确认操作范围'), findsNothing);
    expect(find.textContaining('仅可查看'), findsNothing);
    expect(find.textContaining('当前只读'), findsNothing);
  });
}

Widget _noticeApp({
  required AsyncValue<DocumentScopeCapability> capability,
  required String? ownerId,
  VoidCallback? onRetry,
}) => MaterialApp(
  home: Scaffold(
    body: SingleChildScrollView(
      padding: const EdgeInsets.all(12),
      child: DocumentScopeWriteNotice(
        capability: capability,
        ownerEmployeeId: ownerId,
        onRetry: onRetry ?? () {},
      ),
    ),
  ),
);

class _CapabilitySurface extends ConsumerWidget {
  const _CapabilitySurface({required this.ownerId});

  final String ownerId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final capability = ref.watch(
      documentScopeCapabilityProvider(DocumentDataScope.finance),
    );
    final writable = documentOwnerCanWrite(capability, ownerId);
    return MaterialApp(
      home: Scaffold(
        body: Center(
          child: writable
              ? const ElevatedButton(onPressed: null, child: Text('修改'))
              : const Text('只读'),
        ),
      ),
    );
  }
}
