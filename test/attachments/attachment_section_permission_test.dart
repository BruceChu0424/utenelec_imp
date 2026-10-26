import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/shared/attachments/attachment.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/shared/attachments/attachment_section.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/providers/shared_providers.dart';

void main() {
  const attachment = Attachment(
    id: 'attachment-1',
    ownerType: 'EMPLOYEE',
    ownerId: 'employee-1',
    storageKey: 'storage-key',
    originalName: 'portrait.png',
    contentType: 'image/png',
    sizeBytes: 128,
  );

  Future<void> pumpSection(WidgetTester tester, Set<String> permissions) async {
    SharedPreferences.setMockInitialValues({});
    final preferences = await SharedPreferences.getInstance();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          currentPermissionsProvider.overrideWithValue(permissions),
          sharedPreferencesProvider.overrideWithValue(preferences),
        ],
        child: MaterialApp(
          locale: const Locale('zh'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: AttachmentSection(
              ownerType: 'EMPLOYEE',
              ownerId: 'employee-1',
              attachments: const [attachment],
              ownerCanUpload: true,
              ownerCanDelete: true,
              onChanged: () {},
            ),
          ),
        ),
      ),
    );
  }

  testWidgets('owner allowance never replaces attachment action permissions', (
    tester,
  ) async {
    await pumpSection(tester, const {});

    expect(find.text('添加文件'), findsNothing);
    expect(find.byTooltip('删除'), findsNothing);
    expect(find.byTooltip('预览'), findsNothing);
  });

  testWidgets('upload delete and download controls are independently visible', (
    tester,
  ) async {
    await pumpSection(tester, const {Perm.attachmentUpload});
    expect(find.text('添加文件'), findsOneWidget);
    expect(find.byTooltip('删除'), findsNothing);
    expect(find.byTooltip('预览'), findsNothing);

    await pumpSection(tester, const {
      Perm.attachmentDelete,
      Perm.attachmentDownload,
    });
    expect(find.text('添加文件'), findsNothing);
    expect(find.byTooltip('删除'), findsOneWidget);
    expect(find.byTooltip('预览'), findsOneWidget);
  });
}
