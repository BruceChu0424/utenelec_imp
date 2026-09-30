// 开启车间整批领料对话框 (ADR-131 §5.1 第 3 条)。
//
// 选主仓 (在该主仓下取得或建出"{车间}内料仓")、启用日; 本车间正在生产、还没认料的
// 产品在同一对话框里一次选完 (用哪种料, 或"本产品不用车间内料仓的料"), 所以开启后
// 不存在"在产却没认料"的任务。没有任何 BOM 的产品可勾"还要按工单领别的料 (例如嵌件)"。
// 一个原子命令: 写设置、建第 1 期、在产任务当场绑定。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../../../../components/buttons/uten_button.dart';
import '../../../../components/feedback/uten_busy_overlay.dart';
import '../../../../components/inputs/uten_date_field.dart';
import '../../../../components/inputs/uten_dropdown_field.dart';
import '../../../../core/l10n/gen/app_localizations.dart';
import '../../../../core/network/api_exception.dart';
import '../../../../core/theme/uten_tokens.dart';
import '../../../../core/ui/app_notification.dart';
import '../../../../core/utils/china_datetime.dart';
import '../../../basic_data/models/warehouse_node.dart';
import '../../../basic_data/repositories/warehouse_repository.dart';
import '../models/workshop_material_models.dart';
import '../repositories/workshop_material_repository.dart';
import 'workshop_material_labels.dart';

/// "本产品不用车间内料仓的料"在下拉里的取值。
const _kNone = '__NONE__';

/// 打开开启对话框; 成功返回开启后的设置。
Future<WmSetting?> showWorkshopMaterialEnableDialog(
  BuildContext context, {
  required WmSetting setting,
}) => showDialog<WmSetting>(
  context: context,
  barrierDismissible: false,
  builder: (_) => WorkshopMaterialEnableDialog(setting: setting),
);

class WorkshopMaterialEnableDialog extends ConsumerStatefulWidget {
  const WorkshopMaterialEnableDialog({super.key, required this.setting});

  final WmSetting setting;

  @override
  ConsumerState<WorkshopMaterialEnableDialog> createState() =>
      _WorkshopMaterialEnableDialogState();
}

