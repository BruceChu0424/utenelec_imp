// 货架目视化清单页（仓库管理 hub → 库存查询分区）。
//
// 2026-09-10 信息架构重做：从「打印件的屏幕镜像」改成「现场找货的工具」——
// - 货架图（UtenRackGrid）：库行 × 层 × 位 网格，一格 = 一个库位号，同格多货
//   聚合成一格并显「+n」；点格 = 把表格定位到该库位（过滤 + 高亮）；
// - 统一表格（MasterDataTableView）：货架/层/位/库位号/货品编码/名称/颜色/
//   单位/即时库存/状态；列头筛选（货架/层/状态）、排序、隐藏列、导出全部复用；
//   点表格行 = 反查货架图（高亮该格并滚入视口）；
// - 筛选工具条（UtenFilterToolbar）：库行分段 + 搜索（名称/编码/系列/库位号）
//   + 行尾仓库筛选字段（UtenFilterPickerField，点开侧滑面板选；真过滤：
//     本仓偏好库位优先 + 本仓树库存汇总，主仓 = 自身 + 全部子仓聚合）
//   +「显示已禁用货品」开关 +「未分层」残值 chip + 共 N 项。
//
// 数据口径（GET /api/stock/shelf-labels，stock:view）：
// - 行 = 货品主档已维护库位号（goods.stock_place）的货品；库位号按「库行-层-位」
//   三段解析，不符合格式的老库残值 parsed=false 归「未分层」桶（治理脚本见
//   server/legacy_migration/clean_shelf_place_residue.sql）；
// - 即时库存是参考列：未选仓 = 全部核算仓汇总，选仓 = 该仓及子仓汇总；
// - 禁用货品默认不列（includeDisabled=true 才出现并标「已禁用」），软删货品不列，
//   库位号清空即自动下架。
//
// 预览打印：每个库行独立 A4 横版页，复刻挂牌版式（UTEN 头 + 库行徽章 + 斑马纹表），
// 末尾留白行供现场手写补充；PDF 走 pdf/printing（NotoSansSC 全量字体）。
// Excel 导出：/stock/reports/export report='shelf-labels'（stock_report:export，可加密）。
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import '../../../components/buttons/uten_back_button.dart';
import '../../../components/buttons/uten_button.dart';
import '../../../components/buttons/uten_export_button.dart';
import '../../../components/data_display/uten_rack_grid.dart';
import '../../../components/data_display/uten_status_badge.dart';
import '../../../components/inputs/uten_filter_picker_field.dart';
import '../../../components/inputs/uten_input.dart';
import '../../../components/layout/uten_app_bar.dart';
import '../../../components/layout/uten_content_container.dart';
import '../../../components/layout/uten_filter_toolbar.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/network/latest_request_guard.dart';
import '../../../core/print/pdf_printer.dart';
import '../../../core/router/nav_helpers.dart';
import '../../../core/router/route_names.dart';
import '../../../core/theme/uten_colors.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../core/ui/app_notification.dart';
import '../../../shared/auth/permissions.dart';
import '../../../shared/providers/master_name_provider.dart';
import '../../../shared/widgets/warehouse_picker_panel.dart';
import '../../basic_data/models/master_facet.dart';
import '../../basic_data/widgets/master_data_table_view.dart';
import '../../stock/repositories/stock_query_repository.dart';

/// 「未分层」在列头筛选/分组里的展示名（后端 rack 为空串）。
const String _kUnparsedLabel = '未分层'; // TODO(l10n): 补 arb

/// 库行分段里「全部」的哨兵值（分段值必须非空，null 会与「未选」混淆）。
const String _kAllRacks = '__all__';

class ShelfLabelPage extends ConsumerStatefulWidget {
  const ShelfLabelPage({super.key});

  @override
  ConsumerState<ShelfLabelPage> createState() => _ShelfLabelPageState();
}

class _ShelfLabelPageState extends ConsumerState<ShelfLabelPage> {
  List<String>? _racks;
  List<ShelfLayoutRack>? _layout;
  List<ShelfLabelRow>? _rows;
  bool _loading = false;
  String? _error;

  /// 库行分段选中值：null = 未选（= 全部），[_kAllRacks] = 显式「全部」。
  String? _rackSegment;
  String _keyword = '';

  /// 仓库：真过滤（本仓偏好库位优先 + 本仓树库存汇总），不再只是打印抬头。
  String? _warehouseId;
  bool _includeDisabled = false;

  /// 货架图 ↔ 表格 的双向定位键（库位号）。
  String? _selectedPlace;

  /// true = 定位来自点格（表格收敛到该库位）；false = 定位来自点行（只高亮）。
  bool _placeFilterActive = false;

