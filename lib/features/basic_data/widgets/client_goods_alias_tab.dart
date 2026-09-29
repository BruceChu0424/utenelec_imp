// Customer detail tab 货品对照 (ADR-134): how this customer writes our goods.
//
// The server learns these rows when sales save a quotation or order that came
// from the customer's file (SAP "customer material info record" / Kingdee
// 客户物料对应表). This tab only reads them and lets a person delete a wrong
// one; nothing here creates or edits a row, and no price is ever shown.
//
// - Paged server list (GET /master/clients/{id}/goods-aliases) with keyword
//   search; newest confirmation first.
// - Delete per row only when the server row capability canDelete is true
//   (client:edit + write scope), after a confirm that states the effect; a
//   full-screen busy overlay covers the network call.
// - The list is a plain vertical ListView without an explicit controller so
//   the party page's collapsing header keeps scrolling with it.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../components/buttons/uten_button.dart';
import '../../../components/cards/uten_card.dart';
import '../../../components/data_display/uten_status_badge.dart';
import '../../../components/feedback/uten_busy_overlay.dart';
import '../../../components/feedback/uten_dialog.dart';
import '../../../components/feedback/uten_empty.dart';
import '../../../components/inputs/uten_search_bar.dart';
import '../../../components/layout/uten_floating_action_group.dart';
import '../../../components/layout/uten_section_header.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../core/ui/app_notification.dart';
import '../../../core/utils/china_datetime.dart';
import '../../../shared/models/paged_result.dart';
import '../models/client_goods_alias.dart';
import '../repositories/client_goods_alias_repository.dart';
import 'basic_data_l10n.dart';

class ClientGoodsAliasTab extends ConsumerStatefulWidget {
  const ClientGoodsAliasTab({
    super.key,
    required this.clientId,
    this.pageSize = 20,
  });

  final String clientId;
  final int pageSize;

  @override
  ConsumerState<ClientGoodsAliasTab> createState() =>
      _ClientGoodsAliasTabState();
}

class _ClientGoodsAliasTabState extends ConsumerState<ClientGoodsAliasTab> {
  PagedResult<ClientGoodsAlias>? _result;
  int _page = 1;
  String _keyword = '';
  bool _loading = false;
  String? _error;

  /// Alias being deleted; non-null shows the full-screen busy overlay.
  String? _deletingId;

