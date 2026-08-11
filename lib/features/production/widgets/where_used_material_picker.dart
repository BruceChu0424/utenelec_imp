import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/network/api_client.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/responsive/breakpoint.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../basic_data/models/goods_node.dart';

/// 物料反查专用选择器。
///
/// 与通用货品选择器不同，本选择器搜索全部匹配货品，再标注当前直接 BOM、生产和委外证据，
/// 并保留禁用、自动占位及软删除的历史物料。接口只要求
/// `production_where_used:view`，因此反查页不会额外依赖 `goods:view`。
Future<GoodsListItem?> showWhereUsedMaterialPicker(
  BuildContext context,
  WidgetRef ref,
) {
  final picker = _WhereUsedMaterialPicker(
    api: ref.read(apiClientProvider),
    autofocus: !context.breakpoint.isCompact,
  );

  if (context.breakpoint.isCompact) {
    return showModalBottomSheet<GoodsListItem>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      showDragHandle: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(
          top: Radius.circular(UtenRadius.xxl),
        ),
      ),
      builder: (_) => FractionallySizedBox(heightFactor: 0.92, child: picker),
    );
  }

  return showDialog<GoodsListItem>(
    context: context,
    builder: (dialogContext) {
      final viewport = MediaQuery.sizeOf(dialogContext);
      return Dialog(
        insetPadding: const EdgeInsets.all(UtenSpacing.s24),
        clipBehavior: Clip.antiAlias,
        shape: const RoundedRectangleBorder(borderRadius: UtenRadius.xxlAll),
        child: SizedBox(
          width: math.min(760, math.max(320, viewport.width - 48)),
          height: math.min(720, math.max(280, viewport.height - 48)),
          child: picker,
        ),
      );
    },
  );
}

class _WhereUsedMaterialPicker extends StatefulWidget {
  const _WhereUsedMaterialPicker({required this.api, required this.autofocus});

  final ApiClient api;
  final bool autofocus;

  @override
  State<_WhereUsedMaterialPicker> createState() =>
      _WhereUsedMaterialPickerState();
}

class _WhereUsedMaterialPickerState extends State<_WhereUsedMaterialPicker> {
  static const _pageSize = 50;
  static const _debounceDuration = Duration(milliseconds: 250);

  final _keywordController = TextEditingController();
  Timer? _debounce;
  _MaterialPage? _result;
  String _keyword = '';
  String? _error;
  int _page = 1;
  int _requestGeneration = 0;
  bool _loading = false;

  @override
  void dispose() {
    _debounce?.cancel();
    _keywordController.dispose();
    super.dispose();
  }

  void _onKeywordChanged(String value) {
    _debounce?.cancel();
    final generation = ++_requestGeneration;
    final hasKeyword = value.trim().isNotEmpty;
    setState(() {
      _keyword = value;
      _page = 1;
      _result = null;
      _error = null;
      _loading = hasKeyword;
    });
    if (!hasKeyword) return;
    _debounce = Timer(_debounceDuration, () => _load(generation: generation));
  }

  void _submitKeyword() {
    _debounce?.cancel();
    _page = 1;
    if (_keyword.trim().isEmpty) {
      _resetToSearchPrompt();
      return;
    }
    _reload();
  }

  void _clearKeyword() {
    _keywordController.clear();
    _onKeywordChanged('');
  }

  void _reload() {
    _debounce?.cancel();
    if (_keyword.trim().isEmpty) {
      _resetToSearchPrompt();
      return;
    }
    final generation = ++_requestGeneration;
    setState(() {
      _loading = true;
      _error = null;
      _result = null;
    });
    _load(generation: generation);
  }

  void _resetToSearchPrompt() {
    ++_requestGeneration;
    setState(() {
      _page = 1;
      _result = null;
      _error = null;
      _loading = false;
    });
  }

  Future<void> _load({required int generation}) async {
    final keyword = _keyword.trim();
    if (keyword.isEmpty) return;
    final requestedPage = _page;
    try {
      final json = await widget.api.get(
        '/production/reports/where-used/materials',
        query: <String, dynamic>{
          'keyword': keyword,
          'page': requestedPage,
          'size': _pageSize,
        },
      );
      if (!mounted || generation != _requestGeneration) return;
      final result = _MaterialPage.fromJson(json, fallbackPage: requestedPage);
      setState(() {
        _result = result;
        _page = result.page;
        _loading = false;
      });
    } catch (error) {
      if (!mounted || generation != _requestGeneration) return;
      setState(() {
        _loading = false;
        _error = error is ApiException ? error.message : '物料加载失败，请稍后重试';
      });
    }
  }

