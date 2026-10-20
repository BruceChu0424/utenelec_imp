import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/network/api_client.dart';
import '../../../core/l10n/gen/app_localizations.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../shared/models/paged_result.dart';
import '../../../shared/providers/sensitive_read_boundary_provider.dart';
import '../../basic_data/models/goods_node.dart';
import '../../basic_data/models/product_category_node.dart';
import '../../basic_data/widgets/uten_goods_picker.dart';
import '../../basic_data/widgets/master_data_table_view.dart';

/// Reuses the sales picker shell and its staged single-selection contract.
/// The read-only report API keeps historical, disabled and placeholder goods
/// available without requiring goods:view or material_category:view.
Future<GoodsListItem?> showWhereUsedMaterialPicker(
  BuildContext context,
  WidgetRef ref, {
  String initialKeyword = '',
}) => showUtenGoodsPicker(
  context,
  ref,
  scope: UtenGoodsPickerScope.all,
  dataSource: _WhereUsedMaterialDataSource(ref.read(apiClientProvider)),
  title: '选择要反查的物料',
  initialKeyword: initialKeyword,
  readBoundary: ref.read(sensitiveReadBoundaryProvider),
);

/// Current replacement candidates use the same picker without requiring unrelated master-view grants.
Future<GoodsListItem?> showWhereUsedReplacementPicker(
  BuildContext context,
  WidgetRef ref, {
  required SensitiveReadBoundary readBoundary,
}) => showUtenGoodsPicker(
  context,
  ref,
  scope: UtenGoodsPickerScope.component,
  dataSource: _WhereUsedMaterialDataSource(
    readBoundary.api,
    operationalOnly: true,
  ),
  title: AppLocalizations.of(context).whereUsedReplacementPickerTitle,
  readBoundary: readBoundary,
);

/// Inline discovery uses the same report-only scope and historical candidates
/// as the full picker, without requiring master-data permissions.
Future<List<GoodsListItem>> loadWhereUsedMaterialSuggestions(
  ApiClient api,
  String keyword,
) async {
  if (keyword.trim().isEmpty) return const [];
  final result = await _WhereUsedMaterialDataSource(
    api,
  )._load(page: 1, keyword: keyword, size: 8);
  return result.items;
}

class _WhereUsedMaterialDataSource extends UtenGoodsPickerDataSource {
  _WhereUsedMaterialDataSource(this.api, {this.operationalOnly = false});

  final ApiClient api;
  final bool operationalOnly;
  // Bind evidence to the returned snapshot, so a late discarded request cannot
  // overwrite the tags of a newer visible item with the same goods ID.
  final _evidence = Map<GoodsListItem, _WhereUsedMaterial>.identity();
  static const _basePath = '/production/reports/where-used';

  @override
  bool get supportsRelatedSearch => true;

  @override
  bool isSelectable(GoodsListItem goods) {
    if (!operationalOnly) return true;
    final material = _evidence[goods];
    return material != null &&
        !material.deleted &&
        !material.autoCreated &&
        !const {
          '禁用',
          '停用',
          '报废',
          'DISABLED',
          'SCRAPPED',
          'STOPPED',
        }.contains(material.status.toUpperCase());
  }

  @override
  Future<List<ProductCategoryNode>> tree() async {
    final json = await api.get('$_basePath/material-categories');
    return (json['items'] as List? ?? const [])
        .map(
          (item) => ProductCategoryNode.fromJson(
            Map<String, dynamic>.from(item as Map),
          ),
        )
        .toList();
  }

  @override
  Future<PagedResult<GoodsListItem>> list(
    String categoryId, {
    required int page,
    String? keyword,
  }) => _load(page: page, categoryId: categoryId, keyword: keyword);

  @override
  Future<PagedResult<GoodsListItem>> search(
    String keyword, {
    required int page,
  }) => _load(page: page, keyword: keyword);

  @override
  Future<PagedResult<GoodsListItem>> searchWithOptions(
    String keyword, {
    required int page,
    String? categoryId,
    bool includeRelated = false,
  }) => _load(
    page: page,
    keyword: keyword,
    categoryId: categoryId,
    includeRelated: includeRelated,
  );

  Future<PagedResult<GoodsListItem>> _load({
    required int page,
    int size = 50,
    String? categoryId,
    String? keyword,
    bool includeRelated = false,
  }) async {
    final json = await api.get(
      '$_basePath/materials',
      query: {
        'categoryId': ?categoryId,
        if (keyword != null && keyword.trim().isNotEmpty)
          'keyword': keyword.trim(),
        if (includeRelated && keyword?.trim().isNotEmpty == true)
          'includeRelated': true,
        'page': page,
        'size': size,
      },
    );
    return PagedResult<GoodsListItem>.fromJson(json, (raw) {
      final material = _WhereUsedMaterial.fromJson(raw);
      final goods = material.toGoodsListItem();
      _evidence[goods] = material;
      return goods;
    });
  }

  @override
  Future<Set<String>> searchCategoryIds(String keyword) async {
    return searchCategoryIdsWithOptions(keyword);
  }

