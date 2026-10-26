import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/shared/attachments/attachment.dart';
import 'package:uten_imp/shared/attachments/attachment_category_control.dart';
import 'package:uten_imp/shared/attachments/attachment_section.dart';
import 'package:uten_imp/shared/attachments/attachment_service.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/providers/shared_providers.dart';

Map<String, dynamic> _file({String id = 'original', bool historical = false}) =>
    {
      'id': id,
      'ownerType': 'EMPLOYEE',
      'ownerId': 'original-owner',
      'storageKey': 'opaque-$id',
      'originalName': '$id.png',
      'contentType': 'image/png',
      'sizeBytes': 8,
      'sha256': 'original-digest',
      if (historical) ...{
        'deleted': true,
        'deletedAt': '2026-10-01T00:00:00Z',
        'deletedBy': 'original-actor',
        'deletedByName': 'Historical operator',
        'deletedReason': 'Retained evidence',
        'historyReadOnly': true,
        'originalAvailability': 'AVAILABLE',
        'historyDownloadUrl': 'https://untrusted.invalid/download',
      },
    };

class _Api extends Fake implements ApiClient {
  final paths = <String>[];
  Object? failure;
  @override
  Future<List<Map<String, dynamic>>> getList(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    expect(query?['includeDeleted'], isTrue);
    return [_file()];
  }

  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    paths.add(path);
    return {'url': '/current-bytes'};
  }

  @override
  Future<Uint8List> getBytes(String path) async {
    paths.add(path);
    if (failure != null) throw failure!;
    return Uint8List.fromList([1, 2, 3]);
  }
}

class _Files extends Fake implements AttachmentService {
  final writes = <String>[];
  @override
  Future<Attachment> setCategory(String id, String? category) async {
    writes.add(id);
    return Attachment.fromJson(_file(id: id));
  }
}

