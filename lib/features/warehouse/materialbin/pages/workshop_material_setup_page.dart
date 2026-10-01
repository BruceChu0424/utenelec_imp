// 车间内料仓设置 (/warehouse/workshop-material/setup, ADR-131 §5.1 / §8.1)。
//
// 三个页签:
// - 车间开启: 每个车间一行, 开启整批领料 (选主仓、启用日, 在产产品一次认完料) /
//   停用 (只用来撤销设错的开启; 内料仓已经在用时服务端拒绝)。
// - 机台与容器: 批量新增、勾选多行改一格批量生效、停用、删除。
// - 上线准备: 产品的颗粒与塑料单个重量 (克)。
// 按钮只看服务端下发的 allowedActions (开启 / 停用需 SETUP)。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:uuid/uuid.dart';

import '../../../../components/buttons/uten_back_button.dart';
import '../../../../components/buttons/uten_button.dart';
import '../../../../components/feedback/uten_busy_overlay.dart';
import '../../../../components/feedback/uten_dialog.dart';
import '../../../../components/feedback/uten_empty.dart';
import '../../../../components/feedback/uten_inline_notice.dart';
import '../../../../components/inputs/uten_dropdown_field.dart';
import '../../../../components/layout/uten_app_bar.dart';
import '../../../../components/layout/uten_content_container.dart';
import '../../../../components/layout/uten_filter_toolbar.dart';
import '../../../../core/l10n/gen/app_localizations.dart';
import '../../../../core/network/api_exception.dart';
import '../../../../core/router/nav_helpers.dart';
import '../../../../core/router/page_resume_provider.dart';
import '../../../../core/router/route_access_policy.dart';
import '../../../../core/router/route_names.dart';
import '../../../../core/theme/uten_tokens.dart';
import '../../../../core/ui/app_notification.dart';
import '../../../../shared/auth/permissions.dart';
import '../../../basic_data/widgets/master_data_table_view.dart';
import '../models/workshop_material_models.dart';
import '../repositories/workshop_material_repository.dart';
import '../widgets/workshop_material_enable_dialog.dart';
import '../widgets/workshop_material_labels.dart';
import '../widgets/workshop_material_machines_tab.dart';
import '../widgets/workshop_material_prep_tab.dart';

class WorkshopMaterialSetupPage extends ConsumerStatefulWidget {
  const WorkshopMaterialSetupPage({
    super.key,
    this.initialTab,
    this.initialWorkshopId,
  });

  /// `enable` / `machines` / `prep`; 为空时进"车间开启"。
  final String? initialTab;

  /// 从工单或内料仓深链进入时保持目标车间；不可见时不自动改成其它车间。
  final String? initialWorkshopId;

  @override
  ConsumerState<WorkshopMaterialSetupPage> createState() =>
      _WorkshopMaterialSetupPageState();
}

