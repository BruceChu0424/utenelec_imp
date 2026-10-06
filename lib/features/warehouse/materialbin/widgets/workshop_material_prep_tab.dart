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
import '../../../../components/feedback/uten_empty.dart';
import '../../../../components/inputs/required_field_decoration.dart';
import '../../../../components/inputs/uten_dropdown_field.dart';
import '../../../../components/layout/uten_editable_grid.dart';
import '../../../../core/l10n/gen/app_localizations.dart';
import '../../../../core/network/api_exception.dart';
import '../../../../core/theme/uten_colors.dart';
import '../../../../core/theme/uten_tokens.dart';
import '../../../../core/ui/app_notification.dart';
import '../../../basic_data/widgets/periodic_bom_confirmation.dart';
import '../models/workshop_material_models.dart';
import '../repositories/workshop_material_repository.dart';
import 'workshop_material_labels.dart';

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

class _WmPrepTabState extends ConsumerState<WmPrepTab> {
  final _grid = UtenEditableGridController<WmPrepRow>();
  final _nonce = const Uuid().v4();
  WmPreparation? _prep;
  List<WmMaterialOption> _materials = const [];
  Set<WmPrepRow> _hidden = const {};
  bool _loading = true;
  // 服务端按「常做程度」截断行数(进度三数是独立聚合)；为真时在进度下提示截断。
  bool _truncated = false;
  String? _error;
  String? _busyTitle;

  WorkshopMaterialRepository get _repo =>
      ref.read(workshopMaterialRepositoryProvider);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  @override
  void dispose() {
    _grid.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final prep = await _repo.preparation(widget.workshopId);
      if (!mounted) return;
      setState(() {
        _prep = prep;
        _materials = prep.materials;
        _grid.replaceAll(wmPrepRowsOf(prep.rows));
        _truncated =
            prep.total > prep.rows.map((r) => r.productGoodsId).toSet().length;
        _loading = false;
      });
    } on ApiException catch (e) {
      if (mounted) {
        setState(() {
          _loading = false;
          _error = e.message;
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _loading = false;
          _error = '加载上线准备清单失败, 请重试';
        });
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

  Map<String, WmMaterialOption> get _materialByKey => {
    for (final m in _materials) m.key: m,
  };

  List<UtenDropdownItem> _materialItems(WmPrepRow row) {
    final items = [
      for (final m in _materials)
        UtenDropdownItem(value: m.key, label: m.displayName),
    ];
    final original = row.originalMaterialKey;
    if (original != null && !_materialByKey.containsKey(original)) {
      items.insert(
        0,
        UtenDropdownItem(
          value: original,
          label: row.source.materialName ?? '原来选的料',
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
      // 2026-09-27 用户口径「表格状态列整格底色」：已填单重=绿 / 待填=琥珀 /
      // 待准备=中性灰；不用内料仓的行不铺色。
      cellColor: (context, r) => switch (r.source.status) {
        'WEIGHED' => udenStatusBadgeCellColor(
          context,
          UtenStatusBadgeType.success,
        ),
        'CHOSEN' => udenStatusBadgeCellColor(
          context,
          UtenStatusBadgeType.warning,
        ),
        'NOT_FROM_STORE' => null,
        _ => udenStatusBadgeCellColor(context, UtenStatusBadgeType.neutral),
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
      textOf: (r) => _materialByKey[r.material.value]?.displayName ?? '',
      listenableOf: (r) => r.material,
      filterValueOf: (r) =>
          _materialByKey[r.material.value]?.displayName ?? '(没选)',
      cellBuilder: (_, r) => ValueListenableBuilder<String?>(
        valueListenable: r.material,
        builder: (context, value, _) => Row(
          children: [
            Expanded(
              child: UtenDropdownField(
                key: Key('wm-prep-material-${r.id}'),
                dense: true,
                allowClear: false,
                enabled: _busyTitle == null,
                value: value,
                hintText: '选颗粒',
                items: _materialItems(r),
                onChanged: (key) {
                  for (final target in _targets(r)) {
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
                  enabled: _busyTitle == null,
                  textAlign: TextAlign.right,
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                  ),
                  decoration: applyAutofillHint(
                    const InputDecoration(isDense: true, hintText: '克'),
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
    final byKey = _materialByKey;
    final bodies = [
      for (final r in rows)
        <String, dynamic>{
          'productGoodsId': r.source.productGoodsId,
          'bomItemId': ?r.source.bomItemId,
          'materialGoodsId':
              byKey[r.material.value]?.goodsId ?? r.source.materialGoodsId,
          'colorId':
              byKey[r.material.value]?.colorId ??
              (r.material.value == r.originalMaterialKey
                  ? r.source.materialColorId
                  : null),
          'unitWeightGrams': r.gramsValue,
          if (r.dirty && r.unusual) periodicConfirmUnusualWeight: true,
          if (r.keepsLegacyPrefill) 'prefillSource': 'LEGACY_MATERIAL_TEXT',
        },
    ];
    setState(() => _busyTitle = '正在保存上线准备');
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
    final prep = _prep;
    if (_loading && prep == null) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null && prep == null) {
      return UtenEmpty.error(
        message: _error,
        actionLabel: '重试',
        onAction: _load,
      );
    }
    return Stack(
      children: [
        SingleChildScrollView(
          // 末尾留出右下悬浮按钮组的位置 (平台统一: 动作放右下悬浮组, ADR-147)。
          padding: const EdgeInsets.only(
            top: UtenSpacing.s8,
            bottom: UtenFloatingActionGroup.scrollClearance,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                l10n.wmGoLiveProgress(
                  prep?.total ?? 0,
                  prep?.chosen ?? 0,
                  prep?.weighed ?? 0,
                ),
                key: const Key('wm-prep-progress'),
                style: theme.textTheme.titleSmall,
              ),
              if (_truncated)
                Padding(
                  padding: const EdgeInsets.only(top: UtenSpacing.s2),
                  child: Text(
                    '产品较多，按常做程度显示最常做的一部分；进度统计仍按全部产品计算。',
                    key: const Key('wm-prep-truncated'),
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
              const SizedBox(height: UtenSpacing.s4),
              Text(
                '单个重量填件重 (不含水口)。勾选多行后改任一勾选行的颗粒或单重, 会对全部勾选行生效。'
                '只选了料、没填单重的产品也能先保存, 车间照常开工, 结算前补上单重即可。',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: UtenSpacing.s8),
              if (_grid.isEmpty)
                const UtenEmpty(
                  message: '没有要准备的产品',
                  description: '近 12 个月这个车间没有做过、也没有归属它的产品',
                )
              else
                UtenEditableGrid<WmPrepRow>(
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
            ],
          ),
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
                  onPressed: _busyTitle == null && _grid.selectedCount > 0
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
                  onPressed: _busyTitle == null && !_grid.isEmpty
                      ? _save
                      : null,
                  child: Text(l10n.commonSave),
                ),
              ],
            ),
          ),
        ),
        if (_busyTitle != null) UtenBusyOverlay(title: _busyTitle!),
      ],
    );
  }
}
