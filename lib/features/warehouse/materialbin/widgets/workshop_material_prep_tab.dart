// 车间内料仓设置 · 上线准备 (ADR-131 §5.1 第 2 条)。
//
// 列出近 12 个月在该车间做过或归属该车间的产品: 产品 | 老库材质 | 颗粒 | 单个重量 (克) |
// 参考: 货品资料单重 (克) | 状态。顶部进度"常做的 N 个产品, 已选料 X 个, 已填单重 Y 个"。
// - "勾选行用货品资料单重填入": 只填勾选行里单重空着的, 填完标黄待核对。
// - 勾选多行后改任一勾选行的颗粒或单重 = 对全部勾选行生效 (表头筛掉的行不算)。
// - 单个重量填件重 (不含水口); 小于 0.1 克或大于 5000 克保存前二次确认; 与货品资料单重
//   差 20% 以上标黄。服务端还要人确认的 (同一产品第二种料等) 回 422, 问完带上确认重发。
// - 一次保存 = 批量写 BOM 塑料单个重量; 只选了料、没填单重的写成认料 (记在本车间名下)。
// - 双料件一种料一行; 一个产品改了任一行, 这个产品的全部行一起提交 (只选料时服务端按
//   整个产品重写认料, 漏交一行就等于把那种料去掉了)。
// - 可选的料随上线准备清单一起下发 (本车间内料仓收的整批领料主料)。
import '../../../../components/layout/uten_floating_action_group.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../../../../components/buttons/uten_button.dart';
import '../../../../components/data_display/uten_status_badge.dart';
import '../../../../components/data_display/uten_status_cell_color.dart';
import '../../../../components/feedback/uten_busy_overlay.dart';
import '../../../../components/feedback/uten_dialog.dart';
import '../../../../components/inputs/required_field_decoration.dart';
import '../../../../components/inputs/uten_dropdown_field.dart';
import '../../../../components/inputs/uten_field_hint_icon.dart';
import '../../../../components/layout/uten_editable_grid.dart';
import '../../../../core/l10n/gen/app_localizations.dart';
import '../../../../core/network/api_exception.dart';
import '../../../../core/theme/uten_colors.dart';
import '../../../../core/theme/uten_tokens.dart';
import '../../../../core/ui/app_notification.dart';
import '../../../../shared/auth/native_read_view_scope_mixin.dart'
    show nativeReadAccessDenied;
import '../../../basic_data/widgets/periodic_bom_confirmation.dart';
import '../models/workshop_material_models.dart';
import '../repositories/workshop_material_repository.dart';
import 'workshop_material_labels.dart';
import 'workshop_material_summary_table.dart';
import '../../../../shared/paging/versioned_summary_read.dart';
import '../../../../shared/paging/read_view_activity.dart';
import '../../../../shared/auth/read_owner_fence.dart';

class WmPrepRow extends EditableGridRow {
  WmPrepRow(this.source, {String? id})
    : id = id ?? source.productGoodsId,
      originalMaterialKey = source.materialGoodsId == null
          ? null
          : wmMaterialKey(source.materialGoodsId!, source.materialColorId),
      grams = TextEditingController(
        text: source.unitWeightGrams == null
            ? ''
            : wmQty(source.unitWeightGrams, maxDecimals: 3),
      ) {
    material.value = originalMaterialKey;
  }

  final WmPreparationRow source;

  /// 行的稳定标识 (控件键用): 产品第一行就是产品 id, 双料件第二行起加「#序号」。
  final String id;
  final String? originalMaterialKey;
  final ValueNotifier<String?> material = ValueNotifier<String?>(null);
  final TextEditingController grams;

  /// 由货品资料单重一键填入、还没人核对过 (标黄)。
  final ValueNotifier<bool> autofilled = ValueNotifier<bool>(false);

  double? get gramsValue => wmParseQty(grams.text);

  /// 与货品资料单重差 20% 以上。
  bool get deviates {
    final g = gramsValue;
    final reference = source.goodsWeightGrams;
    if (g == null || reference == null || reference <= 0) return false;
    return (g - reference).abs() / reference > 0.2;
  }

  /// 小于 0.1 克或大于 5000 克, 保存前要二次确认。
  bool get unusual {
    final g = gramsValue;
    return g != null && (g < 0.1 || g > 5000);
  }

