import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/features/employee/models/employee_api_models.dart';
import 'package:uten_imp/features/employee/widgets/employee_identity_archive_section.dart';
import 'package:uten_imp/shared/attachments/attachment_section.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/providers/shared_providers.dart';

Map<String, dynamic> _group(String type, String owner) => {
  'sourceEmployeeId': 'verified-alias',
  'sourceEmployeeCode': 'OLD-001',
  'ownerType': type,
  'ownerId': owner,
  'attachments': [
    {
      'id': '$owner-file',
      'ownerType': type,
      'ownerId': owner,
      'storageKey': 'retained-key',
      'originalName': '$owner.pdf',
      'sizeBytes': 12,
      'originalAvailability': 'LEGACY_UNAVAILABLE',
    },
  ],
};
EmployeeProfile _profile() => EmployeeProfile.fromJson({
  'id': 'canonical',
  'code': 'CURRENT-001',
  'fullName': 'Synthetic employee',
  'historicalAttachmentGroups': [
    _group('EMPLOYEE', 'verified-alias'),
    _group('EMPLOYEE_CONTRACT', 'retained-contract'),
  ],
});

void main() {
  test(
    'history groups preserve raw employee/contract owners and stay outside current editable attachments',
    () {
      final profile = _profile();
      expect(profile.attachments, isEmpty);
      expect(profile.historicalAttachmentGroups.map((g) => g.ownerId), [
        'verified-alias',
        'retained-contract',
      ]);
      for (final group in profile.historicalAttachmentGroups) {
        expect(group.sourceEmployeeId, 'verified-alias');
        expect(group.attachments.single.historyReadOnly, isTrue);
        expect(group.attachments.single.ownerId, group.ownerId);
      }
      final mismatch = _group('EMPLOYEE', 'someone-else');
      expect(
        () => EmployeeHistoricalAttachmentGroup.fromJson(mismatch),
        throwsFormatException,
      );
      final fileMismatch = _group('EMPLOYEE_CONTRACT', 'retained-contract');
      final mismatchedFile =
          (fileMismatch['attachments'] as List<Map<String, dynamic>>).single;
      mismatchedFile['ownerId'] = 'someone-else';
      expect(
        () => EmployeeHistoricalAttachmentGroup.fromJson(fileMismatch),
        throwsFormatException,
      );
    },
  );
  for (final language in ['zh', 'en', 'ko']) {
    testWidgets(
      '$language archived employee and contract files reuse readonly shared sections',
      (tester) async {
        SharedPreferences.setMockInitialValues({});
        final prefs = await SharedPreferences.getInstance();
        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              sharedPreferencesProvider.overrideWithValue(prefs),
              currentPermissionsProvider.overrideWithValue({
                Perm.attachmentUpload,
                Perm.attachmentDelete,
                Perm.attachmentDownload,
              }),
            ],
            child: MaterialApp(
              locale: Locale(language),
              supportedLocales: AppLocalizations.supportedLocales,
              localizationsDelegates: AppLocalizations.localizationsDelegates,
              home: Scaffold(
                body: SingleChildScrollView(
                  child: EmployeeIdentityArchiveSection(profile: _profile()),
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        final sections = tester
            .widgetList<AttachmentSection>(find.byType(AttachmentSection))
            .toList();
        expect(sections.length, 2);
        expect(sections.map((s) => s.ownerId), [
          'verified-alias',
          'retained-contract',
        ]);
        expect(
          sections.every((s) => !s.ownerCanUpload && !s.ownerCanDelete),
          isTrue,
        );
        expect(find.textContaining('OLD-001'), findsNWidgets(2));
        final l10n = lookupAppLocalizations(Locale(language));
        expect(find.text(l10n.employeeHistoricalFilesTitle), findsOneWidget);
        expect(
          find.text(l10n.employeeHistoricalContractFilesTitle),
          findsOneWidget,
        );
        expect(find.text('添加文件'), findsNothing);
        expect(find.byTooltip('删除'), findsNothing);
        expect(find.byType(IconButton), findsNothing);
        expect(tester.takeException(), isNull);
      },
    );
  }
}