  void _goToPage(int page) {
    if (_loading || page < 1 || page == _page) return;
    _page = page;
    _reload();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SafeArea(
      key: const Key('where-used-material-picker'),
      child: Column(
        children: [
          _buildHeader(theme),
          const Divider(height: 1),
          Padding(
            padding: const EdgeInsets.fromLTRB(
              UtenSpacing.s16,
              UtenSpacing.s12,
              UtenSpacing.s16,
              UtenSpacing.s8,
            ),
            child: TextField(
              key: const Key('where-used-material-search'),
              controller: _keywordController,
              autofocus: widget.autofocus,
              textInputAction: TextInputAction.search,
              onChanged: _onKeywordChanged,
              onSubmitted: (_) => _submitKeyword(),
              decoration: InputDecoration(
                labelText: '搜索物料',
                hintText: '编号 / 名称 / 型号 / 规格等',
                helperText: '搜索全部匹配货品，并标注当前直接 BOM、生产及委外证据',
                prefixIcon: const Icon(Icons.search_rounded),
                suffixIcon: _keyword.isEmpty
                    ? null
                    : IconButton(
                        key: const Key('where-used-material-clear'),
                        tooltip: '清除搜索',
                        onPressed: _clearKeyword,
                        icon: const Icon(Icons.close_rounded),
                      ),
                border: const OutlineInputBorder(),
              ),
            ),
          ),
          if (_loading) const LinearProgressIndicator(minHeight: 2),
          if (!_loading) const SizedBox(height: 2),
          Expanded(child: _buildContent(theme)),
          if (_result != null && _result!.totalPages > 1) ...[
            const Divider(height: 1),
            _buildPager(theme, _result!),
          ],
        ],
      ),
    );
  }

  Widget _buildHeader(ThemeData theme) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        UtenSpacing.s20,
        UtenSpacing.s16,
        UtenSpacing.s8,
        UtenSpacing.s12,
      ),
      child: Row(
        children: [
          Icon(Icons.widgets_outlined, color: theme.colorScheme.primary),
          const SizedBox(width: UtenSpacing.s8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '选择要反查的物料',
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
                if (_result != null)
                  Text(
                    '共 ${_result!.total} 个匹配物料',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
              ],
            ),
          ),
          IconButton(
            tooltip: '关闭',
            onPressed: () => Navigator.of(context).pop(),
            icon: const Icon(Icons.close_rounded),
          ),
        ],
      ),
    );
  }

  Widget _buildContent(ThemeData theme) {
    if (_loading && _result == null) {
      return Center(
        child: Semantics(
          liveRegion: true,
          label: '正在加载可反查物料',
          child: const CircularProgressIndicator(strokeWidth: 2.5),
        ),
      );
    }
    if (_error != null) {
      return _scrollableState(
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(UtenSpacing.s24),
            child: Semantics(
              liveRegion: true,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Icons.error_outline_rounded,
                    color: theme.colorScheme.error,
                    size: 36,
                  ),
                  const SizedBox(height: UtenSpacing.s8),
                  Text(_error!, textAlign: TextAlign.center),
                  const SizedBox(height: UtenSpacing.s12),
                  FilledButton.tonalIcon(
                    key: const Key('where-used-material-retry'),
                    onPressed: _reload,
                    icon: const Icon(Icons.refresh_rounded),
                    label: const Text('重试'),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
    }
    if (_keyword.trim().isEmpty && _result == null) {
      return _scrollableState(
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(UtenSpacing.s24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  Icons.manage_search_rounded,
                  color: theme.colorScheme.primary,
                  size: 40,
                ),
                const SizedBox(height: UtenSpacing.s8),
                const Text('输入编号/名称开始搜索'),
                const SizedBox(height: UtenSpacing.s4),
                Text(
                  '支持物料编号、名称、型号或规格，输入后将自动搜索。',
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    }

    final result = _result;
    if (result == null || result.items.isEmpty) {
      return _scrollableState(
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(UtenSpacing.s24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  Icons.search_off_rounded,
                  color: theme.colorScheme.onSurfaceVariant,
                  size: 40,
                ),
                const SizedBox(height: UtenSpacing.s8),
                const Text('没有匹配的物料'),
                const SizedBox(height: UtenSpacing.s4),
                Text(
                  '请尝试更短的编号或名称，也可改用型号或规格。',
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
                if (_keyword.isNotEmpty) ...[
                  const SizedBox(height: UtenSpacing.s12),
                  TextButton.icon(
                    onPressed: _clearKeyword,
                    icon: const Icon(Icons.clear_all_rounded),
                    label: const Text('清除搜索'),
                  ),
                ],
              ],
            ),
          ),
        ),
      );
    }

    return ListView.separated(
      keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
      itemCount: result.items.length,
      separatorBuilder: (_, _) => const Divider(height: 1),
      itemBuilder: (context, index) {
        final item = result.items[index];
        return _MaterialTile(
          key: ValueKey('where-used-material-${item.id}'),
          item: item,
          onTap: () => Navigator.of(context).pop(item.toGoodsListItem()),
        );
      },
    );
  }

  Widget _scrollableState({required Widget child}) {
    return LayoutBuilder(
      builder: (context, constraints) => SingleChildScrollView(
        child: ConstrainedBox(
          constraints: BoxConstraints(
            minHeight: constraints.hasBoundedHeight ? constraints.maxHeight : 0,
          ),
          child: child,
        ),
      ),
    );
  }

  Widget _buildPager(ThemeData theme, _MaterialPage result) {
    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: UtenSpacing.s12,
        vertical: UtenSpacing.s8,
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          IconButton(
            key: const Key('where-used-material-prev'),
            tooltip: '上一页',
            onPressed: !_loading && result.page > 1
                ? () => _goToPage(result.page - 1)
                : null,
            icon: const Icon(Icons.chevron_left_rounded),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: UtenSpacing.s12),
            child: Text(
              '${result.page} / ${result.totalPages}',
              style: theme.textTheme.labelLarge,
            ),
          ),
          IconButton(
            key: const Key('where-used-material-next'),
            tooltip: '下一页',
            onPressed: !_loading && result.page < result.totalPages
                ? () => _goToPage(result.page + 1)
                : null,
            icon: const Icon(Icons.chevron_right_rounded),
          ),
        ],
      ),
    );
  }
}