  bool get dirty =>
      material.value != originalMaterialKey ||
      gramsValue != source.unitWeightGrams;

  /// 颗粒还是老库材质文字预填的那一种, 没人改过 (保存时告诉服务端预填来源)。
  bool get keepsLegacyPrefill =>
      source.prefilledFromLegacy && material.value == originalMaterialKey;

  /// 2026-09-29 用户口径：名称只显示名称，规格（86X86 等）不再拼接显示。
  String get productDisplay => source.productName ?? source.productCode ?? '';

  @override
  void dispose() {
    material.dispose();
    grams.dispose();
    autofilled.dispose();
    super.dispose();
  }
}

String wmPrepStatusLabel(String? status) => switch (status) {
  'WEIGHED' => '已填单重',
  'CHOSEN' => '已选料, 待填单重',
  'NOT_FROM_STORE' => '不用内料仓的料',
  _ => '待准备',
};

/// 给清单行编稳定标识: 产品第一行用产品 id, 双料件后面的行加「#序号」。
List<WmPrepRow> wmPrepRowsOf(List<WmPreparationRow> rows) {
  final seen = <String, int>{};
  return [
    for (final r in rows)
      () {
        final n = seen[r.productGoodsId] = (seen[r.productGoodsId] ?? 0) + 1;
        return WmPrepRow(
          r,
          id: n == 1 ? r.productGoodsId : '${r.productGoodsId}#$n',
        );
      }(),
  ];
}

class WmPrepTab extends ConsumerStatefulWidget {
  const WmPrepTab({super.key, required this.workshopId});

  final String workshopId;

  @override
  ConsumerState<WmPrepTab> createState() => _WmPrepTabState();
}

