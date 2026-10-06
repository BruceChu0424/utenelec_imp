// 车间内料仓开通面板 (ADR-147; 取代 ADR-131 的「开启整批领料」对话框)。
//
// 全站右侧滑窗 (showUtenAdaptivePanel), 一次办多个车间:
// - 发料来源仓: 点开全站仓库滑窗 (先主仓, 再子仓; 只能选启用中的良品子仓), 不选 = 按货品所属仓库;
// - 「同时开启整批领料」: 打开后才出现启用日与在产认料;
// - 在产认料: 所选车间正在生产、还没认料的产品按产品去重 (一个产品只认一次), 用平台表格逐行选料,
//   勾选多行后改任一勾选行的用料 = 全部勾选行生效。
// 一个原子请求 (POST /settings/batch-enable, 全成全败); 失败时保留全部输入并复用同一个请求号。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../../../../components/buttons/uten_button.dart';
import '../../../../components/feedback/uten_busy_overlay.dart';
import '../../../../components/feedback/uten_inline_notice.dart';
import '../../../../components/inputs/uten_date_field.dart';
import '../../../../components/inputs/uten_dropdown_field.dart';
import '../../../../components/inputs/uten_filter_picker_field.dart';
import '../../../../components/layout/uten_adaptive_panel.dart';
import '../../../../components/layout/uten_editable_grid.dart';
import '../../../../core/l10n/gen/app_localizations.dart';
import '../../../../core/network/api_exception.dart';
import '../../../../core/theme/uten_tokens.dart';
import '../../../../core/ui/app_notification.dart';
import '../../../../core/utils/china_datetime.dart';
import '../../../../shared/providers/master_name_provider.dart';
import '../../../../shared/widgets/warehouse_picker_panel.dart';
import '../../../../shared/widgets/warehouse_selection.dart';
import '../models/workshop_material_models.dart';
import '../models/workshop_source_warehouse_option.dart';
import '../repositories/workshop_material_repository.dart';

/// 面板要办的事: 开通 / 开启整批领料 (没开通的同时开通) / 只改发料来源仓。
enum WmBinPanelMode { open, periodic, source }

/// "本产品不用车间内料仓的料"在下拉里的取值。
const wmNoneChoice = '__NONE__';

/// 打开开通面板; 办成后返回各车间的新状态, 关闭或失败返回 null。
Future<List<WmSetting>?> showWorkshopBinOpeningPanel(
  BuildContext context, {
  required List<WmSetting> settings,
  required WmBinPanelMode mode,
}) => showUtenAdaptivePanel<List<WmSetting>>(
  context: context,
  drawerWidth: 760,
  barrierDismissible: false,
  builder: (_) => WorkshopBinOpeningPanel(settings: settings, mode: mode),
);

class WorkshopBinOpeningPanel extends ConsumerStatefulWidget {
  const WorkshopBinOpeningPanel({
    super.key,
    required this.settings,
    required this.mode,
  });

  final List<WmSetting> settings;
  final WmBinPanelMode mode;

  @override
  ConsumerState<WorkshopBinOpeningPanel> createState() =>
      _WorkshopBinOpeningPanelState();
}

/// 在产认料表的一行 (一个产品)。
class WmPendingChoiceRow extends EditableGridRow {
  WmPendingChoiceRow(this.product)
    : choice = ValueNotifier<String?>(
        product.prefillMaterials.isEmpty
            ? null
            : product.prefillMaterials.first.key,
      );

  final WmPendingProductChoice product;
  final ValueNotifier<String?> choice;
  final ValueNotifier<bool> alsoOrder = ValueNotifier<bool>(false);

  List<WmMaterialRef> get options => [
    ...product.materialOptions,
    for (final m in product.prefillMaterials)
      if (!product.materialOptions.any((o) => o.key == m.key)) m,
  ];

  bool get prefilled =>
      choice.value != null &&
      product.prefillMaterials.any((m) => m.key == choice.value);