void main() {
  testWidgets(
    'a stale category action cannot write after the row becomes historical or upload permission is revoked',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final files = _Files();
      var historical = false;
      late StateSetter refresh;
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            sharedPreferencesProvider.overrideWithValue(prefs),
            attachmentServiceProvider.overrideWithValue(files),
            currentPermissionsProvider.overrideWithValue({
              Perm.attachmentUpload,
            }),
          ],
          child: MaterialApp(
            home: Scaffold(
              body: StatefulBuilder(
                builder: (_, setState) {
                  refresh = setState;
                  return AttachmentSection(
                    ownerType: 'EMPLOYEE',
                    ownerId: 'original-owner',
                    attachments: [
                      Attachment.fromJson(_file(historical: historical)),
                    ],
                    ownerCanUpload: true,
                    ownerCanDelete: true,
                    categories: const ['Evidence'],
                    onChanged: () {},
                  );
                },
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final stale = tester
          .widget<AttachmentCategoryControl>(
            find.byType(AttachmentCategoryControl),
          )
          .onChanged!;
      refresh(() => historical = true);
      await tester.pumpAndSettle();
      stale('Evidence');
      await tester.pumpAndSettle();
      expect(files.writes, isEmpty);
      refresh(() => historical = false);
      await tester.pumpAndSettle();
      final staleAfterRevoke = tester
          .widget<AttachmentCategoryControl>(
            find.byType(AttachmentCategoryControl),
          )
          .onChanged!;
      final container = ProviderScope.containerOf(
        tester.element(find.byType(AttachmentSection)),
      );
      container.updateOverrides([
        sharedPreferencesProvider.overrideWithValue(prefs),
        attachmentServiceProvider.overrideWithValue(files),
        currentPermissionsProvider.overrideWithValue(<String>{}),
      ]);
      await tester.pumpAndSettle();
      staleAfterRevoke('Evidence');
      await tester.pumpAndSettle();
      expect(files.writes, isEmpty);
    },
  );

  test(
    'history preserves original owner and deletion metadata; ordinary defaults stay writable',
    () {
      final a = Attachment.fromJson(_file(historical: true));
      expect(a.ownerId, 'original-owner');
      expect(a.sha256, 'original-digest');
      expect(a.deletedBy, 'original-actor');
      expect(a.deletedByName, 'Historical operator');
      expect(a.deletedReason, 'Retained evidence');
      expect(a.deletedAt, isNotNull);
      expect(a.isReadOnly, isTrue);
      expect(a.originalUnavailable, isFalse);
      expect(Attachment.fromJson(_file()).isReadOnly, isFalse);
    },
  );

  test(
    'history download uses authenticated raw ID route, while live downloads keep their grant',
    () async {
      final api = _Api();
      final service = AttachmentService(api);
      final history = await service.listHistory(
        ownerType: 'EMPLOYEE',
        ownerId: 'original-owner',
      );
      expect(history.single.historyReadOnly, isTrue);
      await service.downloadBytes(Attachment.fromJson(_file(historical: true)));
      expect(api.paths, ['/attachments/original/history/download']);
      api.paths.clear();
      await service.downloadBytes(Attachment.fromJson(_file()));
      expect(api.paths, [
        '/attachments/original/download-grant',
        '/current-bytes',
      ]);
      api.failure = StateError('retained original unavailable');
      await expectLater(
        service.downloadBytes(history.single),
        throwsStateError,
      );
    },
  );

  for (final language in ['zh', 'en', 'ko']) {
    testWidgets(
      '$language mixed live/history rows protect each historical action at narrow large text',
      (tester) async {
        tester.view.physicalSize = const Size(780, 1400);
        tester.view.devicePixelRatio = 2;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        SharedPreferences.setMockInitialValues({});
        final prefs = await SharedPreferences.getInstance();
        final files = _Files();
        final live = Attachment.fromJson(_file(id: 'live'));
        final history = Attachment.fromJson({
          ..._file(historical: true),
          'originalAvailability': 'LEGACY_UNAVAILABLE',
        });
        var avatars = 0;
        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              sharedPreferencesProvider.overrideWithValue(prefs),
              attachmentServiceProvider.overrideWithValue(files),
              currentPermissionsProvider.overrideWithValue({
                Perm.attachmentUpload,
                Perm.attachmentDelete,
                Perm.attachmentDownload,
              }),
            ],
            child: MaterialApp(
              locale: Locale(language),
              localizationsDelegates: AppLocalizations.localizationsDelegates,
              supportedLocales: AppLocalizations.supportedLocales,
              home: Scaffold(
                body: MediaQuery(
                  data: const MediaQueryData(
                    textScaler: TextScaler.linear(1.5),
                  ),
                  child: SingleChildScrollView(
                    child: AttachmentSection(
                      ownerType: 'EMPLOYEE',
                      ownerId: 'original-owner',
                      attachments: [live, history],
                      ownerCanUpload: true,
                      ownerCanDelete: true,
                      categories: const ['Evidence'],
                      onSetAvatar: (_) => avatars++,
                      onChanged: () {},
                      rowActionBuilder: (a) => Text('action-${a.id}'),
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.byTooltip('删除'), findsOneWidget);
        expect(find.byTooltip('设为头像'), findsOneWidget);
        expect(find.byTooltip('预览'), findsOneWidget);
        expect(find.text('action-original'), findsNothing);
        final controls = tester
            .widgetList<AttachmentCategoryControl>(
              find.byType(AttachmentCategoryControl),
            )
            .toList();
        expect(controls[0].onChanged, isNotNull);
        expect(controls[1].onChanged, isNull);
        expect(controls[1].enabled, isFalse);
        expect(find.textContaining('Retained evidence'), findsOneWidget);
        final l10n = lookupAppLocalizations(Locale(language));
        expect(
          find.textContaining(l10n.attachmentHistoricalDeletedLabel),
          findsOneWidget,
        );
        expect(
          find.textContaining(l10n.attachmentHistoricalOriginalUnavailable),
          findsOneWidget,
        );
        await tester.tap(find.byTooltip('设为头像'));
        expect(avatars, 1);
        expect(files.writes, isEmpty);
        expect(tester.takeException(), isNull);
      },
    );
  }
}