class _WmPrepTabState extends ConsumerState<WmPrepTab>
    with ReadViewActivityMixin<WmPrepTab> {
  final _grid = UtenEditableGridController<WmPrepRow>();
  bool _readDenied = false;
  final _nonce = const Uuid().v4();
  WmPreparation? _prep;
  Set<WmPrepRow> _hidden = const {};
  bool _loading = true;
  // 服务端按「常做程度」截断行数(进度三数是独立聚合)；为真时在进度下提示截断。
  VersionedSummarySnapshot<Map<String, dynamic>>? _summary;
  final Map<String, List<WmMaterialOption>> _productMaterials = {};
  bool _opening = false;
  VersionedSummarySnapshot<WmMaterialOption>? _catalog;
  Object? _catalogSummary;
  String? _editorCatalogVersion;
  bool _hasSubmittedWorkset = false;
  int _readGeneration = 0;
  bool Function()? _editorOwner;
  String? _editorWorkshop;
  String? _editorDataVersion;
  String? _editorScopeVersion;

  bool get _worksetOwnerCurrent =>
      _editorOwner?.call() != false &&
      (_editorWorkshop == null || _editorWorkshop == widget.workshopId);
  bool get _worksetCurrent =>
      _worksetOwnerCurrent &&
      (_catalog == null ||
          _editorCatalogVersion == null ||
          _editorCatalogVersion ==
              (_catalog!.dataVersion ?? _catalog!.revision)) &&
      (_editorDataVersion == null ||
          (_summary != null &&
              _editorDataVersion ==
                  (_summary!.dataVersion ?? _summary!.revision) &&
              _editorScopeVersion == _summary!.readScopeVersion));

  @override
  Future<void> onReadViewResumed() => _load();

  Future<void> _closeWorkset() async {
    if (_busyTitle != null || _opening || _hasSubmittedWorkset) return;
    if (_grid.rows.any((row) => row.dirty)) {
      final confirmed = await UtenDialog.show(
        context,
        title: '重新选择编辑产品',
        content: const Text('当前编辑明细含未保存输入。确定清除这些输入并重新选择产品？'),
        confirmLabel: '清除并重新选择',
      );
      if (!mounted || confirmed != true) return;
    }
    setState(() {
      _grid.replaceAll(const []);
      _productMaterials.clear();
      _editorOwner = null;
      _editorWorkshop = null;
      _editorDataVersion = null;
      _editorScopeVersion = null;
      _editorCatalogVersion = null;
    });
  }

  String? _error;
  String? _busyTitle;

  WorkshopMaterialRepository get _repo =>
      ref.read(workshopMaterialRepositoryProvider);

  @override
  void initState() {
    super.initState();
    listenReadOwner(ref, () {
      _readGeneration++;
      setState(() {
        _summary = null;
        _prep = null;
        _readDenied = true;
        _loading = false;
        _opening = false;
        _error = '读取身份已变化，请重新读取';
      });
    });
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  @override
  void dispose() {
    _grid.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final owner = captureReadOwner(ref);
    final request = ++_readGeneration;
    final workshop = widget.workshopId;
    bool current() =>
        mounted &&
        owner() &&
        request == _readGeneration &&
        widget.workshopId == workshop;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final summary = await readViewActivity.runRead(
        current,
        () => _repo.preparationSummaries(workshop, isCurrent: current),
      );
      if (!mounted || !current()) return;
      setState(() {
        _summary = summary;
        _catalog = null;
        _catalogSummary = null;
        _readDenied = false;
        _prep = WmPreparation(
          rows: const [],
          total: summary.items.length,
          chosen: summary.items
              .where((r) => const ['CHOSEN', 'WEIGHED'].contains(r['status']))
              .length,
          weighed: summary.items.where((r) => r['status'] == 'WEIGHED').length,
        );
      });
    } catch (error) {
      if (!mounted || !current()) return;
      setState(() {
        if (!isRetiredViewRead(error)) {
          _readDenied = _readDenied || nativeReadAccessDenied(error);
          _error = error is ApiException ? error.message : '加载上线准备清单失败，请重试';
          if (_readDenied) {
            _summary = null;
            _prep = null;
          }
        }
      });
    } finally {
      if (mounted && request == _readGeneration) {
        setState(() => _loading = false);
      }
    }
  }

  Future<void> _openProduct(Map<String, dynamic> row) async {
    final summary = _summary;
    if (summary == null || _opening || _busyTitle != null || _readDenied) {
      return;
    }
    if (!_worksetCurrent) {
      context.appWarning('读取身份已变化，请重新打开上线准备后编辑；原输入尚未改写');
      return;
    }
    final productId = row['productGoodsId'] as String;
    if (_grid.rows.any((r) => r.source.productGoodsId == productId)) return;
    final owner = captureReadOwner(ref);
    final workshop = widget.workshopId;
    final request = _readGeneration;
    bool current() =>
        mounted &&
        owner() &&
        request == _readGeneration &&
        identical(_summary, summary) &&
        widget.workshopId == workshop;
    setState(() => _opening = true);
    try {
      final result = await readViewActivity.runRead(current, () async {
        final rows = await _repo.preparationProduct(
          workshop,
          productId,
          summary: summary,
          isCurrent: current,
        );
        final options = identical(_catalogSummary, summary) && _catalog != null
            ? _catalog!
            : await _repo.preparationMaterialCatalog(
                workshop,
                isCurrent: current,
              );
        return (rows, options);
      }, slot: 'product');
      if (!mounted || !current()) return;
      if (_grid.length + result.$1.length > 500) {
        context.appWarning('一次最多编辑500行；请先保存当前修改后再打开其他产品');
        return;
      }
      final catalogVersion = result.$2.dataVersion ?? result.$2.revision;
      setState(() {
        _catalog = result.$2;
        _catalogSummary = summary;
      });
      if (_editorCatalogVersion != null &&
          _editorCatalogVersion != catalogVersion) {
        context.appWarning('颗粒目录已变化，原输入保留，请重新核对编辑产品');
        return;
      }
      _editorCatalogVersion ??= catalogVersion;
      _editorOwner ??= owner;
      _editorWorkshop ??= workshop;
      _editorDataVersion ??= summary.dataVersion ?? summary.revision;
      _editorScopeVersion ??= summary.readScopeVersion;
      setState(() {
        _productMaterials[productId] = result.$2.items;
        // Existing live row/controller objects are retained across opens.
        _grid.addRows(wmPrepRowsOf(result.$1));
      });
    } catch (error) {
      if (mounted && current() && !isRetiredViewRead(error)) {
        context.appWarning(
          error is ApiException ? error.message : '读取产品明细失败，请重试',
        );
      }
    } finally {
      if (mounted && request == _readGeneration) {
        setState(() => _opening = false);
      }
    }
  }

  /// 本行已勾选且还有别的勾选行 → 全部勾选且看得见的行; 否则只有本行。
  List<WmPrepRow> _targets(WmPrepRow row) {
    final selected = _grid.selectedRows
        .where((r) => !_hidden.contains(r))
        .toList();
    if (!_grid.isSelected(row) || selected.length < 2) return [row];
    return selected;
  }

  void _fillFromGoodsWeight() {
    var filled = 0;
    for (final row in _grid.selectedRows) {
      if (_hidden.contains(row)) continue;
      if (row.grams.text.trim().isNotEmpty) continue;
      final reference = row.source.goodsWeightGrams;
      if (reference == null || reference <= 0) continue;
      row.grams.text = wmQty(reference, maxDecimals: 3);
      row.autofilled.value = true;
      filled++;
    }
    context.appInfo(
      filled == 0 ? '勾选行里没有单重空着且货品资料有单重的产品' : '已填入 $filled 个产品的单个重量, 标黄的请逐个核对',
    );
  }

  Map<String, WmMaterialOption> _materialByKey(WmPrepRow row) => {
    for (final m
        in _productMaterials[row.source.productGoodsId] ??
            const <WmMaterialOption>[])
      m.key: m,
  };

  List<UtenDropdownItem> _materialItems(WmPrepRow row) {
    final items = [
      for (final m
          in _productMaterials[row.source.productGoodsId] ??
              const <WmMaterialOption>[])
        UtenDropdownItem(value: m.key, label: m.displayName),
    ];
    final original = row.originalMaterialKey;
    if (original != null && !_materialByKey(row).containsKey(original)) {
      items.insert(
        0,
        UtenDropdownItem(
          value: original,
          label: row.source.materialName ?? '原来选的料',
          enabled: false,
          visible: false,
        ),
      );
    }
    return items;
  }

  List<EditableGridColumn<WmPrepRow>> _columns(
    AppLocalizations l10n,
    ThemeData theme,
  ) => [
    EditableGridColumn<WmPrepRow>(
      key: 'status',
      label: '状态',
      width: 80,
      textOf: (r) => wmPrepStatusLabel(r.source.status),
      filterValueOf: (r) => wmPrepStatusLabel(r.source.status),
      // 2026-09-27 用户口径「表格状态列整格底色」；档位按 ADR-169 重定：
      // 已填单重=绿（完成）/ 已选料待填单重=紫（部分就绪——料已选、单重未填，
      // 等操作人自己动手而非等外部，琥珀留给「等别人」，2026-10-08 口径）/
      // 待准备=中性灰；不用内料仓的行不铺色。
      cellColor: (context, r) => switch (r.source.status) {
        'WEIGHED' => utenStatusBadgeCellColor(UtenStatusBadgeType.success),
        'CHOSEN' => utenStatusBadgeCellColor(UtenStatusBadgeType.violet),
        'NOT_FROM_STORE' => null,
        _ => utenStatusBadgeCellColor(UtenStatusBadgeType.neutral),
      },
      cellBuilder: (_, r) => Text(wmPrepStatusLabel(r.source.status)),
    ),
    EditableGridColumn<WmPrepRow>(
      key: 'productCode',
      label: '产品编号',
      width: 120,
      textOf: (r) => r.source.productCode ?? '',
      cellBuilder: (_, r) => Text(r.source.productCode ?? ''),
    ),
    EditableGridColumn<WmPrepRow>(
      key: 'product',
      label: '产品',
      width: 180,
      textOf: (r) => r.productDisplay,
      cellBuilder: (_, r) => Text(r.productDisplay),
    ),
    EditableGridColumn<WmPrepRow>(
      key: 'legacy',
      label: '老库材质',
      width: 140,
      textOf: (r) => r.source.legacyMaterial ?? '',
      filterValueOf: (r) => r.source.legacyMaterial,
      cellBuilder: (_, r) => Text(r.source.legacyMaterial ?? ''),
    ),
    EditableGridColumn<WmPrepRow>(
      key: 'material',
      label: '颗粒',
      width: 200,
      textOf: (r) =>
          _materialByKey(r)[r.material.value]?.displayName ??
          r.source.materialName ??
          '',
      listenableOf: (r) => r.material,
      filterValueOf: (r) =>
          _materialByKey(r)[r.material.value]?.displayName ??
          r.source.materialName ??
          '(没选)',
      cellBuilder: (_, r) => ValueListenableBuilder<String?>(
        valueListenable: r.material,
        builder: (context, value, _) => Row(
          children: [
            Expanded(
              child: UtenDropdownField(
                key: Key('wm-prep-material-${r.id}'),
                dense: true,
                allowClear: false,
                enabled: _busyTitle == null && _worksetCurrent,
                value: value,
                hintText: '颗粒',
                items: _materialItems(r),
                onChanged: (key) {
                  final targets = _targets(r);
                  if (targets.any(
                    (row) =>
                        key != row.originalMaterialKey &&
                        !_materialByKey(row).containsKey(key),
                  )) {
                    context.appWarning('所选产品的合法颗粒范围不同，请分别选择');
                    return;
                  }
                  for (final target in targets) {
                    target.material.value = key;
                  }
                },
              ),
            ),
            if (r.keepsLegacyPrefill)
              const Tooltip(
                message: '按老库材质预填, 请核对',
                child: Icon(
                  Icons.flag_outlined,
                  size: 18,
                  color: UtenColors.warning,
                ),
              ),
          ],
        ),
      ),
    ),
    EditableGridColumn<WmPrepRow>(
      key: 'grams',
      exactValueOf: (row) => row.grams.text,
      exactListenableOf: (row) => row.grams,
      label: l10n.wmUnitWeightGrams,
      width: 170,
      numeric: true,
      frozenTextOf: (r) => r.grams.text,
      headerInfo: '件重, 不含水口。与货品资料单重差 20% 以上或是一键填入的会标黄, 请核对。',
      cellBuilder: (_, r) => ListenableBuilder(
        listenable: Listenable.merge([r.grams, r.autofilled]),
        builder: (context, _) {
          final flagged = r.autofilled.value || r.deviates;
          return Row(
            children: [
              Expanded(
                child: TextField(
                  key: Key('wm-prep-grams-${r.id}'),
                  controller: r.grams,
                  enabled: _busyTitle == null && _worksetCurrent,
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                  ),
                  decoration: applyAutofillHint(
                    InputDecoration(
                      isDense: true,
                      hintText: l10n.wmUnitWeightGrams,
                      suffixText: 'g',
                    ),
                    theme,
                    autofilled: flagged,
                  ),
                  onChanged: (text) {
                    for (final target in _targets(r)) {
                      if (target != r) target.grams.text = text;
                      target.autofilled.value = false;
                    }
                  },
                ),
              ),
              if (flagged)
                Tooltip(
                  message: r.autofilled.value
                      ? '由货品资料单重填入, 请核对'
                      : '与货品资料单重差 20% 以上, 请核对',
                  child: Icon(
                    Icons.flag_outlined,
                    key: Key('wm-prep-flag-${r.id}'),
                    size: 18,
                    color: UtenColors.warning,
                  ),
                ),
            ],
          );
        },
      ),
    ),
    EditableGridColumn<WmPrepRow>(
      key: 'goodsWeight',
      exactValueOf: (row) => row.source.goodsWeightGrams?.toString(),
      label: '参考: 货品资料单重 (克)',
      width: 160,
      numeric: true,
      textOf: (r) => wmQty(r.source.goodsWeightGrams, maxDecimals: 3),
      cellBuilder: (_, r) =>
          Text(wmQty(r.source.goodsWeightGrams, maxDecimals: 3)),
    ),
  ];

  Future<void> _save() async {
    if (!_worksetCurrent || _readDenied || _opening || _busyTitle != null) {
      return;
    }
    final l10n = AppLocalizations.of(context);
    final dirtyProducts = {
      for (final r in _grid.rows)
        if (r.dirty) r.source.productGoodsId,
    };
    if (dirtyProducts.isEmpty) {
      context.appInfo('没有要保存的修改');
      return;
    }
    // 一个产品改了任一行, 这个产品的全部行一起提交。
    final rows = [
      for (final r in _grid.rows)
        if (dirtyProducts.contains(r.source.productGoodsId)) r,
    ];
    final byProduct = <String, List<WmPrepRow>>{};
    for (final row in rows) {
      byProduct.putIfAbsent(row.source.productGoodsId, () => []).add(row);
    }
    for (final group in byProduct.values) {
      final name = group.first.productDisplay;
      for (final row in group) {
        final grams = row.grams.text.trim();
        if (row.material.value == null) {
          context.appWarning('「$name」还没选颗粒');
          return;
        }
        if (grams.isNotEmpty &&
            (row.gramsValue == null || row.gramsValue! <= 0)) {
          context.appWarning('「$name」的单个重量要大于 0');
          return;
        }
        if (grams.isEmpty && row.source.bomItemId != null) {
          context.appWarning(
            '「$name」的 BOM 里已经填了单个重量, 开工按 BOM 用料; 请填单个重量, 不能只选料',
          );
          return;
        }
      }
      final weighed = group.where((r) => r.gramsValue != null).length;
      if (weighed > 0 && weighed < group.length) {
        context.appWarning('「$name」的几种料要么都填单个重量, 要么都先只选料');
        return;
      }
      final keys = group.map((r) => r.material.value).toSet();
      if (keys.length < group.length) {
        context.appWarning('「$name」同一种颗粒选了两行, 请改掉其中一行');
        return;
      }
    }
    final unusual = rows.where((r) => r.dirty && r.unusual).toList();
    if (unusual.isNotEmpty) {
      final ok = await UtenDialog.show(
        context,
        title: '单个重量核对',
        content: Text(
          [
            for (final r in unusual)
              '${r.productDisplay}: ${l10n.wmUnusualWeightConfirm(wmQty(r.gramsValue, maxDecimals: 3))}',
          ].join('\n'),
        ),
        confirmLabel: '确定没错',
      );
      if (ok != true || !mounted) return;
    }
    final bodies = [
      for (final r in rows)
        <String, dynamic>{
          'productGoodsId': r.source.productGoodsId,
          'bomItemId': ?r.source.bomItemId,
          'materialGoodsId':
              _materialByKey(r)[r.material.value]?.goodsId ??
              r.source.materialGoodsId,
          'colorId':
              _materialByKey(r)[r.material.value]?.colorId ??
              (r.material.value == r.originalMaterialKey
                  ? r.source.materialColorId
                  : null),
          'unitWeightGrams': r.gramsValue,
          if (r.dirty && r.unusual) periodicConfirmUnusualWeight: true,
          if (r.keepsLegacyPrefill) 'prefillSource': 'LEGACY_MATERIAL_TEXT',
        },
    ];
    setState(() => _busyTitle = '正在保存上线准备');
    _hasSubmittedWorkset = true;
    try {
      List<String> warnings;
      while (true) {
        try {
          warnings = await _repo.savePreparation(
            widget.workshopId,
            bodies,
            idempotencyKey: wmIdempotencyKey('prep', _nonce, bodies),
          );
          break;
        } on ApiException catch (e) {
          // 服务端还要人确认 (异常单重 / 同一产品第二种料): 撤遮罩、问完带上确认重发。
          final confirmations = periodicConfirmationsOf(e);
          if (confirmations == null || !mounted) rethrow;
          setState(() => _busyTitle = null);
          await WidgetsBinding.instance.endOfFrame;
          if (!mounted) return;
          final confirmed = await askPeriodicConfirmations(
            context,
            confirmations,
          );
          if (confirmed == null || !mounted) return;
          applyPeriodicConfirmations(bodies, confirmed);
          setState(() => _busyTitle = '正在保存上线准备');
        }
      }
      if (!mounted) return;
      setState(() => _busyTitle = null);
      await WidgetsBinding.instance.endOfFrame;
      if (!mounted) return;
      if (warnings.isEmpty) {
        context.appSuccess('已保存 ${byProduct.length} 个产品');
      } else {
        context.appWarning(
          '已保存 ${byProduct.length} 个产品, 请留意: ${warnings.take(5).join('; ')}',
        );
      }
      _grid.replaceAll(const []);
      _productMaterials.clear();
      _editorOwner = null;
      _editorWorkshop = null;
      _editorDataVersion = null;
      _editorScopeVersion = null;
      _editorCatalogVersion = null;
      _hasSubmittedWorkset = false;
      await _load();
    } on ApiException catch (e) {
      if (mounted) {
        setState(() => _busyTitle = null);
        context.appWarning(e.message);
      }
    } catch (_) {
      if (mounted) {
        setState(() => _busyTitle = null);
        context.appWarning('网络不稳定, 暂时没确认保存结果, 请再点一次保存 (不会重复写)');
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final prep = _readDenied ? null : _prep;
    return Stack(
      children: [
        Column(
          children: [
            if (prep != null)
              Padding(
                padding: const EdgeInsets.all(UtenSpacing.s8),
                child: Text(
                  l10n.wmGoLiveProgress(prep.total, prep.chosen, prep.weighed),
                  key: const Key('wm-prep-progress'),
                  style: theme.textTheme.titleSmall,
                ),
              ),
            Expanded(
              child: WmProductSummaryTable(
                key: const Key('wm-prep-summary'),
                tableKey: 'workshop.material.preparation.complete-summary',
                items: _readDenied ? const [] : _summary?.items ?? const [],
                openedIds: {
                  if (_worksetCurrent)
                    for (final r in _grid.rows) r.source.productGoodsId,
                },
                onOpen: _openProduct,
                onRetry: _load,
                enabled: !_opening && _busyTitle == null && _worksetCurrent,
                loading: _loading,
                error: _error,
              ),
            ),
            if (!_grid.isEmpty)
              Row(
                children: [
                  const Text('已打开的编辑明细'),
                  UtenFieldHintIcon(
                    info: _worksetCurrent
                        ? '保留完整产品组及原输入；保存只提交明确修改的产品，最多500行。'
                        : '读取身份或数据版本已变化。原输入保留，须重新核对后才能保存。',
                  ),
                  UtenButton(
                    type: UtenButtonType.secondary,
                    onPressed:
                        _busyTitle == null && !_opening && !_hasSubmittedWorkset
                        ? _closeWorkset
                        : null,
                    child: const Text('重新选择编辑产品'),
                  ),
                ],
              ),
            if (!_readDenied && _worksetOwnerCurrent && !_grid.isEmpty)
              SizedBox(
                height: 280,
                child: UtenEditableGrid<WmPrepRow>(
                  headerFilterScopeDescription: '筛选已打开的编辑明细；上方产品摘要为当前范围完整清单',
                  tableKey:
                      'features.warehouse.materialbin.widgets.workshop_material_prep_tab.WmPrepTabState.build.1',
                  key: const Key('wm-prep-grid'),
                  controller: _grid,
                  columns: _columns(l10n, theme),
                  showAddRow: false,
                  selectable: true,
                  showRowDelete: false,
                  showColumnSettings: false,
                  onRowsHiddenByFilter: (hidden) =>
                      setState(() => _hidden = hidden),
                ),
              ),
            const SizedBox(height: UtenFloatingActionGroup.scrollClearance),
          ],
        ),
        PositionedDirectional(
          end: UtenSpacing.s16,
          bottom: UtenSpacing.s16,
          child: ListenableBuilder(
            listenable: _grid,
            builder: (context, _) => UtenFloatingActionGroup(
              children: [
                UtenButton(
                  key: const Key('wm-prep-fill-goods-weight'),
                  type: UtenButtonType.secondary,
                  size: UtenButtonSize.large,
                  icon: Icons.auto_fix_high_outlined,
                  onPressed:
                      _busyTitle == null &&
                          !_loading &&
                          !_readDenied &&
                          _worksetCurrent &&
                          !_opening &&
                          _grid.selectedCount > 0
                      ? _fillFromGoodsWeight
                      : null,
                  child: Text(
                    '${l10n.wmFillFromGoodsWeight} (${_grid.selectedCount})',
                  ),
                ),
                UtenButton(
                  key: const Key('wm-prep-save'),
                  size: UtenButtonSize.large,
                  icon: Icons.save_outlined,
                  onPressed:
                      _busyTitle == null &&
                          !_loading &&
                          !_readDenied &&
                          _worksetCurrent &&
                          !_opening &&
                          !_grid.isEmpty
                      ? _save
                      : null,
                  child: Text(l10n.commonSave),
                ),
              ],
            ),
          ),
        ),
        if (_busyTitle != null) UtenBusyOverlay(title: _busyTitle!),
        if (_opening && _busyTitle == null)
          const UtenBusyOverlay(title: '正在读取产品明细'),
        if (_loading && !_opening && _busyTitle == null)
          const UtenBusyOverlay(title: '正在读取上线准备'),
      ],
    );
  }
}