class _MaterialTile extends StatelessWidget {
  const _MaterialTile({super.key, required this.item, required this.onTap});

  final _WhereUsedMaterial item;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final details = <String>[
      if (item.code.isNotEmpty) item.code,
      if (item.model.isNotEmpty) item.model,
      if (item.spec.isNotEmpty) item.spec,
      if (item.categoryName.isNotEmpty) item.categoryName,
    ];
    final hasKnownEvidence =
        item.currentBom ||
        item.bomIssue ||
        item.productionHistory ||
        item.subcontractHistory;

    final semanticSources = <String>[
      if (item.currentBom) '当前 BOM',
      if (item.bomIssue) 'BOM 异常待治理',
      if (item.productionHistory) '生产历史',
      if (item.subcontractHistory) '委外历史',
      if (!hasKnownEvidence) '暂无已知关系',
      if (item.autoCreated) '自动占位',
      if (item.deleted) '已删除',
      if (item.status.isNotEmpty) '状态 ${item.status}',
    ].join('，');

    return Semantics(
      button: true,
      label: '选择物料 ${item.displayName}，$semanticSources',
      child: ListTile(
        contentPadding: const EdgeInsets.symmetric(
          horizontal: UtenSpacing.s16,
          vertical: UtenSpacing.s4,
        ),
        title: Text(
          item.displayName,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: theme.textTheme.bodyLarge?.copyWith(
            fontWeight: FontWeight.w600,
          ),
        ),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (details.isNotEmpty) ...[
              const SizedBox(height: 2),
              Text(
                details.join(' · '),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            ],
            const SizedBox(height: UtenSpacing.s8),
            Wrap(
              spacing: UtenSpacing.s4,
              runSpacing: UtenSpacing.s4,
              children: [
                if (item.currentBom)
                  const _MaterialTag(label: '当前 BOM', tone: _TagTone.primary),
                if (item.bomIssue)
                  const _MaterialTag(label: 'BOM 异常', tone: _TagTone.error),
                if (item.productionHistory)
                  const _MaterialTag(label: '生产历史', tone: _TagTone.secondary),
                if (item.subcontractHistory)
                  const _MaterialTag(label: '委外历史', tone: _TagTone.tertiary),
                if (!hasKnownEvidence)
                  const _MaterialTag(label: '暂无已知关系', tone: _TagTone.neutral),
                if (item.status.isNotEmpty)
                  _MaterialTag(
                    label: '状态：${item.status}',
                    tone: item.status == '禁用'
                        ? _TagTone.warning
                        : _TagTone.neutral,
                  ),
                if (item.autoCreated)
                  const _MaterialTag(label: '自动占位', tone: _TagTone.warning),
                if (item.deleted)
                  const _MaterialTag(label: '已删除', tone: _TagTone.error),
              ],
            ),
          ],
        ),
        trailing: const Icon(Icons.chevron_right_rounded),
        onTap: onTap,
      ),
    );
  }
}

enum _TagTone { primary, secondary, tertiary, neutral, warning, error }