  /// Latest-request guard: a slow older response never overwrites a newer one.
  int _generation = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load(1));
  }

  @override
  void didUpdateWidget(covariant ClientGoodsAliasTab oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.clientId != widget.clientId) {
      _keyword = '';
      _result = null;
      _load(1);
    }
  }

  Future<void> _load(int page) async {
    if (!mounted) return;
    final generation = ++_generation;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final result = await ref
          .read(clientGoodsAliasRepositoryProvider)
          .list(
            widget.clientId,
            page: page,
            size: widget.pageSize,
            keyword: _keyword,
          );
      if (!mounted || generation != _generation) return;
      setState(() {
        _result = result;
        _page = result.page < 1 ? page : result.page;
        _loading = false;
      });
    } on ApiException catch (e) {
      if (!mounted || generation != _generation) return;
      setState(() {
        _error = e.message;
        _loading = false;
      });
    } catch (_) {
      if (!mounted || generation != _generation) return;
      setState(() {
        _error = basicDataL10n(context).clientGoodsAliasLoadFailed;
        _loading = false;
      });
    }
  }

  void _onKeywordChanged(String value) {
    final keyword = value.trim();
    if (keyword == _keyword) return;
    _keyword = keyword;
    _load(1);
  }

  String _goodsLabel(ClientGoodsAlias alias) {
    final label = alias.goods?.label ?? '';
    return label.isEmpty
        ? basicDataL10n(context).clientGoodsAliasGoodsMissing
        : label;
  }

  Future<void> _delete(ClientGoodsAlias alias) async {
    final l10n = basicDataL10n(context);
    final confirmed = await UtenDialog.show(
      context,
      title: l10n.clientGoodsAliasDelete,
      content: Text(
        l10n.clientGoodsAliasDeleteConfirm(alias.aliasText, _goodsLabel(alias)),
      ),
      confirmLabel: l10n.clientGoodsAliasDeleteAction,
      cancelLabel: l10n.commonCancel,
      danger: true,
    );
    if (confirmed != true || !mounted) return;
    setState(() => _deletingId = alias.id);
    Object? failure;
    try {
      await ref
          .read(clientGoodsAliasRepositoryProvider)
          .delete(widget.clientId, alias.id);
    } catch (e) {
      failure = e;
    } finally {
      if (mounted) setState(() => _deletingId = null);
    }
    if (!mounted) return;
    // The overlay is a root overlay entry: let it leave before any notice.
    await WidgetsBinding.instance.endOfFrame;
    if (!mounted) return;
    if (failure != null) {
      context.appApiError(failure);
      return;
    }
    context.appSuccess(l10n.clientGoodsAliasDeleted);
    final remaining = (_result?.items.length ?? 1) - 1;
    await _load(remaining <= 0 && _page > 1 ? _page - 1 : _page);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = basicDataL10n(context);
    final list = ListView(
      key: const ValueKey('client-goods-alias-list'),
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(
        UtenSpacing.s16,
        UtenSpacing.s16,
        UtenSpacing.s16,
        UtenFloatingActionGroup.scrollClearance,
      ),
      children: [
        UtenSectionHeader(
          title: l10n.clientGoodsAliasTitle,
          icon: Icons.translate_rounded,
        ),
        const SizedBox(height: UtenSpacing.s4),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: UtenSpacing.s4),
          child: Text(
            l10n.clientGoodsAliasDescription,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
              height: 1.5,
            ),
          ),
        ),
        const SizedBox(height: UtenSpacing.s12),
        UtenSearchBar(
          key: const ValueKey('client-goods-alias-search'),
          hint: l10n.clientGoodsAliasSearchHint,
          initialValue: _keyword,
          onChanged: _onKeywordChanged,
          onSubmitted: _onKeywordChanged,
        ),
        const SizedBox(height: UtenSpacing.s12),
        UtenCard(
          padding: EdgeInsets.zero,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // Thin progress line while a search / page change is running
              // over rows that are already shown.
              if (_loading && _result != null)
                const LinearProgressIndicator(minHeight: 2),
              _content(theme),
            ],
          ),
        ),
        if (_result != null && _result!.total > 0) ...[
          const SizedBox(height: UtenSpacing.s12),
          _pager(theme),
        ],
      ],
    );
    return Stack(
      fit: StackFit.expand,
      children: [
        RefreshIndicator(onRefresh: () => _load(_page), child: list),
        if (_deletingId != null)
          UtenBusyOverlay(title: l10n.clientGoodsAliasDeleting),
      ],
    );
  }

  Widget _content(ThemeData theme) {
    final l10n = basicDataL10n(context);
    final result = _result;
    if (result == null) {
      if (_error != null) return _errorState(_error!);
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: UtenSpacing.s32),
        child: Center(child: CircularProgressIndicator(strokeWidth: 2.5)),
      );
    }
    if (_error != null) return _errorState(_error!);
    if (result.items.isEmpty) {
      return _keyword.isEmpty
          ? _emptyState(
              icon: Icons.translate_rounded,
              title: l10n.clientGoodsAliasEmptyTitle,
              message: l10n.clientGoodsAliasEmpty,
            )
          : _emptyState(
              icon: Icons.search_off_rounded,
              title: l10n.clientGoodsAliasNoMatch,
            );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (var i = 0; i < result.items.length; i++) ...[
          if (i > 0) const Divider(height: 1, indent: 70),
          _aliasRow(theme, result.items[i]),
        ],
      ],
    );
  }

  Widget _aliasRow(ThemeData theme, ClientGoodsAlias alias) {
    final l10n = basicDataL10n(context);
    final kindColor = alias.isPartNo
        ? theme.colorScheme.primary
        : theme.colorScheme.tertiary;
    final lastDate = ChinaDateTime.tryParse(alias.lastConfirmedAt);
    final byName = alias.lastConfirmedByName?.trim() ?? '';
    final meta = <String>[
      if (alias.hasContext)
        l10n.clientGoodsAliasContext(alias.contextText!.trim()),
      if (alias.confirmCount > 0)
        alias.explicitCount > 0
            ? '${l10n.clientGoodsAliasConfirmCount(alias.confirmCount)}, '
                  '${l10n.clientGoodsAliasExplicitCount(alias.explicitCount)}'
            : l10n.clientGoodsAliasConfirmCount(alias.confirmCount),
      if (lastDate != null)
        byName.isEmpty
            ? l10n.clientGoodsAliasLastConfirmed(
                ChinaDateTime.formatDate(lastDate),
              )
            : l10n.clientGoodsAliasLastConfirmedBy(
                ChinaDateTime.formatDate(lastDate),
                byName,
              ),
    ];
    final goodsMissing = alias.goods == null;
    return Padding(
      key: ValueKey('client-goods-alias-${alias.id}'),
      padding: const EdgeInsetsDirectional.fromSTEB(
        UtenSpacing.s16,
        UtenSpacing.s12,
        UtenSpacing.s4,
        UtenSpacing.s12,
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 42,
            height: 42,
            decoration: BoxDecoration(
              color: kindColor.withValues(alpha: 0.12),
              borderRadius: UtenRadius.controlAll,
            ),
            child: Icon(
              alias.isPartNo ? Icons.tag_rounded : Icons.notes_rounded,
              size: 22,
              color: kindColor,
            ),
          ),
          const SizedBox(width: UtenSpacing.s12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // The customer's own wording, as written in its file.
                Text(
                  alias.aliasText,
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: UtenSpacing.s4),
                // Which of our goods it means.
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: Icon(
                        Icons.subdirectory_arrow_right_rounded,
                        size: 18,
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                    const SizedBox(width: UtenSpacing.s4),
                    Expanded(
                      child: Text(
                        _goodsLabel(alias),
                        style: theme.textTheme.bodyLarge?.copyWith(
                          fontWeight: FontWeight.w500,
                          color: goodsMissing ? theme.colorScheme.error : null,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: UtenSpacing.s8),
                Wrap(
                  spacing: UtenSpacing.s8,
                  runSpacing: UtenSpacing.s4,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    UtenStatusBadge(
                      label: alias.isPartNo
                          ? l10n.clientGoodsAliasKindPartNo
                          : l10n.clientGoodsAliasKindDescription,
                      type: alias.isPartNo
                          ? UtenStatusBadgeType.info
                          : UtenStatusBadgeType.neutral,
                      size: UtenStatusBadgeSize.small,
                    ),
                    if (meta.isNotEmpty)
                      Text(
                        meta.join(' · '),
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                  ],
                ),
              ],
            ),
          ),
          if (alias.canDelete)
            IconButton(
              key: ValueKey('client-goods-alias-delete-${alias.id}'),
              tooltip: l10n.clientGoodsAliasDelete,
              icon: Icon(
                Icons.delete_outline_rounded,
                size: 22,
                color: theme.colorScheme.error,
              ),
              onPressed: _deletingId == null ? () => _delete(alias) : null,
            ),
        ],
      ),
    );
  }

  Widget _emptyState({
    required IconData icon,
    required String title,
    String? message,
  }) => UtenEmpty(
    key: const ValueKey('client-goods-alias-empty'),
    icon: icon,
    message: title,
    description: message,
  );

  Widget _errorState(String message) => UtenEmpty.error(
    key: const ValueKey('client-goods-alias-error'),
    message: message,
    actionLabel: basicDataL10n(context).commonRetry,
    onAction: _loading ? null : () => _load(_page),
  );

  Widget _pager(ThemeData theme) {
    final l10n = basicDataL10n(context);
    final result = _result!;
    final pages = result.totalPages < 1 ? 1 : result.totalPages;
    final canPrev = !_loading && _page > 1;
    final canNext = !_loading && _page < pages;
    return Wrap(
      key: const ValueKey('client-goods-alias-pager'),
      alignment: WrapAlignment.spaceBetween,
      crossAxisAlignment: WrapCrossAlignment.center,
      spacing: UtenSpacing.s12,
      runSpacing: UtenSpacing.s8,
      children: [
        Text(
          l10n.clientGoodsAliasTotal(result.total),
          style: theme.textTheme.bodyMedium?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        if (pages > 1)
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              UtenButton(
                key: const ValueKey('client-goods-alias-prev'),
                type: UtenButtonType.secondary,
                icon: Icons.chevron_left_rounded,
                onPressed: canPrev ? () => _load(_page - 1) : null,
                child: Text(l10n.clientGoodsAliasPrevPage),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: UtenSpacing.s12,
                ),
                child: Text(
                  l10n.clientGoodsAliasPage(_page, pages),
                  style: theme.textTheme.bodyMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              UtenButton(
                key: const ValueKey('client-goods-alias-next'),
                type: UtenButtonType.secondary,
                icon: Icons.chevron_right_rounded,
                onPressed: canNext ? () => _load(_page + 1) : null,
                child: Text(l10n.clientGoodsAliasNextPage),
              ),
            ],
          ),
      ],
    );
  }
}
