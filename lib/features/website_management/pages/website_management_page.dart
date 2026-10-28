import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../components/buttons/click_guard.dart';
import '../../../components/buttons/uten_button.dart';
import '../../../components/cards/uten_card.dart';
import '../../../components/data_display/uten_status_badge.dart';
import '../../../components/feedback/uten_empty.dart';
import '../../../components/inputs/uten_dropdown_field.dart';
import '../../../components/inputs/uten_input.dart';
import '../../../components/layout/uten_app_bar.dart';
import '../../../components/layout/uten_content_container.dart';
import '../../../components/layout/uten_section_header.dart';
import '../../../core/l10n/gen/app_localizations.dart';
import '../../../core/network/api_client.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/network/authenticated_request_scope.dart';
import '../../../core/network/server_config.dart';
import '../../../core/router/nav_helpers.dart';
import '../../../core/router/route_names.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../core/ui/capsule_nav_metrics.dart';
import '../../../core/ui/uten_notify.dart';
import '../../../core/utils/china_datetime.dart';
import '../../../shared/auth/permissions.dart';
import '../../../shared/providers/authenticated_scope_provider.dart';
import '../models/website_management.dart';
import '../providers/website_management_providers.dart';

class WebsiteManagementPage extends ConsumerWidget {
  const WebsiteManagementPage({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = AppLocalizations.of(context);
    final owner = ref.watch(authenticatedScopeProvider);
    final permissions = ref.watch(currentPermissionsProvider);
    final endpoint = ref.watch(apiBaseUrlProvider);
    final allowed = owner != null && permissions.contains(Perm.websiteView);
    return Scaffold(
      appBar: UtenAppBar(title: l.websiteManagementTitle, showBackButton: true),
      body: !allowed
          ? UtenEmpty(message: l.websiteAccessDenied)
          : _WebsiteWorkspace(
              key: ValueKey((
                owner,
                endpoint,
                (permissions.toList()..sort()).join(','),
              )),
            ),
    );
  }
}

class _WebsiteWorkspace extends ConsumerStatefulWidget {
  const _WebsiteWorkspace({super.key});
  @override
  ConsumerState<_WebsiteWorkspace> createState() => _WebsiteWorkspaceState();
}

class _WebsiteWorkspaceState extends ConsumerState<_WebsiteWorkspace> {
  bool _busy = false;
  bool _showConfig = false;

