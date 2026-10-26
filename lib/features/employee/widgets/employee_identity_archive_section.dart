import 'package:flutter/material.dart';
import '../../../components/cards/uten_card.dart';
import '../../../core/theme/uten_tokens.dart';
import '../models/employee_api_models.dart';
import '../../../shared/attachments/attachment_section.dart';
import '../../../core/l10n/gen/app_localizations.dart';

String employeeIdentitySourceLabel(BuildContext context, String? code) =>
    switch (Localizations.maybeLocaleOf(context)?.languageCode) {
      'en' => 'Archived record ${code ?? ''} (read only)',
      'ko' => '보관 기록 ${code ?? ''} (읽기 전용)',
      _ => '历史档案 ${code ?? ''}(只读)',
    };

/// Read-only evidence stays outside the current employee's editable collections.
class EmployeeIdentityArchiveSection extends StatelessWidget {
  const EmployeeIdentityArchiveSection({super.key, required this.profile});
  final EmployeeProfile profile;
  @override
  Widget build(BuildContext context) {
    final language = Localizations.maybeLocaleOf(context)?.languageCode;
    String text(String zh, String en, String ko) => language == 'en'
        ? en
        : language == 'ko'
        ? ko
        : zh;
    final entries = [
      for (final row in profile.historicalEducations)
        (
          row,
          text('学历', 'Education', '학력'),
          ['school', 'degree', 'major', 'startDate', 'endDate'],
        ),
      for (final row in profile.historicalCertificates)
        (
          row,
          text('证书', 'Certificate', '자격증'),
          ['name', 'type', 'certNo', 'issuedAt', 'expiresAt'],
        ),
    ];
    if (entries.isEmpty && profile.historicalAttachmentGroups.isEmpty) {
      return const SizedBox.shrink();
    }
    final l10n =
        Localizations.of<AppLocalizations>(context, AppLocalizations) ??
        lookupAppLocalizations(Localizations.localeOf(context));
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (entries.isNotEmpty)
          UtenCard(
            child: Padding(
              padding: const EdgeInsets.all(UtenSpacing.s16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    text(
                      '历史学历与证书',
                      'Archived education and certificates',
                      '보관 학력 및 자격증',
                    ),
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  for (final entry in entries)
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: const Icon(Icons.history_rounded),
                      title: Text(
                        [
                          entry.$2,
                          ...entry.$3.map(entry.$1.text),
                        ].where((s) => s.isNotEmpty).join(' · '),
                      ),
                      subtitle: Text(
                        employeeIdentitySourceLabel(
                          context,
                          entry.$1.sourceEmployeeCode,
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        for (final group in profile.historicalAttachmentGroups)
          Padding(
            padding: const EdgeInsets.only(top: UtenSpacing.s16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  employeeIdentitySourceLabel(
                    context,
                    group.sourceEmployeeCode,
                  ),
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                const SizedBox(height: UtenSpacing.s8),
                AttachmentSection(
                  ownerType: group.ownerType,
                  ownerId: group.ownerId,
                  attachments: group.attachments,
                  ownerCanUpload: false,
                  ownerCanDelete: false,
                  onChanged: () {},
                  title: group.ownerType == 'EMPLOYEE_CONTRACT'
                      ? l10n.employeeHistoricalContractFilesTitle
                      : l10n.employeeHistoricalFilesTitle,
                  emptyHint: l10n.employeeHistoricalFilesHint,
                ),
              ],
            ),
          ),
      ],
    );
  }
}
