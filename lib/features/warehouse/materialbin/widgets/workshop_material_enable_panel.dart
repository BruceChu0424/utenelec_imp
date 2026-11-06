// 车间内料仓开通面板 (ADR-147; 取代 ADR-131 的「开启整批领料」对话框)。
//
// 全站右侧滑窗 (showUtenAdaptivePanel), 一次办多个车间:
// - 发料来源仓: 点开全站仓库滑窗 (先主仓, 再子仓; 只能选启用中的良品子仓), 不选 = 按货品所属仓库;
// - 「同时开启整批领料」: 打开后才出现启用日与在产认料;
// - 在产认料: 所选车间正在生产、还没认料的产品按产品去重 (一个产品只认一次), 用平台表格逐行选料,
//   勾选多行后改任一勾选行的用料 = 全部勾选行生效。
// 一个原子请求 (POST /settings/batch-enable, 全成全败); 失败时保留全部输入并复用同一个请求号。
import 'package:uten_imp/components/buttons/uten_close_button.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../../../../components/buttons/uten_button.dart';
import '../../../../components/feedback/uten_busy_overlay.dart';
import '../../../../components/feedback/uten_dialog.dart';
import '../../../../components/feedback/uten_inline_notice.dart';
import '../../../../components/inputs/uten_date_field.dart';
import '../../../../components/inputs/uten_dropdown_field.dart';
import '../../../../components/inputs/uten_filter_picker_field.dart';
import '../../../../components/inputs/uten_field_hint_icon.dart';
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
import 'workshop_material_summary_table.dart';
import '../../../../shared/paging/versioned_summary_read.dart';
import '../../../../shared/paging/read_view_activity.dart';
import '../../../../shared/auth/read_owner_fence.dart';
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
  widthFraction: UtenPanelWidth.content,
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
    extends ConsumerState<WorkshopBinOpeningPanel>
    with ReadViewActivityMixin<WorkshopBinOpeningPanel> {
  final _nonce = const Uuid().v4();
  final _grid = UtenEditableGridController<WmPendingChoiceRow>();
  bool _loading = true;
  bool _opening = false;
  VersionedSummarySnapshot<WmMaterialRef>? _catalog;
  Object? _catalogSummary;
  String? _editorCatalogVersion;
  bool _hasSubmittedWorkset = false;
  int _readGeneration = 0;
  bool Function()? _acceptedOwner;
  bool Function()? _editorOwner;
  String? _editorDataVersion;
  String? _editorScopeVersion;
  VersionedSummarySnapshot<Map<String, dynamic>>? _pendingSummary;

  bool get _worksetOwnerCurrent => _editorOwner?.call() != false;
  bool get _worksetCurrent =>
      _worksetOwnerCurrent &&
      (_catalog == null ||
          _editorCatalogVersion == null ||
          _editorCatalogVersion ==
              (_catalog!.dataVersion ?? _catalog!.revision)) &&
      (_editorDataVersion == null ||
          (_pendingSummary != null &&
              _editorDataVersion ==
                  (_pendingSummary!.dataVersion ?? _pendingSummary!.revision) &&
              _editorScopeVersion == _pendingSummary!.readScopeVersion));
  List<String> get _pendingWorkshopIds => [
    for (final s in _periodicTargets) s.workshopDepartmentId,
  ];

  @override
  Future<void> onReadViewResumed() => _load();
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
    listenReadOwner(ref, () {
      _readGeneration++;
      setState(() {
        _loading = false;
        _opening = false;
        _sources = const [];
        _pendingSummary = null;
        _pendingLoaded = false;
        _acceptedOwner = null;
        _loadError = '读取身份已变化，请重新读取';
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
    bool current() => mounted && owner() && request == _readGeneration;
    setState(() {
      _loading = true;
      _loadError = null;
    });
    try {
      final result = await readViewActivity.runRead(current, () async {
        final sources = await _repo.sourceWarehouses();
        final pending =
            _choosesPeriodic && _periodic && _periodicTargets.isNotEmpty
            ? await _repo.inProgressPendingSummaries(
                _pendingWorkshopIds,
                isCurrent: current,
              )
            : null;
        return (sources, pending);
      });
      if (!mounted || !current()) return;
      setState(() {
        _acceptedOwner = owner;
        _sources = result.$1;
        if (_sourceId != null &&
            !_sources.any((w) => w.id == _sourceId && w.selectable)) {
          _sourceId = null;
        }
        _pendingSummary = result.$2;
        _catalog = null;
        _catalogSummary = null;
        _pendingLoaded = _periodic || _periodicTargets.isEmpty;
      });
    } catch (error) {
      if (mounted && current() && !isRetiredViewRead(error)) {
        setState(
          () => _loadError = error is ApiException
              ? error.message
              : AppLocalizations.of(context).wmBinLoadFailed,
        );
      }
    } finally {
      if (mounted && request == _readGeneration) {
        setState(() => _loading = false);
      }
    }
  }

  bool _pendingLoaded = false;

  Future<void> _setPeriodic(bool value) async {
    _readGeneration++;
    setState(() {
      _periodic = value;
      _error = null;
      _loading = false;
      _opening = false;
    });
    if (!value || _pendingLoaded) return;
    await _load();
  }

  Future<void> _closeWorkset() async {
    if (_saving || _opening || _hasSubmittedWorkset) return;
    final confirmed = await UtenDialog.show(
      context,
      title: '重新选择编辑产品',
      content: const Text('确定清除当前认料输入并重新选择产品？'),
      confirmLabel: '清除并重新选择',
    );
    if (!mounted || confirmed != true) return;
    setState(() {
      _grid.replaceAll(const []);
      _editorOwner = null;
      _editorDataVersion = null;
      _editorScopeVersion = null;
      _editorCatalogVersion = null;
    });
  }

  Future<void> _openPendingProduct(Map<String, dynamic> row) async {
    final summary = _pendingSummary;
    if (summary == null ||
        _opening ||
        _saving ||
        !_periodic ||
        !_worksetCurrent) {
      return;
    }
    if (_grid.length >= 500) {
      context.appWarning('一次最多认料500个产品；请先在上线准备保存产品认料，再返回开启整批领料');
      return;
    }
    final productId = row['productGoodsId'] as String;
    if (_grid.rows.any((r) => r.product.productGoodsId == productId)) return;
    final owner = captureReadOwner(ref);
    final request = _readGeneration;
    final ids = List<String>.unmodifiable(_pendingWorkshopIds);
    bool current() =>
        mounted &&
        owner() &&
        request == _readGeneration &&
        identical(_pendingSummary, summary) &&
        _periodic;
    setState(() => _opening = true);
    try {
      final result = await readViewActivity.runRead(current, () async {
        final product = await _repo.inProgressPendingProduct(
          ids,
          productId,
          summary: summary,
          isCurrent: current,
        );
        final options = identical(_catalogSummary, summary) && _catalog != null
            ? _catalog!
            : await _repo.inProgressMaterialCatalog(ids, isCurrent: current);
        return (product, options);
      }, slot: 'product');
      if (!mounted || !current()) return;
      final catalogVersion = result.$2.dataVersion ?? result.$2.revision;
      setState(() {
        _catalog = result.$2;
        _catalogSummary = summary;
      });
      if (_editorCatalogVersion != null &&
          _editorCatalogVersion != catalogVersion) {
        context.appWarning('选料目录已变化，原输入保留，请重新核对编辑产品');
        return;
      }
      _editorCatalogVersion ??= catalogVersion;
      final original = result.$1;
      WmMaterialRef named(WmMaterialRef ref) {
        for (final option in result.$2.items) {
          if (option.key == ref.key) return option;
        }
        return ref;
      }

      final product = WmPendingProductChoice(
        productGoodsId: original.productGoodsId,
        productCode: original.productCode,
        productName: original.productName,
        productColorName: original.productColorName,
        taskCount: original.taskCount,
        prefillMaterials: original.prefillMaterials
            .map(named)
            .toList(growable: false),
        prefillSource: original.prefillSource,
        materialOptions: result.$2.items,
        unitWeightGrams: original.unitWeightGrams,
        canAlsoOrderMaterials: original.canAlsoOrderMaterials,
        workshopNames: original.workshopNames,
      );
      _editorOwner ??= owner;
      _editorDataVersion ??= summary.dataVersion ?? summary.revision;
      _editorScopeVersion ??= summary.readScopeVersion;
      setState(() => _grid.addRow(WmPendingChoiceRow(product)));
    } catch (error) {
      if (mounted && current() && !isRetiredViewRead(error)) {
        context.appWarning(
          error is ApiException ? error.message : '读取产品认料候选失败，请重试',
        );
      }
    } finally {
      if (mounted && request == _readGeneration) {
        setState(() => _opening = false);
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
    if (_saving ||
        _opening ||
        _acceptedOwner?.call() != true ||
        !_worksetCurrent) {
      return;
    }
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
    final opened = {for (final row in rows) row.product.productGoodsId};
    final missing = [
      if (periodic)
        for (final product
            in _pendingSummary?.items ?? const <Map<String, dynamic>>[])
          if (!opened.contains(product['productGoodsId']))
            (product['productName'] ??
                    product['productCode'] ??
                    product['productGoodsId'])
                .toString(),
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
    _hasSubmittedWorkset = true;
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
                        UtenCloseButton(
                          key: const Key('wm-bin-panel-close'),
                          tooltip: l10n.commonCancel,
                          onPressed: _saving
                              ? null
                              : () => Navigator.of(context).pop(),
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
                            onPressed:
                                _saving ||
                                    _loading ||
                                    _opening ||
                                    !_worksetCurrent ||
                                    _acceptedOwner?.call() != true
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
          if (_opening && !_saving) const UtenBusyOverlay(title: '正在读取产品认料'),
          if (_loading && !_opening && !_saving)
            const UtenBusyOverlay(title: '正在读取开通清单'),
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
          child: Row(
            children: [
              Expanded(
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
              UtenFieldHintIcon(info: l10n.wmBinSourceHint, dense: true),
            ],
          ),
        ),
        if (widget.mode == WmBinPanelMode.source)
          Row(
            children: [
              Expanded(
                child: SwitchListTile(
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
                ),
              ),
              UtenFieldHintIcon(
                info: l10n.wmBinSourceFollowOwningHint,
                dense: true,
              ),
            ],
          ),
        if (_choosesPeriodic && widget.mode == WmBinPanelMode.open) ...[
          const SizedBox(height: UtenSpacing.s8),
          Row(
            children: [
              Expanded(
                child: SwitchListTile(
                  key: const Key('wm-bin-panel-periodic'),
                  contentPadding: EdgeInsets.zero,
                  value: _periodic,
                  onChanged: _saving ? null : _setPeriodic,
                  title: Text(l10n.wmBinAlsoPeriodic),
                ),
              ),
              UtenFieldHintIcon(info: l10n.wmBinAlsoPeriodicHint, dense: true),
            ],
          ),
        ],
        if (periodic) ...[
          const SizedBox(height: UtenSpacing.s12),
          Row(
            children: [
              Flexible(
                child: SizedBox(
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
              ),
              UtenFieldHintIcon(
                key: const Key('wm-enable-flow-notice'),
                info: l10n.wmBinPeriodicFlowNotice,
                dense: true,
              ),
            ],
          ),
          const SizedBox(height: UtenSpacing.s16),
          Text(
            (_pendingSummary?.items.isEmpty ?? true)
                ? l10n.wmBinPendingNone
                : l10n.wmBinPendingTitle(_pendingSummary!.items.length),
            style: theme.textTheme.titleSmall,
          ),
          SizedBox(
            height: 320,
            child: WmProductSummaryTable(
              key: const Key('wm-enable-complete-summary'),
              tableKey: 'workshop.material.enable.complete-summary',
              items: _pendingSummary?.items ?? const [],
              openedIds: {
                if (_worksetCurrent)
                  for (final row in _grid.rows) row.product.productGoodsId,
              },
              onOpen: _openPendingProduct,
              onRetry: _load,
              pending: true,
              enabled: !_opening && !_saving && _worksetCurrent,
            ),
          ),
          if (!_grid.isEmpty)
            Row(
              children: [
                const Text('已打开的认料明细'),
                UtenFieldHintIcon(
                  info: _worksetCurrent
                      ? '认料输入保留；尚未打开的产品仍参与整批领料资格校验，一次最多500个产品。'
                      : '读取身份或数据版本已变化，原输入保留，须重新核对后才能提交。',
                ),
                UtenButton(
                  type: UtenButtonType.secondary,
                  onPressed: !_saving && !_opening && !_hasSubmittedWorkset
                      ? _closeWorkset
                      : null,
                  child: const Text('重新选择编辑产品'),
                ),
              ],
            ),
          if (!_grid.isEmpty && _worksetOwnerCurrent) ...[
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
          enabled: !_saving && _worksetCurrent,
          autofilled: row.prefilled,
          value: value,
          hintText: l10n.wmBinColMaterial,
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
                onChanged: _saving || !_worksetCurrent
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