class _MaterialTag extends StatelessWidget {
  const _MaterialTag({required this.label, required this.tone});

  final String label;
  final _TagTone tone;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final (background, foreground) = switch (tone) {
      _TagTone.primary => (colors.primaryContainer, colors.onPrimaryContainer),
      _TagTone.secondary => (
        colors.secondaryContainer,
        colors.onSecondaryContainer,
      ),
      _TagTone.tertiary => (
        colors.tertiaryContainer,
        colors.onTertiaryContainer,
      ),
      _TagTone.neutral => (
        colors.surfaceContainerHighest,
        colors.onSurfaceVariant,
      ),
      _TagTone.warning => (
        colors.errorContainer.withValues(alpha: 0.55),
        colors.onErrorContainer,
      ),
      _TagTone.error => (colors.errorContainer, colors.onErrorContainer),
    };
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: UtenSpacing.s8,
        vertical: 3,
      ),
      decoration: BoxDecoration(
        color: background,
        borderRadius: UtenRadius.pillAll,
      ),
      child: Text(
        label,
        style: Theme.of(context).textTheme.labelSmall?.copyWith(
          color: foreground,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

class _MaterialPage {
  const _MaterialPage({
    required this.items,
    required this.page,
    required this.total,
    required this.totalPages,
  });

  final List<_WhereUsedMaterial> items;
  final int page;
  final int total;
  final int totalPages;

  factory _MaterialPage.fromJson(
    Map<String, dynamic> json, {
    required int fallbackPage,
  }) {
    final rawItems = json['items'] as List? ?? const [];
    final items = <_WhereUsedMaterial>[];
    for (final raw in rawItems) {
      if (raw is! Map) continue;
      final item = _WhereUsedMaterial.fromJson(Map<String, dynamic>.from(raw));
      if (item.id.isNotEmpty) items.add(item);
    }
    final totalPages = _asInt(json['totalPages'], 1);
    return _MaterialPage(
      items: items,
      page: math.max(1, _asInt(json['page'], fallbackPage)),
      total: math.max(0, _asInt(json['total'], items.length)),
      totalPages: math.max(1, totalPages),
    );
  }
}

class _WhereUsedMaterial {
  const _WhereUsedMaterial({
    required this.id,
    required this.code,
    required this.name,
    required this.model,
    required this.spec,
    required this.status,
    required this.sourceType,
    required this.categoryName,
    required this.autoCreated,
    required this.deleted,
    required this.currentBom,
    required this.bomIssue,
    required this.productionHistory,
    required this.subcontractHistory,
  });

  final String id;
  final String code;
  final String name;
  final String model;
  final String spec;
  final String status;
  final String sourceType;
  final String categoryName;
  final bool autoCreated;
  final bool deleted;
  final bool currentBom;
  final bool bomIssue;
  final bool productionHistory;
  final bool subcontractHistory;

  factory _WhereUsedMaterial.fromJson(Map<String, dynamic> json) =>
      _WhereUsedMaterial(
        id: _asText(json['id']),
        code: _asText(json['code']),
        name: _asText(json['name']),
        model: _asText(json['model']),
        spec: _asText(json['spec']),
        status: _asText(json['status']),
        sourceType: _asText(json['sourceType']),
        categoryName: _asText(json['categoryName']),
        autoCreated: _asBool(json['autoCreated']),
        deleted: _asBool(json['deleted']),
        currentBom: _asBool(json['currentBom']),
        bomIssue: _asBool(json['bomIssue']),
        productionHistory: _asBool(json['productionHistory']),
        subcontractHistory: _asBool(json['subcontractHistory']),
      );

  String get displayName {
    final effectiveName = name.isEmpty ? '（无名称）' : name;
    return code.isEmpty ? effectiveName : '$effectiveName（$code）';
  }

  GoodsListItem toGoodsListItem() => GoodsListItem(
    id: id,
    code: code.isEmpty ? null : code,
    name: name.isEmpty ? null : name,
    spec: spec.isEmpty ? null : spec,
    model: model.isEmpty ? null : model,
    status: status.isEmpty ? null : status,
    sourceType: sourceType.isEmpty ? null : sourceType,
    autoCreated: autoCreated,
  );
}

String _asText(Object? value) => value?.toString().trim() ?? '';

int _asInt(Object? value, int fallback) {
  if (value is num) return value.toInt();
  return int.tryParse(_asText(value)) ?? fallback;
}

bool _asBool(Object? value) {
  if (value is bool) return value;
  if (value is num) return value != 0;
  final text = _asText(value).toLowerCase();
  return text == 'true' || text == '1' || text == 'yes';
}
