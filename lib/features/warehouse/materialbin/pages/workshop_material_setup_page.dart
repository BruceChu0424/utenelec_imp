// 车间内料仓设置 (/warehouse/workshop-material/setup, ADR-131 §5.1 / §8.1; ADR-147 起只剩两个页签)。
//
// 开通内料仓、开启整批领料、改发料来源仓、撤销都在内料仓总览 (唯一的车间清单) 里批量办;
// 这里只做两件事:
// - 机台与容器: 批量新增、勾选多行改一格批量生效、停用、删除;
// - 上线准备: 产品的颗粒与塑料单个重量 (克)。
// 车间切换用与总览同一份车间清单 (GET /workshop-material/settings); 动作在右下悬浮按钮组。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../../components/buttons/uten_back_button.dart';
import '../../../../components/buttons/uten_button.dart';
import '../../../../components/feedback/uten_dialog.dart';
import '../../../../components/feedback/uten_empty.dart';
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
import '../../../../shared/auth/permissions.dart';
import '../models/workshop_material_models.dart';
import '../repositories/workshop_material_repository.dart';
import '../widgets/workshop_material_machines_tab.dart';
import '../widgets/workshop_material_prep_tab.dart';

class WorkshopMaterialSetupPage extends ConsumerStatefulWidget {
  const WorkshopMaterialSetupPage({
    super.key,
    this.initialTab,
    this.initialWorkshopId,
  });

  /// `machines` / `prep`; 为空时进"机台与容器"。
  final String? initialTab;

  /// 从工单或内料仓深链进入时保持目标车间；不可见时不自动改成其它车间。
  final String? initialWorkshopId;

  @override
  ConsumerState<WorkshopMaterialSetupPage> createState() =>
      _WorkshopMaterialSetupPageState();
}

class _WorkshopMaterialSetupPageState
    extends ConsumerState<WorkshopMaterialSetupPage> {
  static const tabMachines = 'machines';
  static const tabPrep = 'prep';

  late String _tab = widget.initialTab == tabPrep ? tabPrep : tabMachines;
  List<WmSetting>? _settings;
  String? _workshopId;
  bool _loading = true;
  String? _error;
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
          _error = AppLocalizations.of(context).wmBinLoadFailed;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final permissions = ref.watch(currentPermissionsProvider);
    final isSuperAdmin = ref.watch(isSuperAdminProvider);
    final canPrepare =
        isSuperAdmin ||
        (permissions.contains(Perm.workshopMaterialSetup) &&
            permissions.contains(Perm.goodsView));
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
            tooltip: l10n.commonRefresh,
            onPressed: _load,
          ),
        ],
      ),
      body: SafeArea(
        child: UtenContentContainer.wide(
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: UtenSpacing.s12),
            child: _body(l10n, canPrepare: canPrepare),
          ),
        ),
      ),
    );
  }

  Widget _body(AppLocalizations l10n, {required bool canPrepare}) {
    if (_loading && _settings == null) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null && _settings == null) {
      return UtenEmpty.error(
        message: _error,
        actionLabel: l10n.commonRetry,
        onAction: _load,
      );
    }
    final settings = _settings ?? const <WmSetting>[];
    if (settings.isEmpty) {
      return UtenEmpty(
        message: l10n.wmSetupNoWorkshop,
        description: l10n.wmSetupNoWorkshopHint,
      );
    }
    final current = _current;
    // 深链和会话撤权也走同一门控，不能只把页签藏起来后继续请求货品资料。
    final tab = _tab == tabPrep && !canPrepare ? tabMachines : _tab;
    if (current == null) {
      return UtenEmpty(
        message: l10n.wmSetupWorkshopUnavailable,
        description: l10n.wmSetupWorkshopUnavailableHint,
        actionLabel: l10n.commonRetry,
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
              UtenFilterSegment(value: tabMachines, label: l10n.wmMachines),
              if (canPrepare)
                UtenFilterSegment(value: tabPrep, label: l10n.wmGoLivePrep),
            ],
            selected: {tab},
            onSelectionChanged: (value) {
              if (value == tabPrep && !canPrepare) return;
              setState(() => _tab = value);
            },
          ),
        ),
        const SizedBox(height: UtenSpacing.s8),
        // 车间与内料仓总览同一份清单。
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: UtenSpacing.s4),
          child: UtenFilterToolbar<String>(
            segmentsKey: const Key('wm-setup-workshop'),
            segments: [
              for (final s in settings)
                UtenFilterSegment(
                  value: s.workshopDepartmentId,
                  label: s.workshopName,
                ),
            ],
            selected: {current.workshopDepartmentId},
            onSelectionChanged: (value) => setState(() => _workshopId = value),
          ),
        ),
        if (tab == tabPrep) ...[
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
                  child: Text(l10n.wmSetupMaterialIssueMethod),
                ),
              UtenButton(
                key: const Key('wm-setup-opening-guide'),
                type: UtenButtonType.ghost,
                size: UtenButtonSize.small,
                onPressed: () => _showOpeningGuide(l10n),
                child: Text(l10n.wmSetupOpeningGuide),
              ),
            ],
          ),
        ],
        const SizedBox(height: UtenSpacing.s8),
        Expanded(
          child: tab == tabMachines
              ? WmMachinesTab(
                  key: ValueKey('machines-${current.workshopDepartmentId}'),
                  workshopId: current.workshopDepartmentId,
                  workshopName: current.workshopName,
                )
              : WmPrepTab(
                  key: ValueKey('prep-${current.workshopDepartmentId}'),
                  workshopId: current.workshopDepartmentId,
                ),
        ),
      ],
    );
  }

  Future<void> _showOpeningGuide(AppLocalizations l10n) async {
    await UtenDialog.show(
      context,
      title: l10n.wmSetupOpeningGuideTitle,
      content: Text(l10n.wmSetupOpeningGuideBody),
      confirmLabel: l10n.wmSetupOpeningGuideOk,
    );
  }
}