class _WorkshopMaterialEnableDialogState
    extends ConsumerState<WorkshopMaterialEnableDialog> {
  final _nonce = const Uuid().v4();
  bool _loading = true;
  String? _loadError;
  List<WarehouseListItem> _mainWarehouses = const [];
  List<WmPendingProductChoice> _pending = const [];
  String? _mainWarehouseId;
  DateTime _goLive = ChinaDateTime.today();

  /// 产品 id → 选的料 (货品|颜色) 或 [_kNone]。
  final Map<String, String?> _choice = {};
  final Map<String, bool> _alsoOrder = {};
  bool _saving = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _mainWarehouseId = widget.setting.mainWarehouseId;
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _loadError = null;
    });
    try {
      final results = await Future.wait<Object>([
        ref.read(warehouseRepositoryProvider).dict(),
        ref
            .read(workshopMaterialRepositoryProvider)
            .inProgressPending(widget.setting.workshopDepartmentId),
      ]);
      if (!mounted) return;
      final warehouses = results[0] as List<WarehouseListItem>;
      final pending = results[1] as List<WmPendingProductChoice>;
      setState(() {
        // 主仓 = 顶层、参与核算、不是内料仓的仓库。
        _mainWarehouses = [
          for (final w in warehouses)
            if (w.parentId == null && !w.lineSide && w.accountable) w,
        ];
        _pending = pending;
        for (final p in pending) {
          _choice[p.productGoodsId] = p.prefillMaterials.isEmpty
              ? null
              : p.prefillMaterials.first.key;
          _alsoOrder[p.productGoodsId] = false;
        }
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
          _loadError = '加载失败, 请重试';
        });
      }
    }
  }

  WmMaterialRef? _refFor(WmPendingProductChoice p, String key) {
    for (final m in [...p.materialOptions, ...p.prefillMaterials]) {
      if (m.key == key) return m;
    }
    return null;
  }

  Future<void> _submit() async {
    if (_mainWarehouseId == null) {
      setState(() => _error = '请选择放在哪个主仓下');
      return;
    }
    final missing = [
      for (final p in _pending)
        if (_choice[p.productGoodsId] == null) p.productDisplay,
    ];
    if (missing.isNotEmpty) {
      setState(
        () => _error =
            '还有 ${missing.length} 个在产产品没选料: ${missing.take(5).join('、')}',
      );
      return;
    }
    final choices = [
      for (final p in _pending)
        _choice[p.productGoodsId] == _kNone
            ? WmProductChoiceInput(
                productGoodsId: p.productGoodsId,
                kind: 'NONE',
              )
            : WmProductChoiceInput(
                productGoodsId: p.productGoodsId,
                kind: 'MATERIAL',
                materials: [?_refFor(p, _choice[p.productGoodsId]!)],
                alsoOrderMaterials:
                    p.canAlsoOrderMaterials &&
                    (_alsoOrder[p.productGoodsId] ?? false),
                prefillSource:
                    p.prefillMaterials.any(
                      (m) => m.key == _choice[p.productGoodsId],
                    )
                    ? p.prefillSource
                    : null,
              ),
    ];
    final goLive = ChinaDateTime.formatDate(_goLive);
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final saved = await ref
          .read(workshopMaterialRepositoryProvider)
          .saveSetting(
            widget.setting.workshopDepartmentId,
            expectedVersion: widget.setting.rowVersion,
            enabled: true,
            mainWarehouseId: _mainWarehouseId,
            goLiveDate: goLive,
            inProgressChoices: choices,
            idempotencyKey: wmIdempotencyKey('enable', _nonce, {
              'workshop': widget.setting.workshopDepartmentId,
              'v': widget.setting.rowVersion,
              'main': _mainWarehouseId,
              'goLive': goLive,
              'choices': [for (final c in choices) c.toJson()],
            }),
          );
      if (!mounted) return;
      setState(() => _saving = false);
      await WidgetsBinding.instance.endOfFrame;
      if (!mounted) return;
      context.appSuccess(
        '已开启 ${widget.setting.workshopName} 的整批领料'
        '${saved.binWarehouseName == null ? '' : ', 内料仓: ${saved.binWarehouseName}'}',
      );
      Navigator.of(context).pop(saved);
    } on ApiException catch (e) {
      if (mounted) {
        setState(() {
          _saving = false;
          _error = e.message;
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _saving = false;
          _error = '网络不稳定, 暂时没确认结果。选择已保留, 请再点一次 (不会重复开启)。';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    return PopScope(
      canPop: !_saving,
      child: Stack(
        children: [
          AlertDialog(
            title: Text('${l10n.wmEnable}: ${widget.setting.workshopName}'),
            content: SizedBox(
              width: 720,
              child: _loading
                  ? const SizedBox(
                      height: 160,
                      child: Center(child: CircularProgressIndicator()),
                    )
                  : _loadError != null
                  ? Text(
                      _loadError!,
                      style: TextStyle(color: theme.colorScheme.error),
                    )
                  : SingleChildScrollView(child: _form(l10n, theme)),
            ),
            actionsAlignment: MainAxisAlignment.center,
            actions: [
              UtenButton(
                type: UtenButtonType.ghost,
                onPressed: _saving ? null : () => Navigator.of(context).pop(),
                child: const Text('取消'),
              ),
              if (_loadError != null)
                UtenButton(onPressed: _load, child: const Text('重试'))
              else
                UtenButton(
                  key: const Key('wm-enable-submit'),
                  isLoading: _saving,
                  onPressed: _saving || _loading ? null : _submit,
                  child: Text(l10n.wmEnable),
                ),
            ],
          ),
          if (_saving)
            const UtenBusyOverlay(
              title: '正在开启整批领料',
              description: '正在建内料仓、第 1 期, 并把在产任务接上',
            ),
        ],
      ),
    );
  }

  Widget _form(AppLocalizations l10n, ThemeData theme) {
    final today = ChinaDateTime.today();
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          '开启时内料仓必须是空的; 启用日当天由仓库把要用的料"${l10n.wmDirectIssue}"进内料仓。',
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: UtenSpacing.s12),
        Wrap(
          spacing: UtenSpacing.s12,
          runSpacing: UtenSpacing.s12,
          children: [
            SizedBox(
              width: 300,
              child: UtenDropdownField(
                key: const Key('wm-enable-main-warehouse'),
                label: l10n.wmMainWarehouse,
                required: true,
                allowClear: false,
                enabled: !_saving,
                value: _mainWarehouseId,
                items: [
                  for (final w in _mainWarehouses)
                    UtenDropdownItem(
                      value: w.id,
                      label: w.name ?? w.code ?? '',
                    ),
                ],
                onChanged: (v) => setState(() => _mainWarehouseId = v),
              ),
            ),
            SizedBox(
              width: 220,
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
          ],
        ),
        const SizedBox(height: UtenSpacing.s16),
        Text(
          _pending.isEmpty
              ? '本车间现在没有需要认料的在产任务。'
              : '本车间正在生产、还没认料的产品 (${_pending.length} 个), 请一次选完:',
          style: theme.textTheme.titleSmall,
        ),
        for (final p in _pending) ...[
          const SizedBox(height: UtenSpacing.s8),
          _productRow(l10n, theme, p),
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

  Widget _productRow(
    AppLocalizations l10n,
    ThemeData theme,
    WmPendingProductChoice p,
  ) {
    final choice = _choice[p.productGoodsId];
    final options = <WmMaterialRef>[
      ...p.materialOptions,
      for (final m in p.prefillMaterials)
        if (!p.materialOptions.any((o) => o.key == m.key)) m,
    ];
    final prefilled =
        choice != null && p.prefillMaterials.any((m) => m.key == choice);
    return Container(
      padding: const EdgeInsets.all(UtenSpacing.s8),
      decoration: BoxDecoration(
        borderRadius: UtenRadius.mdAll,
        border: Border.all(color: theme.colorScheme.outlineVariant),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // 2026-09-29 用户口径：主行只显名称，颜色/任务数/单重进副行。
          Text(
            p.productDisplay,
            style: theme.textTheme.bodyMedium?.copyWith(
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: UtenSpacing.s2),
          Text(
            [
              if (p.productSubline != null) p.productSubline!,
              '本次 ${p.taskCount} 个任务',
              if (p.unitWeightGrams != null)
                '单个重量 ${wmQty(p.unitWeightGrams)} 克',
            ].join(' · '),
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: UtenSpacing.s6),
          UtenDropdownField(
            key: Key('wm-enable-choice-${p.productGoodsId}'),
            dense: true,
            required: true,
            allowClear: false,
            enabled: !_saving,
            autofilled: prefilled,
            value: choice,
            hintText: '选这个产品用的料',
            items: [
              for (final m in options)
                UtenDropdownItem(value: m.key, label: m.displayName),
              UtenDropdownItem(value: _kNone, label: l10n.wmNotFromStore),
            ],
            onChanged: (v) => setState(() => _choice[p.productGoodsId] = v),
          ),
          if (prefilled && p.prefillSource == 'LEGACY_MATERIAL_TEXT')
            Padding(
              padding: const EdgeInsets.only(top: UtenSpacing.s4),
              child: Text(
                '已按老库材质预填, 请核对',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ),
          if (p.canAlsoOrderMaterials && choice != null && choice != _kNone)
            CheckboxListTile(
              key: Key('wm-enable-also-order-${p.productGoodsId}'),
              dense: true,
              contentPadding: EdgeInsets.zero,
              controlAffinity: ListTileControlAffinity.leading,
              value: _alsoOrder[p.productGoodsId] ?? false,
              onChanged: _saving
                  ? null
                  : (v) => setState(
                      () => _alsoOrder[p.productGoodsId] = v ?? false,
                    ),
              title: Text(l10n.wmAlsoOrderMaterials),
            ),
        ],
      ),
    );
  }
}
