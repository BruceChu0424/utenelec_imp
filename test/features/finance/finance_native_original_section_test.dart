import 'dart:async';
import 'dart:typed_data';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/theme/light_theme.dart';
import 'package:uten_imp/features/finance/widgets/finance_native_original_section.dart';
import 'package:uten_imp/shared/attachments/attachment_section.dart';
import 'package:uten_imp/shared/attachments/attachment_service.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/auth/session_snapshot_provider.dart';

const _full = '100.123456789012345678901234';

class _Snapshot extends SessionSnapshotNotifier {
  @override
  Future<SessionSnapshot?> build() async => SessionSnapshot();
}

class _Api extends ApiClient {
  _Api() : super(Dio());
  String state = 'AVAILABLE';
  Completer<Map<String, dynamic>>? pending;
  final reads = <String>[];
  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    reads.add(path);
    if (pending != null) return pending!.future;
    return {
      'readOnly': true,
      'originalEvidenceState': state,
      'original': {
        'title': '匿名原稿',
        'applicationNo': '原申请一',
        'requestedDate': '2026-11-01',
        'amountOriginal': _full,
        'currencyCode': 'USD',
        'payload': {'destination': '原地点', 'remark': '保留原文'},
      },
    };
  }

  @override
  Future<List<Map<String, dynamic>>> getList(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    reads.add('$path:${query?['ownerType']}:${query?['ownerId']}');
    return [
      {
        'id': 'original-one',
        'ownerType': 'FINANCE_APPLICATION',
        'ownerId': 'old-owner',
        'storageKey': 'private-original',
        'originalName': '原凭证.pdf',
        'sizeBytes': 3,
        'contentType': 'application/pdf',
      },
    ];
  }

  @override
  Future<Uint8List> getBytes(String path, {Map<String, dynamic>? query}) async {
    reads.add(path);
    return Uint8List.fromList([1, 2, 3]);
  }
}

void main() {
  testWidgets(
    'original amount and exact linked evidence remain readonly through the verified history path',
    (tester) async {
      final api = _Api();
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            apiClientProvider.overrideWithValue(api),
            sessionSnapshotProvider.overrideWith(_Snapshot.new),
            currentPermissionsProvider.overrideWithValue({
              Perm.attachmentView,
              Perm.attachmentDownload,
            }),
          ],
          child: MaterialApp(
            theme: buildLightTheme(),
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: const Scaffold(
              body: SingleChildScrollView(
                child: FinanceNativeOriginalSection(
                  ownerType: 'BUSINESS_APPLICATION',
                  ownerId: 'current-one',
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('原申请金额：$_full USD'), findsOneWidget);
      final files = tester.widget<AttachmentSection>(
        find.byType(AttachmentSection),
      );
      expect(files.ownerId, 'current-one');
      expect(files.ownerCanUpload, isFalse);
      expect(files.ownerCanDelete, isFalse);
      expect(files.attachments.single.ownerId, 'old-owner');
      expect(files.attachments.single.isReadOnly, isTrue);
      final container = ProviderScope.containerOf(
        tester.element(find.byType(FinanceNativeOriginalSection)),
      );
      await container
          .read(attachmentServiceProvider)
          .downloadBytes(files.attachments.single);
      expect(api.reads.last, '/attachments/original-one/history/download');
      expect(
        api.reads.where((path) => path.startsWith('/attachments:')),
        isEmpty,
      );
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
    },
  );

  testWidgets(
    'unavailable original evidence never starts a linked list or offers mutation controls',
    (tester) async {
      final api = _Api()..state = 'UNAVAILABLE';
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            apiClientProvider.overrideWithValue(api),
            sessionSnapshotProvider.overrideWith(_Snapshot.new),
          ],
          child: MaterialApp(
            theme: buildLightTheme(),
            home: const Scaffold(
              body: SingleChildScrollView(
                child: FinanceNativeOriginalSection(
                  ownerType: 'EXPENSE_CLAIM',
                  ownerId: 'claim-one',
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.textContaining('原凭证已变化或不可用'), findsOneWidget);
      expect(find.byType(AttachmentSection), findsNothing);
      expect(api.reads, ['/expense-claims/claim-one/original-source']);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
    },
  );

  test(
    'a late source reply cannot publish after native identity scope invalidation',
    () async {
      final first = _Api()..pending = Completer<Map<String, dynamic>>();
      final second = _Api()..state = 'NOT_APPLICABLE';
      final container = ProviderContainer(
        overrides: [
          apiClientProvider.overrideWithValue(first),
          sessionSnapshotProvider.overrideWith(_Snapshot.new),
        ],
      );
      addTearDown(container.dispose);
      const key = (ownerType: 'BUSINESS_APPLICATION', id: 'current-one');
      final subscription = container.listen(
        financeNativeOriginalProvider(key),
        (_, _) {},
      );
      addTearDown(subscription.close);
      await Future<void>.delayed(Duration.zero);
      container.updateOverrides([
        apiClientProvider.overrideWithValue(second),
        sessionSnapshotProvider.overrideWith(_Snapshot.new),
      ]);
      final current = await container.read(
        financeNativeOriginalProvider(key).future,
      );
      expect(current.source['originalEvidenceState'], 'NOT_APPLICABLE');
      first.pending!.complete({
        'readOnly': true,
        'originalEvidenceState': 'AVAILABLE',
        'original': {'title': 'old-reader'},
      });
      await Future<void>.delayed(Duration.zero);
      expect(
        container
            .read(financeNativeOriginalProvider(key))
            .requireValue
            .source['originalEvidenceState'],
        'NOT_APPLICABLE',
      );
      expect(
        second.reads.where((path) => path.contains('/attachments/linked')),
        isEmpty,
      );
    },
  );
}