  @override
  Future<Set<String>> searchCategoryIdsWithOptions(
    String keyword, {
    String? categoryId,
    bool includeRelated = false,
  }) async {
    final json = await api.get(
      '$_basePath/material-category-matches',
      query: {
        'keyword': keyword.trim(),
        'categoryId': ?categoryId,
        if (includeRelated && keyword.trim().isNotEmpty) 'includeRelated': true,
      },
    );
    return (json['items'] as List? ?? const [])
        .map((item) => item.toString())
        .toSet();
  }

  @override
  List<MasterColumnDef<GoodsListItem>> get pickerColumns => [
    MasterColumnDef(
      key: 'name',
      label: '物料名称',
      width: 200,
      value: (goods) => goods.name,
      columnSearchEnabled: false,
    ),
    MasterColumnDef(
      key: 'code',
      label: '编号',
      width: 130,
      value: (goods) => goods.code,
      columnSearchEnabled: false,
    ),
    MasterColumnDef(
      key: 'category',
      label: '分类',
      width: 140,
      value: (goods) => _evidence[goods]?.categoryName,
      columnSearchEnabled: false,
    ),
    MasterColumnDef(
      key: 'status',
      label: '状态 / 提示',
      width: 240,
      value: (goods) {
        final item = _evidence[goods];
        if (item == null) return null;
        return [
          if (item.status.isNotEmpty) '状态：${item.status}',
          if (item.bomIssue) 'BOM 异常',
          if (item.autoCreated) '自动占位',
          if (item.deleted) '已删除',
        ].join(' · ');
      },
      cellBuilder: _statusCell,
      columnSearchEnabled: false,
    ),
    MasterColumnDef(
      key: 'evidence',
      label: '关联依据',
      width: 260,
      value: _evidenceLabel,
      columnSearchEnabled: false,
    ),
  ];

  String? _evidenceLabel(GoodsListItem goods) {
    final item = _evidence[goods];
    if (item == null) return null;
    final labels = [
      if (item.currentBom) '当前 BOM',
      if (item.productionHistory) '生产历史',
      if (item.subcontractHistory) '委外历史',
    ];
    return labels.isEmpty
        ? (item.bomIssue ? 'BOM 异常' : '暂无已知关系')
        : labels.join(' · ');
  }

  Widget _statusCell(BuildContext context, GoodsListItem goods) {
    final item = _evidence[goods];
    if (item == null) return const Text('—');
    final inactive = const {
      '禁用',
      '停用',
      'DISABLED',
      'INACTIVE',
    }.contains(item.status.toUpperCase());
    return Wrap(
      spacing: UtenSpacing.s4,
      runSpacing: UtenSpacing.s4,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        if (item.status.isNotEmpty)
          if (inactive)
            _MaterialTag(label: '状态：${item.status}', tone: _TagTone.warning)
          else
            Text(
              '状态：${item.status}',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
        if (item.bomIssue)
          const _MaterialTag(label: 'BOM 异常', tone: _TagTone.error),
        if (item.autoCreated)
          const _MaterialTag(label: '自动占位', tone: _TagTone.warning),
        if (item.deleted)
          const _MaterialTag(label: '已删除', tone: _TagTone.error),
      ],
    );
  }
}

enum _TagTone { warning, error }

class _MaterialTag extends StatelessWidget {
  const _MaterialTag({required this.label, required this.tone});

  final String label;
  final _TagTone tone;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final (background, foreground) = switch (tone) {
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
    required this.categoryId,
    required this.autoCreated,
    required this.deleted,
    required this.currentBom,
    required this.bomIssue,
    required this.productionHistory,
    required this.subcontractHistory,
    this.searchRank,
    this.searchMatchKind,
  });

  final String id;
  final String code;
  final String name;
  final String model;
  final String spec;
  final String status;
  final String sourceType;
  final String categoryName;
  final String categoryId;
  final bool autoCreated;
  final bool deleted;
  final bool currentBom;
  final bool bomIssue;
  final bool productionHistory;
  final bool subcontractHistory;
  final int? searchRank;
  final String? searchMatchKind;

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
        categoryId: _asText(json['categoryId']),
        autoCreated: _asBool(json['autoCreated']),
        deleted: _asBool(json['deleted']),
        currentBom: _asBool(json['currentBom']),
        bomIssue: _asBool(json['bomIssue']),
        productionHistory: _asBool(json['productionHistory']),
        subcontractHistory: _asBool(json['subcontractHistory']),
        searchRank: (json['searchRank'] as num?)?.toInt(),
        searchMatchKind: json['searchMatchKind'] as String?,
      );

  GoodsListItem toGoodsListItem() => GoodsListItem(
    id: id,
    code: code.isEmpty ? null : code,
    name: name.isEmpty ? null : name,
    spec: spec.isEmpty ? null : spec,
    model: model.isEmpty ? null : model,
    status: status.isEmpty ? null : status,
    sourceType: sourceType.isEmpty ? null : sourceType,
    autoCreated: autoCreated,
    categoryId: categoryId,
    searchRank: searchRank,
    searchMatchKind: searchMatchKind,
  );
}

String _asText(Object? value) => value?.toString().trim() ?? '';

bool _asBool(Object? value) {
  if (value is bool) return value;
  if (value is num) return value != 0;
  final text = _asText(value).toLowerCase();
  return text == 'true' || text == '1' || text == 'yes';
}