  /// 列头筛选（客户端聚合：货架/层/状态）。
  final Map<String, String?> _filters = <String, String?>{};

  final _rowRequests = LatestRequestGuard();
  final _optionRequests = LatestRequestGuard();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      await ref.read(masterNameServiceProvider).ensureLoaded();
      await _loadOptions();
      await _load();
    });
  }

  /// 仓库筛选 = 侧滑面板查询口径（2026-09-11 全站统一，与即时库存同款）：
  /// 「全部」= 参与核算仓库聚合（_warehouseId=null）；选主仓 = 自身 + 全部子仓聚合。
  /// 换仓后库位定位态清空，库行/布局与主表三个查询一起重取。
  Future<void> _pickWarehouse() async {
    final result = await showUtenWarehousePickerPanel(
      context,
      hierarchy: ref.read(masterNameServiceProvider).warehouseHierarchy,
      initialWarehouseId: _warehouseId,
      title: '选择仓库', // TODO(l10n): 补 arb
      includeAll: true,
      allowParent: true,
    );
    if (!mounted || result == null) return;
    final next = result.isAll ? null : result.id;
    if (next == _warehouseId) return;
    setState(() {
      _warehouseId = next;
      _selectedPlace = null;
      _placeFilterActive = false;
    });
    _loadOptions();
    _load();
  }

  /// 库行下拉 + 货架图布局（随仓库/禁用口径变化重取；失败不阻塞主表）。
  Future<void> _loadOptions() async {
    final generation = _optionRequests.begin();
    try {
      final repo = ref.read(stockQueryRepositoryProvider);
      final racks = await repo.shelfLabelRacks(
        warehouseId: _warehouseId,
        includeDisabled: _includeDisabled,
      );
      final layout = await repo.shelfLabelLayout(
        warehouseId: _warehouseId,
        includeDisabled: _includeDisabled,
      );
      if (!mounted || !_optionRequests.isCurrent(generation)) return;
      setState(() {
        _racks = racks;
        _layout = layout;
      });
    } catch (_) {
      /* 库行/布局加载失败不阻塞主表：表格与搜索仍可用 */
    }
  }

  Future<void> _load() async {
    final generation = _rowRequests.begin();
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final rows = await ref
          .read(stockQueryRepositoryProvider)
          .shelfLabels(
            rack: _rackQuery,
            keyword: _keyword.trim().isEmpty ? null : _keyword.trim(),
            warehouseId: _warehouseId,
            includeDisabled: _includeDisabled,
          );
      if (!mounted || !_rowRequests.isCurrent(generation)) return;
      setState(() => _rows = rows);
    } on ApiException catch (e) {
      if (!mounted || !_rowRequests.isCurrent(generation)) return;
      setState(() => _error = e.message);
    } catch (_) {
      if (!mounted || !_rowRequests.isCurrent(generation)) return;
      setState(() => _error = '加载失败'); // TODO(l10n): 补 arb
    } finally {
      if (mounted && _rowRequests.isCurrent(generation)) {
        setState(() => _loading = false);
      }
    }
  }

  /// 服务端库行参数（「全部」/未选 = 不传）。
  String? get _rackQuery => (_rackSegment == null || _rackSegment == _kAllRacks)
      ? null
      : _rackSegment;

  /// 挂牌标题：默认取所选仓库名 +「物料库」（对标现场「五金仓库物料库」）。
  String get _headerTitle {
    final name = _warehouseId == null
        ? null
        : ref.read(masterNameServiceProvider).warehouseEntries[_warehouseId];
    if (name == null || name.isEmpty) return '仓库物料库'; // TODO(l10n): 补 arb
    return name.endsWith('物料库') ? name : '$name物料库';
  }

  // ---- 口径转换（展示值 = 筛选值 = 导出值，一处定义） --------------------

  static String _rackLabel(ShelfLabelRow r) =>
      r.rack.isEmpty ? _kUnparsedLabel : r.rack;

  static String _levelLabel(ShelfLabelRow r) =>
      r.level == null ? '' : '${r.level}';

  static String _statusLabel(ShelfLabelRow r) =>
      r.disabled ? '已禁用' : '启用'; // TODO(l10n): 补 arb

  /// 数字格式化：最多 2 位小数，去掉无意义的尾随 0（1.50→1.5；0→0）。
  static String _num(double v) {
    final s = v.toStringAsFixed(2);
    return s.contains('.')
        ? s.replaceAll(RegExp(r'0+$'), '').replaceAll(RegExp(r'\.$'), '')
        : s;
  }

  /// 列头筛选后的行（货架图与打印用这一份：不含「点格定位」的临时收敛）。
  List<ShelfLabelRow> get _filteredRows {
    final rows = _rows ?? const <ShelfLabelRow>[];
    if (_filters.values.every((v) => v == null || v.isEmpty)) return rows;
    final rack = _filters['rack'];
    final level = _filters['level'];
    final status = _filters['status'];
    return rows.where((r) {
      final rackOk = rack == null || rack.isEmpty || _rackLabel(r) == rack;
      final levelOk = level == null || level.isEmpty || _levelLabel(r) == level;
      final statusOk =
          status == null || status.isEmpty || _statusLabel(r) == status;
      return rackOk && levelOk && statusOk;
    }).toList();
  }

  /// 表格行 = 列头筛选 + （点格定位时）收敛到该库位。
  List<ShelfLabelRow> get _tableRows {
    final rows = _filteredRows;
    if (!_placeFilterActive || _selectedPlace == null) return rows;
    return rows.where((r) => r.place == _selectedPlace).toList();
  }

  /// 货架/层/状态三列的筛选桶：按列头筛选前的全量行聚合，空值不进桶。
  Map<String, List<MasterFacetBucket>> get _facets {
    final rows = _rows ?? const <ShelfLabelRow>[];
    List<MasterFacetBucket> bucketsOf(
      Iterable<String> texts, {
      bool numeric = false,
    }) {
      final counts = <String, int>{};
      for (final text in texts) {
        if (text.isEmpty) continue;
        counts[text] = (counts[text] ?? 0) + 1;
      }
      final entries = counts.entries.toList()
        ..sort(
          (a, b) => numeric
              ? (int.tryParse(a.key) ?? 0).compareTo(int.tryParse(b.key) ?? 0)
              : a.key.compareTo(b.key),
        );
      return [
        for (final entry in entries)
          MasterFacetBucket(value: entry.key, count: entry.value),
      ];
    }

    return {
      'rack': bucketsOf(rows.map(_rackLabel)),
      'level': bucketsOf(rows.map(_levelLabel), numeric: true),
      'status': bucketsOf(rows.map(_statusLabel)),
    };
  }

  /// 未分层（老库残值）行数：布局桶优先，缺布局时按行数兜底。
  int get _unparsedCount {
    final bucket = (_layout ?? const <ShelfLayoutRack>[])
        .where((r) => r.isUnparsedBucket)
        .firstOrNull;
    if (bucket != null) return bucket.count;
    return (_rows ?? const <ShelfLabelRow>[]).where((r) => !r.parsed).length;
  }

  /// 导出/打印查询参数（与 _load 同口径；列头筛选是客户端态，不下传）。
  Map<String, dynamic> get _exportQuery => <String, dynamic>{
    if (_rackQuery != null) 'rack': _rackQuery,
    if (_keyword.trim().isNotEmpty) 'keyword': _keyword.trim(),
    if (_warehouseId != null) 'warehouseId': _warehouseId,
    'includeDisabled': _includeDisabled,
  };

  // ---- 货架图 ↔ 表格 双向联动 --------------------------------------------

  /// 点格：定位到该库位（表格收敛 + 高亮）；再点一次取消定位。
  void _onCellTap(String place) {
    setState(() {
      if (_placeFilterActive && _selectedPlace == place) {
        _selectedPlace = null;
        _placeFilterActive = false;
      } else {
        _selectedPlace = place;
        _placeFilterActive = true;
      }
    });
  }

  /// 点表格行：反查货架图（只高亮并滚到该格，不收敛表格）。
  void _onRowSelected(ShelfLabelRow row) {
    final place = row.place;
    if (place == null || place.isEmpty) return;
    setState(() {
      _selectedPlace = place;
      _placeFilterActive = false;
    });
  }

  void _clearPlaceFilter() {
    setState(() {
      _selectedPlace = null;
      _placeFilterActive = false;
    });
  }

  List<MasterColumnDef<ShelfLabelRow>> _columns() {
    // 列头 ⓘ：库位号来源与仓维度口径必须让非专业用户看得懂。
    final placeInfo = StringBuffer(
      '库位号由入库登记自动学习，可在货品资料改正（格式：库行-层-位，如 A31-3-1）',
    );
    if (_warehouseId != null) {
      placeInfo.write('；本仓偏好优先——同一货品在不同仓可有不同库位');
    }
    final qtyInfo = _warehouseId == null
        ? '即时库存参考量：全部参与核算仓库汇总（货架摆放以库位号为准，与库存多少无关）'
        : '即时库存参考量：所选仓库及其子仓汇总（货架摆放以库位号为准，与库存多少无关）';
    return <MasterColumnDef<ShelfLabelRow>>[
      const MasterColumnDef(
        key: 'rack',
        label: '货架',
        width: 90,
        value: _rackLabel,
      ),
      MasterColumnDef(
        key: 'level',
        label: '层',
        width: 64,
        type: 'number',
        value: (r) => r.level == null ? '' : '${r.level}',
      ),
      MasterColumnDef(
        key: 'slot',
        label: '位',
        width: 64,
        type: 'number',
        value: (r) => r.slot == null ? '' : '${r.slot}',
      ),
      MasterColumnDef(
        key: 'place',
        label: '库位号',
        width: 120,
        info: placeInfo.toString(),
        value: (r) => r.place ?? '',
      ),
      MasterColumnDef(
        key: 'goodsCode',
        label: '货品编码',
        width: 130,
        value: (r) => r.goodsCode ?? '',
      ),
      MasterColumnDef(
        key: 'goodsName',
        label: '货品名称',
        width: 220,
        value: (r) => r.goodsName ?? '',
      ),
      MasterColumnDef(
        key: 'colorName',
        label: '颜色',
        width: 90,
        value: (r) => r.colorName ?? '',
      ),
      MasterColumnDef(
        key: 'unitName',
        label: '单位',
        width: 70,
        value: (r) => r.unitName ?? '',
      ),
      MasterColumnDef(
        key: 'qty',
        label: '即时库存',
        width: 110,
        type: 'number',
        info: qtyInfo,
        value: (r) => _num(r.qty),
      ),
      MasterColumnDef(
        key: 'status',
        label: '状态',
        width: 96,
        value: _statusLabel,
        cellBuilder: (context, r) => Align(
          alignment: Alignment.centerLeft,
          child: UtenStatusBadge(
            label: _statusLabel(r),
            type: r.disabled
                ? UtenStatusBadgeType.neutral
                : UtenStatusBadgeType.success,
            size: UtenStatusBadgeSize.small,
          ),
        ),
      ),
    ];
  }

  /// 货架图数据：列头筛选后的行（点格定位不影响图，否则点完只剩一格无法再挑）。
  List<UtenRackGridItem> _gridItems(List<ShelfLabelRow> rows) => [
    for (final r in rows)
      UtenRackGridItem(
        id: r.goodsId,
        place: r.place ?? '',
        level: r.level,
        slot: r.slot,
        code: r.goodsCode,
        name: r.goodsName,
        qtyLabel: r.qty == 0
            ? null
            : '${_num(r.qty)}${(r.unitName ?? '').isEmpty ? '' : r.unitName!}',
        disabled: r.disabled,
      ),
  ];

  List<UtenRackGridRack> get _gridRacks => [
    for (final rack in _layout ?? const <ShelfLayoutRack>[])
      UtenRackGridRack(
        rack: rack.rack,
        maxLevel: rack.maxLevel,
        maxSlot: rack.maxSlot,
        count: rack.count,
      ),
  ];

  /// 打印分组（按库行，未分层单独一组；用列头筛选后的行，与屏上所见一致）。
  List<MapEntry<String, List<ShelfLabelRow>>> get _printGroups {
    final map = <String, List<ShelfLabelRow>>{};
    for (final r in _filteredRows) {
      map.putIfAbsent(_rackLabel(r), () => []).add(r);
    }
    return map.entries.toList();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final names = ref.watch(masterNameServiceProvider);
    final filtered = _filteredRows;
    final unparsed = _unparsedCount;
    return Scaffold(
      appBar: UtenAppBar(
        title: '货架目视化清单', // TODO(l10n): 补 arb
        leading: UtenBackButton(
          onPressed: () => backTo(context, defaultPath: RouteName.warehouse),
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh_rounded),
            tooltip: '刷新', // TODO(l10n): 补 arb
            // 整页刷新：字典 + 库行/布局 + 清单（与 initState 同口径）。
            onPressed: () async {
              await ref.read(masterNameServiceProvider).ensureLoaded();
              await _loadOptions();
              await _load();
            },
          ),
        ],
      ),
      body: SafeArea(
        child: UtenContentContainer.wide(
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: UtenSpacing.s12),
            child: Column(
              children: [
                _toolbar(theme, names, filtered.length, unparsed),
                _gridPane(filtered),
                if (_placeFilterActive && _selectedPlace != null)
                  _locateBanner(theme),
                Expanded(
                  child: MasterDataTableView<ShelfLabelRow>(
                    columns: _columns(),
                    items: _tableRows,
                    facets: _facets,
                    nullCounts: const {},
                    filters: _filters,
                    onFilterChanged: (key, value) => setState(() {
                      if (value == null || value.isEmpty) {
                        _filters.remove(key);
                      } else {
                        _filters[key] = value;
                      }
                    }),
                    isSelected: (r) =>
                        _selectedPlace != null && r.place == _selectedPlace,
                    onSelectionChanged: _onRowSelected,
                    toolbarActions: [
                      UtenButton(
                        size: UtenButtonSize.large,
                        icon: Icons.print_outlined,
                        onPressed: (filtered.isEmpty || _loading)
                            ? null
                            : () => _showPrintPreview(context),
                        child: const Text('预览打印'), // TODO(l10n): 补 arb
                      ),
                      UtenExportButton(
                        endpoint: '/stock/reports/export',
                        requiredPermission: Perm.stockReportExport,
                        report: 'shelf-labels',
                        queryParams: _exportQuery,
                        filename: '货架目视化清单',
                        type: UtenButtonType.primary,
                        size: UtenButtonSize.large,
                      ),
                    ],
                    isLoading: _loading && _rows == null,
                    loadingMore: _loading && _rows != null,
                    error: _error,
                    onRetry: _load,
                    emptyMessage:
                        '暂无已维护库位号的货品\n请先在货品资料中填写「库位号」(如 A31-3-1)', // TODO(l10n): 补 arb
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _toolbar(
    ThemeData theme,
    MasterNameService names,
    int total,
    int unparsed,
  ) {
    return Padding(
      padding: const EdgeInsets.only(
        left: UtenSpacing.s4,
        right: UtenSpacing.s4,
        bottom: UtenSpacing.s8,
      ),
      child: UtenFilterToolbar<String>(
        segmentsKey: const Key('shelf-label-rack-segments'),
        searchKey: const Key('shelf-label-search'),
        segments: [
          const UtenFilterSegment(value: _kAllRacks, label: '全部'), // TODO(l10n)
          for (final rack in _racks ?? const <String>[])
            UtenFilterSegment(value: rack, label: '$rack 库行'),
        ],
        selected: _rackSegment == null ? const <String>{} : {_rackSegment!},
        onSelectionChanged: (value) {
          setState(() {
            _rackSegment = value;
            _selectedPlace = null;
            _placeFilterActive = false;
          });
          _load();
        },
        searchHint: '搜索货品名称 / 编号 / 系列 / 库位号', // TODO(l10n): 补 arb
        onSearchChanged: (value) {
          setState(() => _keyword = value.trim());
          _load();
        },
        trailing: Wrap(
          spacing: UtenSpacing.s12,
          runSpacing: UtenSpacing.s8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            // 仓库筛选：与即时库存同款——点开侧滑面板选（2026-09-11 全站统一）。
            UtenFilterPickerField(
              key: const Key('shelf-label-warehouse'),
              label: '仓库', // TODO(l10n): 补 arb
              icon: Icons.warehouse_outlined,
              width: 220,
              value: _warehouseId == null
                  ? null
                  : names.warehouseEntries[_warehouseId],
              onTap: _pickWarehouse,
            ),
            FilterChip(
              key: const Key('shelf-label-include-disabled'),
              label: const Text('显示已禁用货品'), // TODO(l10n): 补 arb
              selected: _includeDisabled,
              onSelected: (v) {
                setState(() => _includeDisabled = v);
                _loadOptions();
                _load();
              },
            ),
            if (unparsed > 0)
              FilterChip(
                key: const Key('shelf-label-unparsed-chip'),
                avatar: const Icon(Icons.help_outline_rounded, size: 16),
                label: Text('$_kUnparsedLabel $unparsed'), // TODO(l10n): 补 arb
                selected: _filters['rack'] == _kUnparsedLabel,
                onSelected: (v) => setState(() {
                  if (v) {
                    _filters['rack'] = _kUnparsedLabel;
                  } else {
                    _filters.remove('rack');
                  }
                }),
              ),
            Text(
              '共 $total 项', // TODO(l10n): 补 arb
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 货架图区：限高 + 竖向滚动（表格反查时 ensureVisible 在这里生效）。
  Widget _gridPane(List<ShelfLabelRow> rows) {
    return ConstrainedBox(
      constraints: const BoxConstraints(maxHeight: 320),
      child: SingleChildScrollView(
        padding: const EdgeInsets.only(
          left: UtenSpacing.s4,
          right: UtenSpacing.s4,
          bottom: UtenSpacing.s4,
        ),
        child: UtenRackGrid(
          key: const Key('shelf-label-rack-grid'),
          racks: _gridRacks,
          items: _gridItems(rows),
          selectedPlace: _selectedPlace,
          onCellTap: _onCellTap,
        ),
      ),
    );
  }

  /// 点格定位提示条：明确「表格已收敛到这一格」，一键取消。
  Widget _locateBanner(ThemeData theme) {
    return Padding(
      padding: const EdgeInsets.only(
        left: UtenSpacing.s4,
        right: UtenSpacing.s4,
        bottom: UtenSpacing.s8,
      ),
      child: Align(
        alignment: Alignment.centerLeft,
        child: InputChip(
          key: const Key('shelf-label-locate-chip'),
          avatar: const Icon(Icons.my_location_rounded, size: 16),
          label: Text('已定位库位 $_selectedPlace'), // TODO(l10n): 补 arb
          onDeleted: _clearPlaceFilter,
          deleteIconColor: theme.colorScheme.onSurfaceVariant,
        ),
      ),
    );
  }

  // ---- 预览打印（复刻挂牌版式：每库行独立 A4 横版页，末尾留白行供手写） ----

  void _showPrintPreview(BuildContext context) {
    showDialog<void>(
      context: context,
      builder: (_) => _ShelfLabelPrintDialog(
        defaultTitle: _headerTitle,
        groups: _printGroups,
        exportQuery: _exportQuery,
      ),
    );
  }
}

/// 挂牌打印预览对话框：灰底 + 白纸分页预览，打印生成同版式 PDF。
/// 抬头标题在本弹窗内可改（默认取所选仓库名 +「物料库」）。
class _ShelfLabelPrintDialog extends StatefulWidget {
  const _ShelfLabelPrintDialog({
    required this.defaultTitle,
    required this.groups,
    required this.exportQuery,
  });

  final String defaultTitle;
  final List<MapEntry<String, List<ShelfLabelRow>>> groups;
  final Map<String, dynamic> exportQuery;

  @override
  State<_ShelfLabelPrintDialog> createState() => _ShelfLabelPrintDialogState();
}

class _ShelfLabelPrintDialogState extends State<_ShelfLabelPrintDialog> {
  static const _teal = PdfColor.fromInt(0xFF1B7F8E);
  static const _tealLight = PdfColor.fromInt(0xFFF2F8FA);
  static const _rowsPerPage = 16; // 每页数据行（不含末尾留白）
  static const _blankRows = 6; // 每库行末尾留白行（现场手写补充位）

  late final TextEditingController _title = TextEditingController(
    text: widget.defaultTitle,
  );

  @override
  void dispose() {
    _title.dispose();
    super.dispose();
  }

  String get _effectiveTitle {
    final t = _title.text.trim();
    return t.isEmpty ? widget.defaultTitle : t;
  }

  Future<void> _print() async {
    final title = _effectiveTitle;
    try {
      final fontData = await rootBundle.load('assets/fonts/NotoSansSCFull.ttf');
      final font = pw.Font.ttf(fontData);
      final doc = pw.Document();
      for (final g in widget.groups) {
        final rows = g.value;
        for (var i = 0; i < rows.length || i == 0; i += _rowsPerPage) {
          final chunk = i < rows.length
              ? rows.sublist(
                  i,
                  i + _rowsPerPage > rows.length
                      ? rows.length
                      : i + _rowsPerPage,
                )
              : const <ShelfLabelRow>[];
          final isLastChunk = i + _rowsPerPage >= rows.length;
          doc.addPage(
            pw.Page(
              pageFormat: PdfPageFormat.a4.landscape,
              margin: const pw.EdgeInsets.all(24),
              build: (_) => _pdfLabelPage(
                font,
                title,
                g.key,
                chunk,
                padBlanks: isLastChunk ? _blankRows : 0,
              ),
            ),
          );
          if (rows.isEmpty) break;
        }
      }
      await printPdfBytes(await doc.save(), '$title-货架目视化清单.pdf');
    } catch (_) {
      if (!mounted) return;
      context.appError('生成打印件失败，请稍后重试'); // TODO(l10n): 补 arb
    }
  }

  /// PDF 单页：UTEN 头（左 logo 文案 / 中标题 / 右库行徽章）+ 五列斑马表 + 留白行。
  pw.Widget _pdfLabelPage(
    pw.Font font,
    String title,
    String rack,
    List<ShelfLabelRow> rows, {
    int padBlanks = 0,
  }) {
    pw.Widget hCell(String t) => pw.Padding(
      padding: const pw.EdgeInsets.symmetric(horizontal: 4, vertical: 5),
      child: pw.Text(
        t,
        textAlign: pw.TextAlign.center,
        style: pw.TextStyle(
          font: font,
          fontSize: 10,
          fontWeight: pw.FontWeight.bold,
          color: PdfColors.white,
        ),
      ),
    );
    pw.Widget dCell(String? t, {bool start = false}) => pw.Padding(
      padding: const pw.EdgeInsets.symmetric(horizontal: 4, vertical: 4),
      child: pw.Text(
        t ?? '',
        textAlign: start ? pw.TextAlign.left : pw.TextAlign.center,
        style: pw.TextStyle(font: font, fontSize: 9),
      ),
    );
    return pw.Column(
      crossAxisAlignment: pw.CrossAxisAlignment.stretch,
      children: [
        pw.Container(
          color: _teal,
          padding: const pw.EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: pw.Row(
            children: [
              pw.Column(
                crossAxisAlignment: pw.CrossAxisAlignment.start,
                children: [
                  pw.Text(
                    'UTEN优腾',
                    style: pw.TextStyle(
                      font: font,
                      fontSize: 16,
                      fontWeight: pw.FontWeight.bold,
                      color: PdfColors.white,
                    ),
                  ),
                  pw.Text(
                    '德国工匠 · 质造开关',
                    style: pw.TextStyle(
                      font: font,
                      fontSize: 7,
                      color: PdfColors.white,
                    ),
                  ),
                ],
              ),
              pw.Expanded(
                child: pw.Column(
                  children: [
                    pw.Text(
                      title,
                      textAlign: pw.TextAlign.center,
                      style: pw.TextStyle(
                        font: font,
                        fontSize: 14,
                        fontWeight: pw.FontWeight.bold,
                        color: PdfColors.white,
                      ),
                    ),
                    pw.Text(
                      '目视化管理清单 Visual Management List',
                      textAlign: pw.TextAlign.center,
                      style: pw.TextStyle(
                        font: font,
                        fontSize: 10,
                        color: PdfColors.white,
                      ),
                    ),
                  ],
                ),
              ),
              pw.Container(
                padding: const pw.EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 4,
                ),
                decoration: pw.BoxDecoration(
                  color: PdfColors.white,
                  borderRadius: pw.BorderRadius.circular(3),
                ),
                child: pw.Text(
                  rack == _kUnparsedLabel ? rack : '$rack库行',
                  style: pw.TextStyle(
                    font: font,
                    fontSize: 14,
                    fontWeight: pw.FontWeight.bold,
                  ),
                ),
              ),
            ],
          ),
        ),
        pw.SizedBox(height: 6),
        pw.Table(
          border: pw.TableBorder.all(width: 0.5),
          columnWidths: const {
            0: pw.FlexColumnWidth(1.1),
            1: pw.FlexColumnWidth(1.4),
            2: pw.FlexColumnWidth(),
            3: pw.FlexColumnWidth(2.6),
            4: pw.FlexColumnWidth(0.9),
          },
          children: [
            pw.TableRow(
              decoration: const pw.BoxDecoration(color: _teal),
              children: [
                for (final h in ['库位号', '物料编码', '物料系列', '物料名称', '颜色']) hCell(h),
              ],
            ),
            for (var i = 0; i < rows.length; i++)
              pw.TableRow(
                decoration: pw.BoxDecoration(
                  color: i.isOdd ? _tealLight : PdfColors.white,
                ),
                children: [
                  dCell(rows[i].place),
                  dCell(rows[i].goodsCode),
                  dCell(rows[i].series),
                  dCell(rows[i].goodsName, start: true),
                  dCell(rows[i].colorName),
                ],
              ),
            for (var i = 0; i < padBlanks; i++)
              pw.TableRow(
                children: [
                  dCell(' '),
                  dCell(''),
                  dCell(''),
                  dCell(''),
                  dCell(''),
                ],
              ),
          ],
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Dialog(
      shape: const RoundedRectangleBorder(borderRadius: UtenRadius.xxlAll),
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: 1080,
          maxHeight: MediaQuery.sizeOf(context).height * 0.92,
        ),
        child: SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(
                  UtenSpacing.s16,
                  UtenSpacing.s12,
                  UtenSpacing.s8,
                  UtenSpacing.s12,
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: UtenInput(
                        label: '抬头标题', // TODO(l10n): 补 arb
                        hint: '如：五金仓库物料库', // TODO(l10n): 补 arb
                        controller: _title,
                        onChanged: (_) => setState(() {}),
                      ),
                    ),
                    const SizedBox(width: UtenSpacing.s12),
                    UtenButton(
                      type: UtenButtonType.tonal,
                      size: UtenButtonSize.small,
                      icon: Icons.print_outlined,
                      onPressed: widget.groups.isEmpty ? null : _print,
                      child: const Text('打印'), // TODO(l10n): 补 arb
                    ),
                    const SizedBox(width: UtenSpacing.s8),
                    UtenExportButton(
                      endpoint: '/stock/reports/export',
                      report: 'shelf-labels',
                      queryParams: widget.exportQuery,
                      filename: '货架目视化清单',
                      requiredPermission: Perm.stockReportExport,
                      label: '下载Excel', // TODO(l10n): 补 arb
                    ),
                    const SizedBox(width: UtenSpacing.s8),
                    UtenButton(
                      type: UtenButtonType.tonal,
                      icon: Icons.close_rounded,
                      onPressed: () => Navigator.of(context).pop(),
                      child: const Text('关闭'), // TODO(l10n): 补 arb
                    ),
                  ],
                ),
              ),
              const Divider(height: 1),
              Expanded(
                child: Container(
                  color: theme.colorScheme.surfaceContainerHighest,
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.all(UtenSpacing.s16),
                    child: Center(
                      child: Column(
                        children: [
                          for (final g in widget.groups) ...[
                            _paperLabel(theme, g.key, g.value),
                            const SizedBox(height: UtenSpacing.s16),
                          ],
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// 屏上纸面预览（与 PDF 同款版式；一个库行一张纸）。
  /// 这里刻意用 UtenColors 固定色而非 colorScheme：预览的是「打印出来的纸」，
  /// 纸永远是白的、抬头永远是品牌青绿，不随明暗主题变。
  Widget _paperLabel(ThemeData theme, String rack, List<ShelfLabelRow> rows) {
    return Container(
      width: 1000,
      decoration: BoxDecoration(
        color: UtenColors.surface,
        border: Border.all(color: UtenColors.border),
        boxShadow: UtenElevation.high(),
      ),
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            color: UtenColors.teal700,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            child: Row(
              children: [
                const Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'UTEN优腾',
                      style: TextStyle(
                        color: UtenColors.surface,
                        fontSize: 18,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    Text(
                      '德国工匠 · 质造开关',
                      style: TextStyle(color: UtenColors.surface, fontSize: 8),
                    ),
                  ],
                ),
                Expanded(
                  child: Column(
                    children: [
                      Text(
                        _effectiveTitle,
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                          color: UtenColors.surface,
                          fontSize: 15,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const Text(
                        '目视化管理清单 Visual Management List',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          color: UtenColors.surface,
                          fontSize: 10,
                        ),
                      ),
                    ],
                  ),
                ),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 4,
                  ),
                  decoration: const BoxDecoration(
                    color: UtenColors.surface,
                    borderRadius: UtenRadius.xsAll,
                  ),
                  child: Text(
                    rack == _kUnparsedLabel ? rack : '$rack库行',
                    style: const TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w700,
                      color: UtenColors.textPrimary,
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 6),
          Table(
            columnWidths: const {
              0: FlexColumnWidth(1.1),
              1: FlexColumnWidth(1.4),
              2: FlexColumnWidth(),
              3: FlexColumnWidth(2.6),
              4: FlexColumnWidth(0.9),
            },
            border: TableBorder.all(color: UtenColors.slate400, width: 0.5),
            children: [
              TableRow(
                decoration: const BoxDecoration(color: UtenColors.teal700),
                children: [
                  for (final h in ['库位号', '物料编码', '物料系列', '物料名称', '颜色'])
                    Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 4,
                        vertical: 5,
                      ),
                      child: Text(
                        h,
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                          color: UtenColors.surface,
                          fontSize: 11,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                ],
              ),
              for (var i = 0; i < rows.length; i++)
                TableRow(
                  decoration: BoxDecoration(
                    color: i.isOdd ? UtenColors.teal50 : UtenColors.surface,
                  ),
                  children: [
                    _paperCell(rows[i].place),
                    _paperCell(rows[i].goodsCode),
                    _paperCell(rows[i].series),
                    _paperCell(rows[i].goodsName, start: true),
                    _paperCell(rows[i].colorName),
                  ],
                ),
              for (var i = 0; i < 6; i++)
                const TableRow(
                  children: [
                    _BlankCell(),
                    _BlankCell(),
                    _BlankCell(),
                    _BlankCell(),
                    _BlankCell(),
                  ],
                ),
            ],
          ),
          const SizedBox(height: 6),
          Align(
            alignment: Alignment.centerRight,
            child: Text(
              '共 ${rows.length} 项 · 打印时每个库行自动分页', // TODO(l10n): 补 arb
              style: theme.textTheme.labelSmall?.copyWith(
                color: UtenColors.textSecondary,
              ),
            ),
          ),
        ],
      ),
    );
  }

  static Widget _paperCell(String? text, {bool start = false}) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
    child: Text(
      text ?? '',
      textAlign: start ? TextAlign.start : TextAlign.center,
      style: const TextStyle(fontSize: 10, color: UtenColors.textPrimary),
    ),
  );
}

class _BlankCell extends StatelessWidget {
  const _BlankCell();

  @override
  Widget build(BuildContext context) =>
      const Padding(padding: EdgeInsets.all(12), child: Text(' '));
}
