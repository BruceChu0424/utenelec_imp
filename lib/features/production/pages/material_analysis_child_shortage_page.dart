part of 'production_material_analysis_page.dart';

/// 「补下层物料」页(ADR-117)：把刚下单的件下面还缺的料都列出来，数量已按缺口填好，
/// 一键下单。
///
/// 这一页**没有自己的一套数据**：输入框、车间 / 负责人、供应方式、勾选之外的一切都是
/// 主表那一份([_MaterialAnalysisMaterialTableState])，提交走同一个
/// [_MaterialAnalysisMaterialTableState._submitMaterialTableRows]——父先子后分段、失败
/// 即停、成功后「下单数量」锁成累计已下单量、「追加下单」回 0。所以回到主表时，下单
/// 数量、追加、还缺数量已经是新的，不会出现两处数字对不上。
///
/// 一轮下完如果更深一层又缺了(比如刚给自制子件排了计划，它的原料就要跟着备)，本页
/// 按最新快照自动列出下一层，不用退出重进；全部补齐后显示「都下够了」。
class _ChildShortageFillPage extends StatefulWidget {
  const _ChildShortageFillPage({
    required this.host,
    this.rootKeys,
    this.orderedQty = const {},
    this.appendedKeys = const {},
  });

  final _MaterialAnalysisChildShortageState host;

  /// 从下单后弹窗进来：刚下单的那几件；null = 从提示条进来(所有已下单的件)。
  final Set<String>? rootKeys;
  final Map<String, double> orderedQty;
  final Set<String> appendedKeys;

  @override
  State<_ChildShortageFillPage> createState() => _ChildShortageFillPageState();
}

class _ChildShortageFillPageState extends State<_ChildShortageFillPage> {
  /// 用户亲手撤掉勾的行(其余能下单的行默认都勾着)。
  final Set<String> _deselected = {};
  bool _submitting = false;

  /// 本页已经成功下过几轮：用来区分「一进来就没有缺的」与「补完了」。
  int _rounds = 0;

  _MaterialAnalysisChildShortageState get _host => widget.host;

  late final Listenable _hostChanges = Listenable.merge([
    _host._childShortageRevision,
    _host.materialDetailRevision,
    _host._tableEstimateTick,
  ]);

  /// 缺哪些料只随分析快照与宿主状态(路线草稿等)变；敲数量只刷新格子里的估算，
  /// 不必每敲一个键把整棵 BOM 重走一遍(大分析上会卡)。
  ProductionMaterialAnalysisView? _rootsAnalysis;
  int _rootsRevision = -1;
  List<_ChildShortageRoot> _rootsCache = const [];

  List<_ChildShortageRoot> _roots() {
    final analysis = _host._analysis;
    final revision = _host._childShortageRevision.value;
    if (!identical(analysis, _rootsAnalysis) || revision != _rootsRevision) {
      _rootsAnalysis = analysis;
      _rootsRevision = revision;
      _rootsCache = _host._childShortageRoots(
        rootKeys: widget.rootKeys,
        orderedQty: widget.orderedQty,
        appendedKeys: widget.appendedKeys,
      );
    }
    return _rootsCache;
  }

  _MaterialTableRow _rowOf(_ChildShortageLine line) => _MaterialTableRow(
    kind: _MaterialTableRowKind.material,
    key: 'CHILD_SHORTAGE|${line.group.key}',
    sequence: '',
    depth: line.depth,
    material: line.material,
    group: line.group,
  );

  /// 勾选框的状态：没被撤勾、而且能下单。
  bool _checked(_ChildShortageLine line) =>
      !_deselected.contains(line.group.key) &&
      _host._tableIssueBlockedReason(line.group) == null;

  /// 算进「一键下单(N)」的行：勾着，而且填的数大于 0(清空的行不下)。
  bool _selected(_ChildShortageLine line) =>
      _checked(line) && _host._tableSubmitQtyOf(line.group) > 0.0001;