  Future<void> _perform(
    Future<void> Function(AuthenticatedRequestScope scope) action, {
    String requiredPermission = Perm.websiteView,
    bool administrator = false,
  }) async {
    if (_busy) return;
    final owner = ref.read(authenticatedScopeProvider);
    final endpoint = ref.read(apiBaseUrlProvider);
    bool current() =>
        mounted &&
        owner != null &&
        ref.read(authenticatedScopeProvider) == owner &&
        ref.read(apiBaseUrlProvider) == endpoint &&
        ref.read(currentPermissionsProvider).contains(requiredPermission) &&
        (!administrator ||
            (ref.read(isSuperAdminProvider) && owner.actorId == null));
    if (!current()) return;
    setState(() => _busy = true);
    try {
      final scope = await ref
          .read(apiClientProvider)
          .captureRequestScope(isCurrent: current);
      await scope.run(() => action(scope));
    } catch (error) {
      if (mounted) {
        final l = AppLocalizations.of(context);
        if (isSessionBoundaryError(error)) {
          UtenNotify.error(context, l.websiteSessionChanged);
        } else if (error is ApiException &&
            error.code == 'WEBSITE_UNTRUSTED_TARGET') {
          UtenNotify.error(context, l.websiteUntrustedTarget);
        } else {
          UtenNotify.apiError(context, error, fallback: l.websiteOpenFailed);
        }
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _open(
    WebsiteManagementSnapshot snapshot,
    String section,
    String permission,
  ) => _perform((scope) async {
    if (!snapshot.ready ||
        ref.read(authenticatedScopeProvider)?.actorId != null ||
        !snapshot.info.permissions.contains(permission)) {
      return;
    }
    final proof = WebsiteHandoffProof.create();
    final grant = await ref
        .read(websiteManagementRepositoryProvider)
        .open(section: section, codeChallenge: proof.challenge);
    await scope.verify();
    final uri = websiteEditorUri(
      info: snapshot.info,
      grant: grant,
      proof: proof,
      now: DateTime.now().toUtc(),
      releaseMode: kReleaseMode,
      allowLoopbackHttp: websiteAllowLoopbackHttp,
    );
    // Verify immediately before the external side effect, too.
    await scope.verify();
    final opened = await ref.read(websiteExternalLauncherProvider)(uri);
    if (!opened && mounted) {
      UtenNotify.error(context, AppLocalizations.of(context).websiteOpenFailed);
    }
  }, requiredPermission: permission);

  Future<void> _openPublic(WebsiteManagementInfo info) => _perform((
    scope,
  ) async {
    final uri = websiteOriginUri(
      info.publicOrigin,
      releaseMode: kReleaseMode,
      allowLoopbackHttp: websiteAllowLoopbackHttp,
    );
    await scope.verify();
    final opened = await ref.read(websiteExternalLauncherProvider)(uri);
    if (!opened && mounted) {
      UtenNotify.error(context, AppLocalizations.of(context).websiteOpenFailed);
    }
  });

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final permissions = ref.watch(currentPermissionsProvider);
    final owner = ref.watch(authenticatedScopeProvider);
    final value = ref.watch(websiteManagementProvider);
    return value.when(
      skipLoadingOnRefresh: false,
      loading: () => Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const CircularProgressIndicator(),
            const SizedBox(height: UtenSpacing.s16),
            Text(l.websiteConnectionChecking),
          ],
        ),
      ),
      error: (_, _) => UtenEmpty.error(
        message: l.websiteConnectionHelp,
        actionLabel: l.websiteCheckAgain,
        onAction: () => ref.invalidate(websiteManagementProvider),
      ),
      data: (snapshot) {
        final info = snapshot.info;
        final canConfigure =
            ref.watch(isSuperAdminProvider) &&
            permissions.contains(Perm.authorizationManage) &&
            info.canConfigure &&
            owner?.actorId == null;
        final canOpen = snapshot.ready && owner?.actorId == null && !_busy;
        final sections =
            <(String, String, String, String, IconData)>[
                  (
                    'home',
                    Perm.websiteContentEdit,
                    l.websiteHomeSection,
                    l.websiteHomeDescription,
                    Icons.home_outlined,
                  ),
                  (
                    'products',
                    Perm.websiteProductEdit,
                    l.websiteProductsSection,
                    l.websiteProductsDescription,
                    Icons.inventory_2_outlined,
                  ),
                  (
                    'resources',
                    Perm.websiteMediaManage,
                    l.websiteResourcesSection,
                    l.websiteResourcesDescription,
                    Icons.perm_media_outlined,
                  ),
                  (
                    'news',
                    Perm.websiteContentEdit,
                    l.websiteNewsSection,
                    l.websiteNewsDescription,
                    Icons.article_outlined,
                  ),
                  (
                    'settings',
                    Perm.websiteContentEdit,
                    l.websiteSettingsSection,
                    l.websiteSettingsDescription,
                    Icons.tune,
                  ),
                  (
                    'releases',
                    permissions.contains(Perm.websitePublish)
                        ? Perm.websitePublish
                        : Perm.websiteRollback,
                    l.websiteReleasesSection,
                    l.websiteReleasesDescription,
                    Icons.history,
                  ),
                ]
                .where(
                  (s) =>
                      permissions.contains(s.$2) &&
                      info.permissions.contains(s.$2),
                )
                .toList();
        return UtenContentContainer(
          child: SingleChildScrollView(
            padding: EdgeInsets.only(
              top: UtenSpacing.s16,
              bottom:
                  UtenCapsuleNavScope.occlusionOf(context) + UtenSpacing.s32,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                UtenCard(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Wrap(
                        spacing: UtenSpacing.s12,
                        runSpacing: UtenSpacing.s8,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        children: [
                          UtenSectionHeader(
                            title: info.displayName.isEmpty
                                ? l.websiteConnectionTitle
                                : info.displayName,
                            info: l.websiteManageSubtitle,
                          ),
                          UtenStatusBadge(
                            label: snapshot.ready
                                ? l.websiteConnectionReady
                                : l.websiteConnectionNotReady,
                            type: snapshot.ready
                                ? UtenStatusBadgeType.success
                                : UtenStatusBadgeType.warning,
                          ),
                        ],
                      ),
                      if (info.publicOrigin.isNotEmpty) ...[
                        const SizedBox(height: UtenSpacing.s8),
                        SelectableText(info.publicOrigin),
                      ],
                      if (!snapshot.ready) ...[
                        const SizedBox(height: UtenSpacing.s12),
                        Text(
                          snapshot.check?.message ?? l.websiteConnectionHelp,
                        ),
                        Text(
                          l.websiteEditingRequiresConnection,
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                      ],
                      const SizedBox(height: UtenSpacing.s16),
                      Wrap(
                        spacing: UtenSpacing.s24,
                        runSpacing: UtenSpacing.s12,
                        children: [
                          _Fact(
                            l.websiteLastChecked,
                            _date(
                              snapshot.check?.checkedAt ?? info.lastCheckedAt,
                              l,
                            ),
                          ),
                          _Fact(l.websiteLastSync, _date(info.lastSyncAt, l)),
                          if (snapshot.check?.publishedRevision != null)
                            _Fact(
                              l.websitePublishedRevision,
                              snapshot.check!.publishedRevision!,
                            ),
                          if (snapshot.check?.pendingInquiries != null ||
                              info.pendingInquiries != null)
                            _Fact(
                              l.websitePendingInquiries,
                              '${snapshot.check?.pendingInquiries ?? info.pendingInquiries}',
                            ),
                        ],
                      ),
                      const SizedBox(height: UtenSpacing.s20),
                      Wrap(
                        spacing: UtenSpacing.s8,
                        runSpacing: UtenSpacing.s8,
                        children: [
                          UtenButton(
                            key: const ValueKey('website-open-overview'),
                            isLoading: _busy,
                            icon: Icons.open_in_new,
                            onPressed:
                                canOpen &&
                                    info.permissions.contains(Perm.websiteView)
                                ? () => _open(
                                    snapshot,
                                    'overview',
                                    Perm.websiteView,
                                  )
                                : null,
                            child: Text(l.websiteOpenEditor),
                          ),
                          UtenActionButton(
                            type: UtenActionButtonType.secondary,
                            icon: Icons.refresh,
                            label: Text(l.websiteCheckAgain),
                            onAction: () async {
                              if (_busy) return;
                              ref.invalidate(websiteManagementProvider);
                              try {
                                await ref.read(
                                  websiteManagementProvider.future,
                                );
                              } catch (_) {
                                /* state displays recovery */
                              }
                            },
                          ),
                          if (info.configured)
                            UtenButton(
                              type: UtenButtonType.secondary,
                              icon: Icons.language,
                              onPressed: _busy ? null : () => _openPublic(info),
                              child: Text(l.websiteOpenPublic),
                            ),
                          if (canConfigure)
                            UtenButton(
                              key: const ValueKey('website-configure'),
                              type: UtenButtonType.ghost,
                              icon: Icons.settings_outlined,
                              onPressed: _busy
                                  ? null
                                  : () => setState(
                                      () => _showConfig = !_showConfig,
                                    ),
                              child: Text(l.websiteConfigure),
                            ),
                        ],
                      ),
                    ],
                  ),
                ),
                if (canConfigure && _showConfig) ...[
                  const SizedBox(height: UtenSpacing.s16),
                  _ConnectionEditor(
                    key: ValueKey(info.version),
                    info: info,
                    busy: _busy,
                    onSave: (name, origin, enabled) => _perform(
                      (scope) async {
                        await ref
                            .read(websiteManagementRepositoryProvider)
                            .configure(
                              expectedVersion: info.version,
                              displayName: name,
                              publicOrigin: origin,
                              enabled: enabled,
                            );
                        await scope.verify();
                        if (!mounted) return;
                        UtenNotify.success(this.context, l.websiteConfigSaved);
                        setState(() => _showConfig = false);
                        ref.invalidate(websiteManagementProvider);
                      },
                      requiredPermission: Perm.authorizationManage,
                      administrator: true,
                    ),
                  ),
                ],
                if (sections.isNotEmpty) ...[
                  const SizedBox(height: UtenSpacing.s24),
                  UtenSectionHeader(title: l.websiteContentTitle),
                  const SizedBox(height: UtenSpacing.s12),
                  UtenCard(
                    child: Column(
                      children: [
                        for (var i = 0; i < sections.length; i++) ...[
                          if (i > 0) const Divider(height: UtenSpacing.s24),
                          _SectionRow(
                            title: sections[i].$3,
                            description: sections[i].$4,
                            icon: sections[i].$5,
                            action: UtenButton(
                              size: UtenButtonSize.small,
                              type: UtenButtonType.secondary,
                              onPressed: canOpen
                                  ? () => _open(
                                      snapshot,
                                      sections[i].$1,
                                      sections[i].$2,
                                    )
                                  : null,
                              child: Text(l.websiteOpenEditor),
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                ],
                if (permissions.contains(Perm.webinquiryView)) ...[
                  const SizedBox(height: UtenSpacing.s24),
                  UtenCard(
                    child: _SectionRow(
                      title: l.websiteInquiryEntry,
                      description: l.websiteInquiryDescription,
                      icon: Icons.mark_email_unread_outlined,
                      action: UtenButton(
                        type: UtenButtonType.secondary,
                        onPressed: () =>
                            goFrom(context, RouteName.websiteInquiry),
                        child: Text(l.websiteInquiryEntry),
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
        );
      },
    );
  }
}

class _Fact extends StatelessWidget {
  const _Fact(this.label, this.value);
  final String label, value;
  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(label, style: Theme.of(context).textTheme.bodySmall),
      const SizedBox(height: UtenSpacing.s4),
      Text(value, style: Theme.of(context).textTheme.bodyMedium),
    ],
  );
}

class _SectionRow extends StatelessWidget {
  const _SectionRow({
    required this.title,
    required this.description,
    required this.icon,
    required this.action,
  });
  final String title, description;
  final IconData icon;
  final Widget action;
  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final text = UtenSectionHeader(title: title, info: description);
      if (constraints.maxWidth < 580 ||
          MediaQuery.textScalerOf(context).scale(1) > 1.4) {
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            text,
            const SizedBox(height: UtenSpacing.s12),
            action,
          ],
        );
      }
      return Row(
        children: [
          Icon(icon, color: Theme.of(context).colorScheme.primary),
          const SizedBox(width: UtenSpacing.s16),
          Expanded(child: text),
          const SizedBox(width: UtenSpacing.s16),
          action,
        ],
      );
    },
  );
}

class _ConnectionEditor extends StatefulWidget {
  const _ConnectionEditor({
    super.key,
    required this.info,
    required this.busy,
    required this.onSave,
  });
  final WebsiteManagementInfo info;
  final bool busy;
  final Future<void> Function(String name, String origin, bool enabled) onSave;
  @override
  State<_ConnectionEditor> createState() => _ConnectionEditorState();
}

class _ConnectionEditorState extends State<_ConnectionEditor> {
  late final _name = TextEditingController(text: widget.info.displayName);
  late String? _origin =
      widget.info.allowedOrigins.contains(widget.info.publicOrigin)
      ? widget.info.publicOrigin
      : null;
  late bool _enabled = widget.info.enabled;
  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    return UtenCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          UtenSectionHeader(
            title: l.websiteConfigure,
            info: l.websiteConfigureHelp,
          ),
          const SizedBox(height: UtenSpacing.s16),
          UtenInput(
            label: l.websiteDisplayName,
            controller: _name,
            enabled: !widget.busy,
          ),
          const SizedBox(height: UtenSpacing.s12),
          UtenDropdownField(
            label: l.websiteApprovedOrigin,
            value: _origin,
            enabled: !widget.busy,
            allowClear: false,
            items: [
              for (final origin in widget.info.allowedOrigins)
                UtenDropdownItem(value: origin, label: origin),
            ],
            onChanged: (value) => setState(() => _origin = value),
          ),
          if (widget.info.allowedOrigins.isEmpty)
            Text(l.websiteConfigNoOrigins),
          SwitchListTile.adaptive(
            contentPadding: EdgeInsets.zero,
            title: Text(l.websiteEnabled),
            value: _enabled,
            onChanged: widget.busy ? null : (v) => setState(() => _enabled = v),
          ),
          UtenButton(
            isLoading: widget.busy,
            onPressed: widget.busy
                ? null
                : () async {
                    if (_name.text.trim().isEmpty ||
                        _name.text.trim().length > 80 ||
                        _origin == null ||
                        !widget.info.allowedOrigins.contains(_origin)) {
                      UtenNotify.error(context, l.websiteConfigRequired);
                      return;
                    }
                    await widget.onSave(_name.text.trim(), _origin!, _enabled);
                  },
            child: Text(l.websiteSaveConfig),
          ),
        ],
      ),
    );
  }
}

String _date(DateTime? value, AppLocalizations l) =>
    value == null ? l.websiteNoRecord : ChinaDateTime.formatInstant(value);