  WmProductChoiceInput toInput() {
    if (choice.value == wmNoneChoice) {
      return WmProductChoiceInput(
        productGoodsId: product.productGoodsId,
        kind: 'NONE',
      );
    }
    WmMaterialRef? material;
    for (final m in options) {
      if (m.key == choice.value) material = m;
    }
    return WmProductChoiceInput(
      productGoodsId: product.productGoodsId,
      kind: 'MATERIAL',
      materials: [?material],
      alsoOrderMaterials: product.canAlsoOrderMaterials && alsoOrder.value,
      prefillSource: prefilled ? product.prefillSource : null,
    );
  }

  @override
  void dispose() {
    choice.dispose();
    alsoOrder.dispose();
    super.dispose();
  }
}

class _WorkshopBinOpeningPanelState
    extends ConsumerState<WorkshopBinOpeningPanel> {
  final _nonce = const Uuid().v4();
  final _grid = UtenEditableGridController<WmPendingChoiceRow>();
  bool _loading = true;
  String? _loadError;
  List<WmSourceWarehouse> _sources = const [];
  late String? _sourceId = _initialSource();

  /// 改来源仓时选「不指定来源仓, 恢复按货品所属仓库发料」(来源仓置空)。
  bool _followOwning = false;
  late bool _periodic = widget.mode == WmBinPanelMode.periodic;
  DateTime _goLive = ChinaDateTime.today();
  bool _saving = false;
  String? _error;

  WorkshopMaterialRepository get _repo =>
      ref.read(workshopMaterialRepositoryProvider);

  /// 所选车间都用同一个来源仓时带出来; 各不相同时留空, 由人重新选。
  String? _initialSource() {
    final ids = widget.settings.map((s) => s.sourceWarehouseId).toSet();
    return ids.length == 1 ? ids.first : null;
  }

  /// 要开启整批领料的车间 (已经整批领料中的不算)。
  List<WmSetting> get _periodicTargets => [
    for (final s in widget.settings)
      if (s.status != WmBinStatus.periodic) s,
  ];

  bool get _choosesPeriodic => widget.mode != WmBinPanelMode.source;

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
      _loadError = null;
    });
    try {
      final sources = await _repo.sourceWarehouses();
      // 在产认料只在要开启整批领料时才读 (只开通不需要)。
      final pending = _choosesPeriodic && _periodic
          ? await _pendingFor(_periodicTargets)
          : null;
      if (!mounted) return;
      setState(() {
        _sources = sources;
        if (_sourceId != null &&
            !sources.any((w) => w.id == _sourceId && w.selectable)) {
          _sourceId = null;
        }
        if (pending != null) _usePending(pending);
        _loading = false;
      });
    } on ApiException catch (e) {
      if (mounted) {
        setState(() {
          _loading = false;
          _loadError = e.message;
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _loading = false;
          _loadError = AppLocalizations.of(context).wmBinLoadFailed;
        });
      }
    }
  }

  bool _pendingLoaded = false;

  Future<List<WmPendingProductChoice>> _pendingFor(List<WmSetting> targets) =>
      targets.isEmpty
      ? Future.value(const <WmPendingProductChoice>[])
      : _repo.inProgressPending([
          for (final s in targets) s.workshopDepartmentId,
        ]);

  void _usePending(List<WmPendingProductChoice> pending) {
    _grid.replaceAll([for (final p in pending) WmPendingChoiceRow(p)]);
    _pendingLoaded = true;
  }

  /// 开通时才打开「同时开启整批领料」: 这时再读在产认料。
  Future<void> _setPeriodic(bool value) async {
    setState(() {
      _periodic = value;
      _error = null;
    });
    if (!value || _pendingLoaded) return;
    setState(() => _loading = true);
    try {
      final pending = await _pendingFor(_periodicTargets);
      if (!mounted) return;
      setState(() {
        _usePending(pending);
        _loading = false;
      });
    } on ApiException catch (e) {
      if (mounted) {
        setState(() {
          _loading = false;
          _loadError = e.message;
        });
      }
    }
  }

  String? _sourceLabel() {
    if (_sourceId == null) return null;
    final hierarchy = [for (final w in _sources) w.toDictEntry()];
    return warehouseFullLabel(hierarchy, _sourceId!);
  }

  Future<void> _pickSource(AppLocalizations l10n) async {
    if (_saving) return;
    final hierarchy = <WarehouseDictEntry>[
      for (final w in _sources) w.toDictEntry(),
    ];
    final picked = await showUtenWarehousePickerPanel(
      context,
      hierarchy: hierarchy,
      use: WarehouseUse.goodOut,
      initialWarehouseId: _sourceId,
      title: l10n.wmBinSourcePickerTitle,
    );
    if (picked == null || !mounted || picked.isAll) return;
    setState(() {
      _sourceId = picked.id;
      _error = null;
    });
  }

  List<WmPendingChoiceRow> _targets(WmPendingChoiceRow row) {
    final selected = _grid.selectedRows;
    if (!_grid.isSelected(row) || selected.length < 2) return [row];
    return selected;
  }

  Future<void> _submit(AppLocalizations l10n) async {
    if (_saving) return;
    final periodic = _choosesPeriodic && _periodic;
    final clearSource = widget.mode == WmBinPanelMode.source && _followOwning;
    if (widget.mode == WmBinPanelMode.source &&
        !clearSource &&
        _sourceId == null) {
      setState(() => _error = l10n.wmBinSourceRequired);
      return;
    }
    final sourceId = clearSource ? null : _sourceId;
    final rows = periodic ? _grid.rows : const <WmPendingChoiceRow>[];
    final missing = [
      for (final row in rows)
        if (row.choice.value == null) row.product.productDisplay,
    ];
    if (missing.isNotEmpty) {
      setState(
        () => _error = l10n.wmBinMissingChoice(
          missing.length,
          missing.take(5).join('、'),
        ),
      );
      return;
    }
    final choices = [for (final row in rows) row.toInput()];
    final goLive = periodic ? ChinaDateTime.formatDate(_goLive) : null;
    final items = [for (final s in widget.settings) WmBinItem.of(s)];
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final saved = await _repo.batchEnable(
        items: items,
        sourceWarehouseId: sourceId,
        clearSource: clearSource,
        periodic: periodic,
        goLiveDate: goLive,
        inProgressChoices: choices,
        // 内容不变重试 = 同一个请求号 (服务端按号去重, 不会重复开通)。
        idempotencyKey: wmIdempotencyKey('bin-enable', _nonce, {
          'items': [for (final i in items) i.toJson()],
          'source': sourceId,
          'clearSource': clearSource,
          'periodic': periodic,
          'goLive': goLive,
          'choices': [for (final c in choices) c.toJson()],
        }),
      );
      if (!mounted) return;
      setState(() => _saving = false);
      await WidgetsBinding.instance.endOfFrame;
      if (!mounted) return;
      context.appSuccess(switch (widget.mode) {
        WmBinPanelMode.source when clearSource => l10n.wmBinSourceCleared,
        WmBinPanelMode.source => l10n.wmBinSourceSaved,
        _ when periodic => l10n.wmBinPeriodicDone(saved.length),
        _ => l10n.wmBinOpenDone(saved.length),
      });
      Navigator.of(context).pop(saved);
    } on ApiException catch (e) {
      if (mounted) {
        setState(() {
          _saving = false;
          // 服务端一次把每个车间的问题都列在 message 里 (全成全败)。
          _error = e.message;
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _saving = false;
          _error = l10n.wmBinNetworkRetry;
        });
      }
    }
  }

  String _title(AppLocalizations l10n) => switch (widget.mode) {
    WmBinPanelMode.open => l10n.wmBinPanelTitleOpen,
    WmBinPanelMode.periodic => l10n.wmEnable,
    WmBinPanelMode.source => l10n.wmBinPanelTitleSource,
  };

  String _submitLabel(AppLocalizations l10n) {
    final n = widget.settings.length;
    if (widget.mode == WmBinPanelMode.source) return l10n.wmBinSaveSource;
    return _periodic ? l10n.wmBinPeriodicAction(n) : l10n.wmBinOpenAction(n);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    return PopScope(
      canPop: !_saving,
      child: Stack(
        children: [
          Scaffold(
            backgroundColor: Colors.transparent,
            body: SafeArea(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Padding(
                    padding: const EdgeInsets.all(UtenSpacing.s16),
                    child: Row(
                      children: [
                        Expanded(
                          child: Text(
                            _title(l10n),
                            style: theme.textTheme.titleMedium?.copyWith(
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                        IconButton(
                          key: const Key('wm-bin-panel-close'),
                          tooltip: l10n.commonCancel,
                          onPressed: _saving
                              ? null
                              : () => Navigator.of(context).pop(),
                          icon: const Icon(Icons.close_rounded),
                        ),
                      ],
                    ),
                  ),
                  const Divider(height: 1),
                  Expanded(child: _body(l10n, theme)),
                  const Divider(height: 1),
                  Padding(
                    padding: const EdgeInsets.all(UtenSpacing.s12),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        UtenButton(
                          type: UtenButtonType.ghost,
                          onPressed: _saving
                              ? null
                              : () => Navigator.of(context).pop(),
                          child: Text(l10n.commonCancel),
                        ),
                        const SizedBox(width: UtenSpacing.s12),
                        if (_loadError != null)
                          UtenButton(
                            onPressed: _load,
                            child: Text(l10n.commonRetry),
                          )
                        else
                          UtenButton(
                            key: const Key('wm-bin-panel-submit'),
                            isLoading: _saving,
                            onPressed: _saving || _loading
                                ? null
                                : () => _submit(l10n),
                            child: Text(_submitLabel(l10n)),
                          ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
          if (_saving)
            UtenBusyOverlay(
              title: l10n.wmBinSaving,
              description: _periodic ? l10n.wmBinSavingPeriodic : null,
            ),
        ],
      ),
    );
  }

  Widget _body(AppLocalizations l10n, ThemeData theme) {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_loadError != null) {
      return Padding(
        padding: const EdgeInsets.all(UtenSpacing.s16),
        child: UtenInlineNotice(
          level: UtenInlineNoticeLevel.error,
          message: _loadError!,
        ),
      );
    }
    final today = ChinaDateTime.today();
    final periodic = _choosesPeriodic && _periodic;
    return ListView(
      padding: const EdgeInsets.all(UtenSpacing.s16),
      children: [
        Text(
          l10n.wmBinSelectedWorkshops(
            widget.settings.length,
            widget.settings.map((s) => s.workshopName).join('、'),
          ),
          key: const Key('wm-bin-panel-workshops'),
          style: theme.textTheme.bodyMedium,
        ),
        const SizedBox(height: UtenSpacing.s12),
        SizedBox(
          width: double.infinity,
          child: UtenFilterPickerField(
            key: const Key('wm-bin-panel-source'),
            label: l10n.wmBinColSource,
            value: _followOwning ? null : _sourceLabel(),
            placeholder: l10n.wmBinSourceDefault,
            icon: Icons.warehouse_outlined,
            width: null,
            enabled: !_saving && !_followOwning,
            onTap: () => _pickSource(l10n),
          ),
        ),
        if (widget.mode == WmBinPanelMode.source)
          SwitchListTile(
            key: const Key('wm-bin-panel-follow-owning'),
            contentPadding: EdgeInsets.zero,
            value: _followOwning,
            onChanged: _saving
                ? null
                : (value) => setState(() {
                    _followOwning = value;
                    _error = null;
                  }),
            title: Text(l10n.wmBinSourceFollowOwning),
            subtitle: Text(l10n.wmBinSourceFollowOwningHint),
          ),
        const SizedBox(height: UtenSpacing.s4),
        Text(
          l10n.wmBinSourceHint,
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        if (_choosesPeriodic && widget.mode == WmBinPanelMode.open) ...[
          const SizedBox(height: UtenSpacing.s8),
          SwitchListTile(
            key: const Key('wm-bin-panel-periodic'),
            contentPadding: EdgeInsets.zero,
            value: _periodic,
            onChanged: _saving ? null : _setPeriodic,
            title: Text(l10n.wmBinAlsoPeriodic),
            subtitle: Text(l10n.wmBinAlsoPeriodicHint),
          ),
        ],
        if (periodic) ...[
          const SizedBox(height: UtenSpacing.s8),
          UtenInlineNotice(
            key: const Key('wm-enable-flow-notice'),
            message: l10n.wmBinPeriodicFlowNotice,
          ),
          const SizedBox(height: UtenSpacing.s12),
          SizedBox(
            width: 240,
            child: UtenDateField(
              key: const Key('wm-enable-go-live'),
              label: l10n.wmGoLiveDate,
              required: true,
              enabled: !_saving,
              value: _goLive,
              firstDate: today.subtract(const Duration(days: 31)),
              lastDate: today.add(const Duration(days: 366)),
              onChanged: (v) =>
                  setState(() => _goLive = ChinaDateTime.asWallTime(v)),
            ),
          ),
          const SizedBox(height: UtenSpacing.s16),
          Text(
            _grid.isEmpty
                ? l10n.wmBinPendingNone
                : l10n.wmBinPendingTitle(_grid.length),
            style: theme.textTheme.titleSmall,
          ),
          if (!_grid.isEmpty) ...[
            const SizedBox(height: UtenSpacing.s8),
            SizedBox(
              height: (_grid.length * 52.0 + 120).clamp(180.0, 460.0),
              child: UtenEditableGrid<WmPendingChoiceRow>(
                tableKey:
                    'features.warehouse.materialbin.widgets.workshop_material_enable_panel.pending',
                key: const Key('wm-bin-panel-pending'),
                controller: _grid,
                columns: _columns(l10n, theme),
                showAddRow: false,
                selectable: true,
                showRowDelete: false,
                showColumnSettings: false,
              ),
            ),
          ],
        ],
        if (_error != null) ...[
          const SizedBox(height: UtenSpacing.s12),
          Semantics(
            liveRegion: true,
            child: Text(
              _error!,
              key: const Key('wm-enable-error'),
              style: TextStyle(color: theme.colorScheme.error),
            ),
          ),
        ],
      ],
    );
  }

  List<EditableGridColumn<WmPendingChoiceRow>> _columns(
    AppLocalizations l10n,
    ThemeData theme,
  ) => [
    EditableGridColumn<WmPendingChoiceRow>(
      key: 'product',
      label: l10n.wmBinColProduct,
      width: 200,
      textOf: (row) => row.product.productDisplay,
      // 2026-10-06 行高统一口径：名称 + 小字注记并到单行（注记挂 Tooltip），
      // 不再用 Column 两层把行撑高。
      cellBuilder: (context, row) {
        final subline = row.product.productSubline;
        if (subline == null) {
          return Text(
            row.product.productDisplay,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          );
        }
        return Tooltip(
          message: '${row.product.productDisplay}\n$subline',
          child: Text.rich(
            TextSpan(
              text: row.product.productDisplay,
              children: [
                TextSpan(
                  text: ' · $subline',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        );
      },
    ),
    EditableGridColumn<WmPendingChoiceRow>(
      key: 'workshops',
      label: l10n.wmBinColInProgressWorkshops,
      width: 150,
      textOf: (row) => row.product.workshopNames.join('、'),
      // 2026-10-06 行高统一口径：单行省略号 + Tooltip，不用两行文本撑高行。
      cellBuilder: (context, row) => Tooltip(
        message: row.product.workshopNames.join('、'),
        child: Text(
          row.product.workshopNames.join('、'),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
      ),
    ),
    EditableGridColumn<WmPendingChoiceRow>(
      key: 'tasks',
      label: l10n.wmBinColTasks,
      width: 70,
      numeric: true,
      textOf: (row) => '${row.product.taskCount}',
      cellBuilder: (context, row) => Text('${row.product.taskCount}'),
    ),
    EditableGridColumn<WmPendingChoiceRow>(
      key: 'material',
      label: l10n.wmBinColMaterial,
      width: 230,
      required: true,
      listenableOf: (row) => row.choice,
      textOf: (row) => _choiceText(l10n, row),
      cellBuilder: (context, row) => ValueListenableBuilder<String?>(
        valueListenable: row.choice,
        builder: (context, value, _) => UtenDropdownField(
          key: Key('wm-enable-choice-${row.product.productGoodsId}'),
          dense: true,
          required: true,
          allowClear: false,
          enabled: !_saving,
          autofilled: row.prefilled,
          value: value,
          hintText: l10n.wmBinChooseMaterialHint,
          items: [
            for (final m in row.options)
              UtenDropdownItem(value: m.key, label: m.displayName),
            UtenDropdownItem(value: wmNoneChoice, label: l10n.wmNotFromStore),
          ],
          onChanged: (next) {
            // 勾选多行后改任一勾选行 = 全部勾选行生效。
            for (final target in _targets(row)) {
              target.choice.value = next;
            }
            setState(() => _error = null);
          },
        ),
      ),
    ),
    EditableGridColumn<WmPendingChoiceRow>(
      key: 'alsoOrder',
      label: l10n.wmBinColAlsoOrder,
      width: 120,
      listenableOf: (row) => row.alsoOrder,
      textOf: (row) => row.alsoOrder.value ? '✓' : '',
      cellBuilder: (context, row) => ValueListenableBuilder<String?>(
        valueListenable: row.choice,
        builder: (context, choice, _) {
          if (!row.product.canAlsoOrderMaterials ||
              choice == null ||
              choice == wmNoneChoice) {
            return const SizedBox.shrink();
          }
          return ValueListenableBuilder<bool>(
            valueListenable: row.alsoOrder,
            // 2026-10-06 行高统一口径：编辑表内 Checkbox 收掉 48dp 触控槽，
            // 不把行撑过 39 的控件行高标准。
            builder: (context, value, _) => Theme(
              data: Theme.of(context).copyWith(
                materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
              child: Checkbox(
                key: Key('wm-enable-also-order-${row.product.productGoodsId}'),
                value: value,
                onChanged: _saving
                    ? null
                    : (next) {
                        for (final target in _targets(row)) {
                          if (target.product.canAlsoOrderMaterials) {
                            target.alsoOrder.value = next ?? false;
                          }
                        }
                      },
              ),
            ),
          );
        },
      ),
    ),
  ];

  String _choiceText(AppLocalizations l10n, WmPendingChoiceRow row) {
    final value = row.choice.value;
    if (value == null) return '';
    if (value == wmNoneChoice) return l10n.wmNotFromStore;
    for (final m in row.options) {
      if (m.key == value) return m.displayName;
    }
    return '';
  }
}

/// 撤销确认里一个车间要退的那一步 (大白话)。
String wmBinRevokeLine(AppLocalizations l10n, WmSetting setting) =>
    setting.status == WmBinStatus.periodic
    ? l10n.wmBinRevokeLinePeriodic(setting.workshopName)
    : l10n.wmBinRevokeLineOpen(setting.workshopName);

/// 三态的中文名与底色 (表格状态列、副标题共用)。
String wmBinStatusLabel(AppLocalizations l10n, String status) =>
    switch (status) {
      WmBinStatus.periodic => l10n.wmBinStatusPeriodic,
      WmBinStatus.open => l10n.wmBinStatusOpen,
      _ => l10n.wmBinStatusNotOpen,
    };