  Future<void> _submit(List<_ChildShortageLine> lines) async {
    if (_submitting || _host._busy) return;
    final groups = [
      for (final line in lines)
        if (_selected(line)) line.group,
    ];
    if (groups.isEmpty) {
      context.appInfo('先勾选要下单的料');
      return;
    }
    setState(() => _submitting = true);
    var ok = false;
    try {
      ok = await _host._submitMaterialTableRows(groups, fromShortagePage: true);
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
    if (!mounted || !ok) return;
    setState(() => _rounds++);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AnimatedBuilder(
      animation: _hostChanges,
      builder: (context, _) {
        final analysis = _host._analysis;
        final roots = analysis == null
            ? const <_ChildShortageRoot>[]
            : _roots();
        final lines = [for (final root in roots) ...root.lines];
        final urged = _host._urgedMaterialLineIds();
        final selectable = [
          for (final line in lines)
            if (_selected(line)) line,
        ];
        // 下单跑到一半不许退出(返回键、手势都拦住)：按层级一段段提交，退出了就看不到
        // 哪一段没下成，也列不出更深一层。
        return PopScope(
          canPop: !_submitting,
          child: Scaffold(
            key: const Key('child-shortage-page'),
            appBar: UtenAppBar(
              title: '补下层物料',
              // 命令式子页面，没有独立路由 scope；权限入口由物料分析页承载。
              showPagePermissionAction: false,
              leading: _submitting
                  ? const SizedBox(width: 48)
                  : UtenBackButton(
                      onPressed: () => Navigator.of(context).pop(),
                    ),
            ),
            body: Stack(
              children: [
                lines.isEmpty
                    ? _doneState(theme)
                    : ListView(
                        key: const Key('child-shortage-list'),
                        padding: const EdgeInsets.fromLTRB(
                          UtenSpacing.s16,
                          UtenSpacing.s12,
                          UtenSpacing.s16,
                          UtenSpacing.s24,
                        ),
                        children: [
                          _summaryCard(theme, lines, urged),
                          const SizedBox(height: UtenSpacing.s12),
                          for (final root in roots) ...[
                            _rootSection(theme, root, urged),
                            const SizedBox(height: UtenSpacing.s12),
                          ],
                        ],
                      ),
                // 遮罩只跟宿主的网络段走(与分桶页、级联页同一份)：提交前宿主还会弹确认框，
                // 那段时间挂遮罩会把确认框盖在转圈背后点不动。
                AnimatedBuilder(
                  animation: Listenable.merge([
                    _host.bucketActionBusyMessage,
                    _host.planSubmissionProgress,
                  ]),
                  builder: (context, _) {
                    final segment = _host.bucketActionBusyMessage.value;
                    if (!_submitting ||
                        (segment == null &&
                            !_host.planSubmissionProgress.value)) {
                      return const SizedBox.shrink();
                    }
                    return UtenBusyOverlay(
                      semanticsKey: const Key('child-shortage-busy'),
                      title: segment ?? '正在下达车间',
                      description: '按层级先下上层再下下层：任一段失败会停下提示，已成功的不会重复下单。',
                    );
                  },
                ),
              ],
            ),
            bottomNavigationBar: lines.isEmpty
                ? null
                : UtenBottomActionBar(
                    child: Row(
                      children: [
                        Expanded(
                          child: Text(
                            '已选 ${selectable.length} / ${lines.length} 种',
                            style: theme.textTheme.titleSmall,
                          ),
                        ),
                        UtenButton(
                          key: const Key('child-shortage-submit'),
                          size: UtenButtonSize.large,
                          icon: Icons.shopping_cart_checkout_rounded,
                          // 不转圈：点下去先弹宿主的确认框，转圈会在确认框背后一直转；
                          // 真正跑网络段时由上面的遮罩说明在做什么。
                          onPressed:
                              selectable.isEmpty || _submitting || _host._busy
                              ? null
                              : () => unawaited(_submit(lines)),
                          child: Text(
                            _submitting
                                ? '正在下单…'
                                : '一键下单(${selectable.length})',
                          ),
                        ),
                      ],
                    ),
                  ),
          ),
        );
      },
    );
  }

  Widget _doneState(ThemeData theme) {
    final color = theme.brightness == Brightness.dark
        ? UtenColors.successOnDark
        : UtenColors.success;
    return Center(
      key: const Key('child-shortage-done'),
      child: Padding(
        padding: const EdgeInsets.all(UtenSpacing.s24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.task_alt_rounded, size: 72, color: color),
            const SizedBox(height: UtenSpacing.s16),
            Text(
              _rounds > 0 ? '下层物料都下够了' : '下层物料都够，不用补',
              style: theme.textTheme.headlineSmall?.copyWith(
                fontWeight: FontWeight.w800,
              ),
            ),
            const SizedBox(height: UtenSpacing.s8),
            Text(
              '上面的件可以足量生产。',
              style: theme.textTheme.bodyLarge?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: UtenSpacing.s24),
            UtenButton(
              key: const Key('child-shortage-back'),
              size: UtenButtonSize.large,
              icon: Icons.arrow_back_rounded,
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('返回物料分析'),
            ),
          ],
        ),
      ),
    );
  }

  /// 顶部说明 + 三个数：要下单几种、要追加几种、要先选供应方式的几种。
  Widget _summaryCard(
    ThemeData theme,
    List<_ChildShortageLine> lines,
    Set<String> urged,
  ) {
    var toOrder = 0, toAppend = 0, routeFirst = 0, urgedCount = 0;
    for (final line in lines) {
      if (line.material.confirmedRoute == null) {
        routeFirst++;
      } else if (_host._tableGroupIssued(line.group)) {
        toAppend++;
      } else {
        toOrder++;
      }
      if (urged.contains(line.material.materialLineId)) urgedCount++;
    }
    final isDark = theme.brightness == Brightness.dark;
    final accent = isDark ? UtenColors.warningOnDark : UtenColors.warning;
    return Container(
      key: const Key('child-shortage-summary'),
      padding: const EdgeInsets.all(UtenSpacing.s16),
      decoration: BoxDecoration(
        color: isDark ? accent.withValues(alpha: 0.14) : UtenColors.warningBg,
        borderRadius: UtenRadius.mdAll,
        border: Border(left: BorderSide(color: accent, width: 4)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.inventory_2_outlined, color: accent, size: 28),
              const SizedBox(width: UtenSpacing.s12),
              Expanded(
                child: Text(
                  '这些料还没下够单，上面的件做不够数',
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: UtenSpacing.s8),
          Text(
            '数量已按缺口填好，核对后点右下角「一键下单」。'
            '没下过的是「下单」，下过的是「追加」。',
            style: theme.textTheme.bodyMedium,
          ),
          const SizedBox(height: UtenSpacing.s12),
          Wrap(
            spacing: UtenSpacing.s8,
            runSpacing: UtenSpacing.s8,
            children: [
              if (toOrder > 0)
                UtenStatusBadge(
                  key: const Key('child-shortage-count-order'),
                  label: '要下单 $toOrder 种',
                  type: UtenStatusBadgeType.success,
                  icon: Icons.add_shopping_cart_rounded,
                  size: UtenStatusBadgeSize.large,
                ),
              if (toAppend > 0)
                UtenStatusBadge(
                  key: const Key('child-shortage-count-append'),
                  label: '要追加 $toAppend 种',
                  type: UtenStatusBadgeType.warning,
                  icon: Icons.exposure_plus_1_rounded,
                  size: UtenStatusBadgeSize.large,
                ),
              if (routeFirst > 0)
                UtenStatusBadge(
                  key: const Key('child-shortage-count-route'),
                  label: '先选供应方式 $routeFirst 种',
                  type: UtenStatusBadgeType.danger,
                  icon: Icons.alt_route_rounded,
                  size: UtenStatusBadgeSize.large,
                ),
              if (urgedCount > 0)
                UtenStatusBadge(
                  key: const Key('child-shortage-count-urged'),
                  label: '车间在催 $urgedCount 种',
                  type: UtenStatusBadgeType.danger,
                  icon: Icons.notifications_active_rounded,
                  size: UtenStatusBadgeSize.large,
                ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _rootSection(
    ThemeData theme,
    _ChildShortageRoot root,
    Set<String> urged,
  ) {
    final material = root.group.representative;
    final unit = material.unitName ?? '';
    final fromOrder = widget.rootKeys != null;
    final orderedLabel = fromOrder
        ? '${root.appended ? '刚追加' : '刚下单'} ${_host._qty(root.orderedQty)}$unit'
        : '已下单 ${_host._qty(root.orderedQty)}$unit';
    return DecoratedBox(
      key: ValueKey('child-shortage-root-${root.group.key}'),
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        borderRadius: UtenRadius.mdAll,
        border: Border.all(color: theme.colorScheme.outlineVariant),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            padding: const EdgeInsets.fromLTRB(
              UtenSpacing.s16,
              UtenSpacing.s12,
              UtenSpacing.s16,
              UtenSpacing.s12,
            ),
            decoration: BoxDecoration(
              color: theme.colorScheme.surfaceContainerLow,
              borderRadius: const BorderRadius.vertical(
                top: Radius.circular(UtenRadius.md),
              ),
            ),
            child: Wrap(
              crossAxisAlignment: WrapCrossAlignment.center,
              spacing: UtenSpacing.s12,
              runSpacing: UtenSpacing.s4,
              children: [
                Icon(
                  Icons.check_circle_rounded,
                  size: 22,
                  color: theme.brightness == Brightness.dark
                      ? UtenColors.successOnDark
                      : UtenColors.success,
                ),
                Text(
                  _host._tableGroupLabel(root.group),
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w800,
                  ),
                ),
                UtenStatusBadge(
                  label: orderedLabel,
                  type: UtenStatusBadgeType.success,
                  size: UtenStatusBadgeSize.large,
                ),
                Text(
                  '下面还缺 ${root.lines.length} 种',
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: theme.colorScheme.error,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ],
            ),
          ),
          for (final line in root.lines)
            _lineTile(
              theme,
              line,
              urged.contains(line.material.materialLineId),
            ),
        ],
      ),
    );
  }

  Widget _lineTile(ThemeData theme, _ChildShortageLine line, bool urged) {
    final group = line.group;
    final material = line.material;
    final row = _rowOf(line);
    final blocked = _host._tableIssueBlockedReason(group);
    final issued = _host._tableGroupIssued(group);
    final routeConfirmed = material.confirmedRoute != null;
    final shown = _host._tableShownQty(material);
    final unit = material.unitName ?? '';
    final checked = _checked(line);
    final assignable = _host._tableAssignable(group);
    final meta = [
      if (material.goodsCode?.trim().isNotEmpty == true) material.goodsCode!,
      if (material.colorName?.trim().isNotEmpty == true) material.colorName!,
      if (unit.isNotEmpty) unit,
    ].join(' · ');
    final kind = !routeConfirmed
        ? const UtenStatusBadge(
            label: '先选方式',
            type: UtenStatusBadgeType.danger,
            icon: Icons.alt_route_rounded,
          )
        : issued
        ? Tooltip(
            message:
                '这种料之前下过 ${_host._qty(_host._tableGroupIssuedQty(group))}$unit，'
                '这次是在原来的基础上再追加。',
            child: const UtenStatusBadge(
              label: '追加',
              type: UtenStatusBadgeType.warning,
              icon: Icons.exposure_plus_1_rounded,
            ),
          )
        : const UtenStatusBadge(
            label: '下单',
            type: UtenStatusBadgeType.success,
            icon: Icons.add_shopping_cart_rounded,
          );
    final covered = shown.residual - shown.net;
    final shortage = Tooltip(
      message: covered > 0.0001
          ? '右边填的是这次要盖住的总量 ${_host._qty(shown.residual)}$unit；'
                '其中 ${_host._qty(covered)}$unit 会先用别处的公共在途，只为剩下的开新单。'
          : '还要另外下单 ${_host._qty(shown.net)}$unit 才够。',
      child: Text(
        shown.net > 0.0001
            ? '还缺 ${_host._qty(shown.net)}$unit'
            : '待认领 ${_host._qty(_host._childShortageUncovered(material))}$unit',
        key: ValueKey('child-shortage-net-${group.key}'),
        style: theme.textTheme.titleSmall?.copyWith(
          color: theme.colorScheme.error,
          fontWeight: FontWeight.w800,
        ),
      ),
    );
    final quantity = SizedBox(
      width: 132,
      child: issued
          ? _host._materialTableAppendQtyCell(theme, row)
          : _host._materialTableOrderQtyCell(theme, row),
    );
    final overproductionRate = _host._tableIssueTarget(group).viaWorkshop
        ? SizedBox(
            width: 152,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text('允许超产比例', style: theme.textTheme.bodySmall),
                const SizedBox(height: UtenSpacing.s4),
                ProductionOverproductionRateField(
                  key: ValueKey(
                    'child-shortage-overproduction-rate-${group.key}',
                  ),
                  controller: _host._overproductionPercentController(
                    materialLineId: material.materialLineId,
                  ),
                  enabled: _host._canGenerate && !_host._busy && !_submitting,
                ),
              ],
            ),
          )
        : null;
    final checkbox = Checkbox(
      key: ValueKey('child-shortage-check-${group.key}'),
      value: checked,
      onChanged: blocked != null || _submitting
          ? null
          : (value) => setState(() {
              if (value == true) {
                _deselected.remove(group.key);
              } else {
                _deselected.add(group.key);
              }
            }),
    );
    final identity = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Wrap(
          crossAxisAlignment: WrapCrossAlignment.center,
          spacing: UtenSpacing.s8,
          runSpacing: 2,
          children: [
            Text(
              _host._tableGroupLabel(group),
              style: theme.textTheme.titleSmall?.copyWith(
                fontWeight: FontWeight.w700,
              ),
            ),
            if (urged)
              const UtenStatusBadge(
                label: '车间在催',
                type: UtenStatusBadgeType.danger,
                icon: Icons.notifications_active_rounded,
                size: UtenStatusBadgeSize.small,
              ),
          ],
        ),
        if (meta.isNotEmpty)
          Text(
            meta,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        if (line.depth > 1)
          Text(
            '用在「${line.parentLabel}」里',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        if (blocked != null)
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  Icons.info_outline_rounded,
                  size: 14,
                  color: theme.colorScheme.error,
                ),
                const SizedBox(width: 4),
                Flexible(
                  child: Text(
                    blocked,
                    key: ValueKey('child-shortage-blocked-${group.key}'),
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.error,
                    ),
                  ),
                ),
              ],
            ),
          ),
      ],
    );
    final route = SizedBox(
      width: 120,
      child: _host._materialTableRouteCell(theme, row),
    );
    final workshop = assignable
        ? SizedBox(
            width: 132,
            child: _host._materialTableProductionWorkshopCell(
              theme,
              row,
              revealKey: false,
            ),
          )
        : null;
    final worker = assignable
        ? SizedBox(
            width: 116,
            child: _host._materialTableResponsibleCell(
              theme,
              row,
              revealKey: false,
            ),
          )
        : null;
    final indent = (line.depth - 1) * 20.0;
    return Container(
      key: ValueKey('child-shortage-line-${group.key}'),
      decoration: BoxDecoration(
        color: checked
            ? theme.colorScheme.primary.withValues(alpha: 0.05)
            : null,
        border: Border(
          top: BorderSide(color: theme.colorScheme.outlineVariant),
        ),
      ),
      padding: EdgeInsets.fromLTRB(
        UtenSpacing.s8 + indent,
        UtenSpacing.s8,
        UtenSpacing.s16,
        UtenSpacing.s8,
      ),
      child: LayoutBuilder(
        builder: (context, constraints) {
          if (constraints.maxWidth >=
              (overproductionRate == null ? 980 : 1140)) {
            return Row(
              children: [
                checkbox,
                const SizedBox(width: UtenSpacing.s4),
                Expanded(child: identity),
                const SizedBox(width: UtenSpacing.s12),
                SizedBox(width: 88, child: kind),
                SizedBox(width: 132, child: shortage),
                route,
                const SizedBox(width: UtenSpacing.s12),
                quantity,
                if (overproductionRate != null) ...[
                  const SizedBox(width: UtenSpacing.s8),
                  overproductionRate,
                ],
                if (workshop != null) ...[
                  const SizedBox(width: UtenSpacing.s8),
                  workshop,
                ],
                if (worker != null) ...[
                  const SizedBox(width: UtenSpacing.s8),
                  worker,
                ],
              ],
            );
          }
          // 窄屏：名字一行，数量与供应方式换行排开。
          return Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              checkbox,
              const SizedBox(width: UtenSpacing.s4),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    identity,
                    const SizedBox(height: UtenSpacing.s8),
                    Wrap(
                      spacing: UtenSpacing.s12,
                      runSpacing: UtenSpacing.s8,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        kind,
                        shortage,
                        route,
                        quantity,
                        ?overproductionRate,
                        ?workshop,
                        ?worker,
                      ],
                    ),
                  ],
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}