class _WorkshopMaterialSetupPageState
    extends ConsumerState<WorkshopMaterialSetupPage> {
  static const tabEnable = 'enable';
  static const tabMachines = 'machines';
  static const tabPrep = 'prep';

  final _nonce = const Uuid().v4();
  late String _tab =
      const {tabEnable, tabMachines, tabPrep}.contains(widget.initialTab)
      ? widget.initialTab!
      : tabEnable;
  List<WmSetting>? _settings;
  String? _workshopId;
  bool _loading = true;
  String? _error;
  String? _busyTitle;
  String? _myLocation;

  WorkshopMaterialRepository get _repo =>
      ref.read(workshopMaterialRepositoryProvider);

  WmSetting? get _current {
    for (final s in _settings ?? const <WmSetting>[]) {
      if (s.workshopDepartmentId == _workshopId) return s;
    }
    return null;
  }

  @override
  void initState() {
    super.initState();
    _workshopId = widget.initialWorkshopId;
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final settings = await _repo.settings();
      if (!mounted) return;
      setState(() {
        _settings = settings;
        _workshopId ??= settings.isEmpty
            ? null
            : settings.first.workshopDepartmentId;
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
          _error = '加载失败, 请重试';
        });
      }
    }
  }

  Future<void> _enable(WmSetting setting) async {
    final saved = await showWorkshopMaterialEnableDialog(
      context,
      setting: setting,
    );
    if (saved != null && mounted) {
      setState(() => _workshopId = saved.workshopDepartmentId);
      await _load();
    }
  }

  Future<void> _disable(WmSetting setting) async {
    final ok = await UtenDialog.show(
      context,
      title: '停用 ${setting.workshopName} 的整批领料',
      content: const Text(
        '停用只用来撤销设错的开启: 内料仓从来没进过料、没有在产任务接上时才能停用。'
        '已经在用的内料仓不能停用。',
      ),
      confirmLabel: '停用',
      danger: true,
    );
    if (ok != true || !mounted) return;
    setState(() => _busyTitle = '正在停用');
    try {
      await _repo.saveSetting(
        setting.workshopDepartmentId,
        expectedVersion: setting.rowVersion,
        enabled: false,
        mainWarehouseId: setting.mainWarehouseId,
        goLiveDate: setting.goLiveDate,
        idempotencyKey: wmIdempotencyKey('disable', _nonce, {
          'workshop': setting.workshopDepartmentId,
          'v': setting.rowVersion,
        }),
      );
      if (!mounted) return;
      setState(() => _busyTitle = null);
      await WidgetsBinding.instance.endOfFrame;
      if (!mounted) return;
      context.appSuccess('已停用 ${setting.workshopName} 的整批领料');
      await _load();
    } on ApiException catch (e) {
      if (mounted) {
        setState(() => _busyTitle = null);
        context.appWarning(e.message);
      }
    } catch (_) {
      if (mounted) {
        setState(() => _busyTitle = null);
        context.appWarning('网络不稳定, 请刷新看看是否已停用');
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    _myLocation ??= currentLocationOr(context, RouteName.workshopMaterialSetup);
    ref.onPageResume(_myLocation!, _load);
    return Scaffold(
      appBar: UtenAppBar(
        title: l10n.workshopMaterialSetup,
        leading: UtenBackButton(
          onPressed: () => backTo(context, defaultPath: RouteName.warehouse),
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh_rounded),
            tooltip: '刷新',
            onPressed: () {
              setState(() => _busyTitle = null);
              _load();
            },
          ),
        ],
      ),
      body: SafeArea(
        child: Stack(
          children: [
            UtenContentContainer.wide(
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: UtenSpacing.s12),
                child: _body(l10n),
              ),
            ),
            if (_busyTitle != null) UtenBusyOverlay(title: _busyTitle!),
          ],
        ),
      ),
    );
  }

  Widget _body(AppLocalizations l10n) {
    if (_loading && _settings == null) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null && _settings == null) {
      return UtenEmpty.error(
        message: _error,
        actionLabel: '重试',
        onAction: _load,
      );
    }
    final settings = _settings ?? const <WmSetting>[];
    final current = _current;
    if (_workshopId != null && current == null) {
      return UtenEmpty(
        message: '指定车间当前不可用或无权查看',
        description: '请返回原任务核对车间，或刷新后重试。',
        actionLabel: '重试',
        onAction: _load,
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: UtenSpacing.s4),
          child: UtenFilterToolbar<String>(
            segmentsKey: const Key('wm-setup-tabs'),
            segments: [
              UtenFilterSegment(
                value: tabEnable,
                label: l10n.wmEnableWorkshopTab,
              ),
              UtenFilterSegment(value: tabMachines, label: l10n.wmMachines),
              UtenFilterSegment(value: tabPrep, label: l10n.wmGoLivePrep),
            ],
            selected: {_tab},
            onSelectionChanged: (value) => setState(() => _tab = value),
          ),
        ),
        const SizedBox(height: UtenSpacing.s8),
        if (_tab == tabEnable) ...[
          const UtenInlineNotice(
            key: Key('wm-setup-flow-guide'),
            title: '首次认料即可开工，补料按车间办理',
            message:
                '开启对应车间后，申请直接选择原料和数量；首次使用的原料由仓库发料时在同页确认用途。'
                '产品第一次只确认用哪种料，不必按工单领料；进行中的任务可随时申请整批补料。'
                '上线前清点车间已有余料，核对原库存归属后登记，避免重复计入。',
          ),
          const SizedBox(height: UtenSpacing.s8),
          Wrap(
            spacing: UtenSpacing.s8,
            runSpacing: UtenSpacing.s8,
            children: [
              if (locationAllowedFor(
                ref.watch(currentPermissionsProvider),
                ref.watch(isSuperAdminProvider),
                RouteName.basicinfoGoods,
              ))
                UtenButton(
                  key: const Key('wm-setup-material-settings'),
                  type: UtenButtonType.ghost,
                  size: UtenButtonSize.small,
                  onPressed: () async {
                    await context.push(RouteName.basicinfoGoods);
                    if (mounted) await _load();
                  },
                  child: const Text('原材料发料方式'),
                ),
              UtenButton(
                key: const Key('wm-setup-opening-guide'),
                type: UtenButtonType.ghost,
                size: UtenButtonSize.small,
                onPressed: _showOpeningGuide,
                child: const Text('上线余料怎么登记'),
              ),
            ],
          ),
          const SizedBox(height: UtenSpacing.s8),
        ],
        if (_tab != tabEnable && settings.isNotEmpty) ...[
          Align(
            alignment: Alignment.centerLeft,
            child: SizedBox(
              width: 320,
              child: UtenDropdownField(
                key: const Key('wm-setup-workshop'),
                label: '车间',
                allowClear: false,
                value: _workshopId,
                items: [
                  for (final s in settings)
                    UtenDropdownItem(
                      value: s.workshopDepartmentId,
                      label: s.periodicEnabled
                          ? s.workshopName
                          : '${s.workshopName} (未开启)',
                    ),
                ],
                onChanged: (v) => setState(() => _workshopId = v),
              ),
            ),
          ),
          const SizedBox(height: UtenSpacing.s8),
        ],
        Expanded(child: _tabBody(l10n, settings, current)),
      ],
    );
  }

  Widget _tabBody(
    AppLocalizations l10n,
    List<WmSetting> settings,
    WmSetting? current,
  ) {
    if (settings.isEmpty) {
      return const UtenEmpty(
        message: '没有找到生产车间',
        description: '车间是生产部下面的部门; 请先在部门管理里建好车间',
      );
    }
    if (_tab == tabEnable) {
      return _enableTable(
        l10n,
        widget.initialWorkshopId == null ? settings : [current!],
      );
    }
    if (current == null) return const UtenEmpty(message: '请先选车间');
    if (_tab == tabMachines) {
      return WmMachinesTab(
        key: ValueKey('machines-${current.workshopDepartmentId}'),
        workshopId: current.workshopDepartmentId,
        workshopName: current.workshopName,
      );
    }
    return WmPrepTab(
      key: ValueKey('prep-${current.workshopDepartmentId}'),
      workshopId: current.workshopDepartmentId,
    );
  }

  Widget _enableTable(AppLocalizations l10n, List<WmSetting> settings) {
    return MasterDataTableView<WmSetting>(
      tableKey:
          'features.warehouse.materialbin.pages.workshop_material_setup_page.WorkshopMaterialSetupPageState._enableTable.1',
      key: const Key('wm-setup-enable-table'),
      columns: [
        MasterColumnDef(
          key: 'workshop',
          label: '车间',
          width: 160,
          value: (s) => s.workshopName,
        ),
        MasterColumnDef(
          key: 'enabled',
          label: '整批领料',
          width: 100,
          value: (s) => s.periodicEnabled ? '已开启' : '未开启',
        ),
        MasterColumnDef(
          key: 'bin',
          label: '内料仓',
          width: 180,
          value: (s) => s.binWarehouseName,
        ),
        MasterColumnDef(
          key: 'main',
          label: l10n.wmMainWarehouse,
          width: 160,
          value: (s) => s.mainWarehouseName,
        ),
        MasterColumnDef(
          key: 'goLive',
          label: l10n.wmGoLiveDate,
          width: 120,
          value: (s) => s.goLiveDate,
        ),
        MasterColumnDef(
          key: 'period',
          label: '本期',
          width: 240,
          value: (s) => s.currentPeriod == null
              ? null
              : '${wmPeriodLabel(s.currentPeriod!)} · ${wmPeriodStatusLabel(s.currentPeriod!.status)}',
        ),
        MasterColumnDef(
          key: 'action',
          label: '操作',
          width: 170,
          value: (s) => s.periodicEnabled ? '停用' : l10n.wmEnable,
          cellBuilderHandlesSemantics: true,
          cellBuilder: (context, s) {
            if (!s.can(WmAction.setup)) return const SizedBox.shrink();
            return s.periodicEnabled
                ? UtenButton(
                    key: Key('wm-setup-disable-${s.workshopDepartmentId}'),
                    type: UtenButtonType.ghost,
                    size: UtenButtonSize.small,
                    onPressed: _busyTitle == null ? () => _disable(s) : null,
                    child: const Text('停用'),
                  )
                : UtenButton(
                    key: Key('wm-setup-enable-${s.workshopDepartmentId}'),
                    size: UtenButtonSize.small,
                    onPressed: _busyTitle == null ? () => _enable(s) : null,
                    child: Text(l10n.wmEnable),
                  );
          },
        ),
      ],
      items: settings,
      facets: const {},
      nullCounts: const {},
      filters: const {},
      onFilterChanged: (_, _) {},
      rowKeyOf: (s) => s.workshopDepartmentId,
      isLoading: _loading && _settings == null,
      emptyMessage: '没有找到生产车间',
    );
  }

  Future<void> _showOpeningGuide() async {
    await UtenDialog.show(
      context,
      title: '上线前清点车间余料',
      content: const Text(
        '先记录料架整袋、开口袋、搅拌待用料和机台容器余料；称重与容器估算分别记录。\n\n'
        '已有库存账的余料：核对原仓库和工单。已按工单发出的先按原流程退料清账；'
        '仍在普通仓库账上的，由仓库整批调入车间内料仓。\n\n'
        '从未入账的余料：经核定数量和金额后办理其它入库，再整批调入内料仓，'
        '不要同时新增一份库存或把历史已用掉的料再记入。\n\n'
        '这是上线库存衔接，不要求生产员工为每张工单重新领料。'
        '后续按实际交接登记补料、退回，按需要盘点；机桶估算会影响耗用差异，不能当作精确实耗。',
      ),
      confirmLabel: '知道了',
    );
  }
}
