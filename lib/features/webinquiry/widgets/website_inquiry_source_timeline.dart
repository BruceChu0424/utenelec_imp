import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/utils/china_datetime.dart';
import '../../../components/buttons/click_guard.dart';
import '../../../components/buttons/uten_button.dart';
import '../../../components/cards/uten_card.dart';
import '../../../components/inputs/uten_input.dart';
import '../../../components/layout/uten_section_header.dart';
import '../../../core/l10n/gen/app_localizations.dart';
import '../../../core/network/authenticated_request_scope.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../core/ui/uten_notify.dart';
import '../../../shared/auth/permissions.dart';
import '../../../shared/providers/authenticated_scope_provider.dart';
import '../../../shared/providers/session_provider.dart';
import '../models/website_inquiry.dart';
import '../providers/website_inquiry_providers.dart';

class WebsiteInquirySourceCard extends StatefulWidget {
  const WebsiteInquirySourceCard({super.key, required this.inquiry});
  final WebsiteInquiry inquiry;
  @override
  State<WebsiteInquirySourceCard> createState() =>
      _WebsiteInquirySourceCardState();
}

class _WebsiteInquirySourceCardState extends State<WebsiteInquirySourceCard> {
  bool _expanded = false;
  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final source = widget.inquiry.sourceContext;
    String? text(Object? value) =>
        value is String && value.trim().isNotEmpty ? value : null;
    final fields = <(String, String?)>[
      (l.websiteInquirySourceIdentity, widget.inquiry.sourceId),
      (l.websiteInquirySourceUrl, text(source['pageUrl'])),
      (l.websiteInquirySeries, text(source['series'])),
      (l.websiteInquiryConsent, text(source['consentAt'])),
      (l.websiteInquiryConsentPolicy, text(source['consentPolicyVersion'])),
    ].where((e) => e.$2 != null).toList();
    final products =
        (source['products'] is List
                ? source['products'] as List
                : const <Object?>[])
            .whereType<Map<String, dynamic>>()
            .toList();
    if (fields.isEmpty && products.isEmpty) return const SizedBox.shrink();
    return UtenCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          UtenSectionHeader(title: l.websiteInquiryOrigin),
          for (final field in fields)
            Padding(
              padding: const EdgeInsets.only(top: UtenSpacing.s8),
              child: SelectableText('${field.$1}: ${field.$2}'),
            ),
          if (products.isNotEmpty) ...[
            const SizedBox(height: UtenSpacing.s12),
            Text(
              '${l.websiteInquiryProduct} (${products.length})',
              style: Theme.of(context).textTheme.titleSmall,
            ),
            for (final product in (_expanded ? products : products.take(1)))
              Padding(
                padding: const EdgeInsets.only(top: UtenSpacing.s8),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SelectableText(
                      [
                        text(product['series']),
                        text(product['name']),
                      ].whereType<String>().join(' / '),
                    ),
                    if (text(product['id']) != null)
                      SelectableText(
                        '${l.websiteInquiryProductId}: ${product['id']}',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    if (text(product['sourceIdentity']) != null)
                      SelectableText(
                        '${l.websiteInquirySourceIdentity}: ${product['sourceIdentity']}',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                  ],
                ),
              ),
            if (products.length > 1)
              UtenButton(
                type: UtenButtonType.ghost,
                size: UtenButtonSize.small,
                onPressed: () => setState(() => _expanded = !_expanded),
                child: Text(
                  _expanded
                      ? l.websiteInquiryCollapseProducts
                      : l.websiteInquiryExpandProducts,
                ),
              ),
          ],
        ],
      ),
    );
  }
}

class WebsiteInquiryTimelineCard extends ConsumerStatefulWidget {
  const WebsiteInquiryTimelineCard({super.key, required this.inquiry});
  final WebsiteInquiry inquiry;
  @override
  ConsumerState<WebsiteInquiryTimelineCard> createState() =>
      _WebsiteInquiryTimelineCardState();
}

class _WebsiteInquiryTimelineCardState
    extends ConsumerState<WebsiteInquiryTimelineCard> {
  final _note = TextEditingController();
  bool _saving = false;
  @override
  void dispose() {
    _note.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final inquiry = widget.inquiry;
    final owner = ref.watch(authenticatedScopeProvider);
    final employeeId = ref.watch(
      sessionProvider.select((s) => s.user?.employeeId),
    );
    final canWrite =
        owner != null &&
        !owner.readOnly &&
        ref.watch(currentPermissionsProvider).contains(Perm.webinquiryClaim) &&
        inquiry.status == WebsiteInquiryStatus.following &&
        employeeId != null &&
        inquiry.assigneeEmployeeId == employeeId;
    return UtenCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          UtenSectionHeader(title: l.websiteInquiryTimeline),
          if (inquiry.timeline.isEmpty)
            Padding(
              padding: const EdgeInsets.only(top: UtenSpacing.s8),
              child: Text(l.websiteInquiryTimelineEmpty),
            ),
          for (final event in inquiry.timeline)
            Padding(
              padding: const EdgeInsets.only(top: UtenSpacing.s12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    _eventTitle(event.kind, l),
                    style: Theme.of(context).textTheme.titleSmall,
                  ),
                  Text(
                    [
                      _format(event.createdAt),
                      event.actorLabel,
                    ].whereType<String>().join('  '),
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                  if (event.note?.isNotEmpty == true)
                    SelectableText(event.note!),
                ],
              ),
            ),
          if (canWrite) ...[
            const SizedBox(height: UtenSpacing.s20),
            UtenInput(
              key: const ValueKey('website-inquiry-follow-up-note'),
              controller: _note,
              label: l.websiteInquiryNote,
              maxLines: 3,
              enabled: !_saving,
            ),
            const SizedBox(height: UtenSpacing.s12),
            UtenActionButton(
              key: const ValueKey('website-inquiry-save-follow-up'),
              label: Text(l.websiteInquirySaveNote),
              onAction: () async {
                final note = _note.text.trim();
                if (note.isEmpty || note.length > 2000) {
                  UtenNotify.error(context, l.websiteInquiryNoteRequired);
                  return;
                }
                setState(() => _saving = true);
                try {
                  await followUpWebsiteInquiry(ref, inquiry.id, note);
                  if (!mounted) return;
                  _note.clear();
                  UtenNotify.success(this.context, l.websiteInquiryNoteSaved);
                } catch (error) {
                  if (mounted) {
                    if (isSessionBoundaryError(error)) {
                      UtenNotify.error(this.context, l.websiteSessionChanged);
                    } else {
                      UtenNotify.apiError(this.context, error);
                    }
                  }
                } finally {
                  if (mounted) setState(() => _saving = false);
                }
              },
            ),
          ],
        ],
      ),
    );
  }
}

String _eventTitle(String kind, AppLocalizations l) =>
    switch (kind.toLowerCase()) {
      'received' || 'ingested' || 'created' => l.websiteInquiryReceivedEvent,
      'claimed' || 'assigned' => l.websiteInquiryClaimedEvent,
      'follow_up' || 'note' || 'followup' => l.websiteInquiryNoteEvent,
      'closed' => l.websiteInquiryClosedEvent,
      'converted' => l.websiteInquiryConvertedEvent,
      _ => l.websiteInquiryEvent,
    };

String _format(DateTime v) => ChinaDateTime.formatDateTime(v);
