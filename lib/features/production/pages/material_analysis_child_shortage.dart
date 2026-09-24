part of 'production_material_analysis_page.dart';

// ADR-117 下单后查子层 + 车间催计划(计划侧)。
//
// 物料分析准备页可以分批下单、也可以追加，于是很容易「只下了父件、忘了子件」。这里做三件事：
//
// 1. 每次下单 / 追加成功之后(主表「下单(N)」、下达采购 / 委外 / 车间三个分桶页、行菜单)，
//    沿 BOM 往下看刚下单的件：下层还有「还缺数量」的，弹窗告诉计划员「下层物料还不够，做不够
//    这么多」，可以「去补下单」或「稍后再说」；
// 2. 「补下层物料」页：把缺的料都列出来，数量已按缺口填好——没下过的是「下单」、下过的是
//    「追加」，一键下单。输入框、车间 / 负责人、供应方式、提交编排全部用的是主表同一份状态与
//    同一个 [_submitMaterialTableRows]，所以下完之后主表的「下单数量 / 追加下单」当场就是新的；
// 3. 页面顶部提示条：已下单的件下面还有没下够的料时常驻提醒；车间催计划(车间任务等料开工)时
//    换成红色「车间在催」，点「去补下单」进同一页。
//
// 「还缺」的口径只有一个：主表「还缺数量」那一列(服务端 netShortageQty)。判断「下层缺不缺」
// 只看权威快照，不看父行改量时的估算值——估算只是展示，库里并没有那些单。

/// 一件已下单的物料(树顶)和它下面还缺的物料。
final class _ChildShortageRoot {
  const _ChildShortageRoot({
    required this.group,
    required this.orderedQty,
    required this.appended,
    required this.lines,
  });

  final _MaterialGroup group;

  /// 刚下单 / 追加的量；提示条入口打开时是累计已下单量。
  final double orderedQty;

  /// 这次是追加(下单前就下过)。
  final bool appended;
  final List<_ChildShortageLine> lines;
}

/// 下层一种还缺的物料。
final class _ChildShortageLine {
  const _ChildShortageLine({
    required this.group,
    required this.depth,
    required this.parentLabel,
  });

  final _MaterialGroup group;

  /// 相对树顶的层级：1 = 直接下层。
  final int depth;
  final String parentLabel;

  ProductionMaterialAnalysisMaterial get material => group.representative;
}

abstract class _MaterialAnalysisChildShortageState
    extends _MaterialAnalysisChildCascadeState {
  static const int _shortageDepthLimit = 10;
  static const int _shortageRowLimit = 300;

  /// 「补下层物料」页是另一条路由：宿主 setState 不会重建它。宿主每次 setState
  /// 都推一下这个信号，页里的行、数量、车间 / 负责人就与主表同一时刻变。
  final ValueNotifier<int> _childShortageRevision = ValueNotifier<int>(0);

  /// 本分析上车间在催的任务(ADR-117)；换分析时清空重取。
  List<MaterialAnalysisWorkshopUrge> _workshopUrges = const [];
  String? _workshopUrgesScope;
  int _workshopUrgesGeneration = 0;

  /// 提示条那一份「已下单的件下面还缺什么」按快照缓存：页面每次重建都会读它。
  ProductionMaterialAnalysisView? _childShortageBannerAnalysis;
  List<_ChildShortageRoot> _childShortageBannerRoots = const [];

  @override
  void setState(VoidCallback fn) {
    super.setState(fn);
    _childShortageRevision.value++;
  }

  @override
  void dispose() {
    _childShortageRevision.dispose();
    super.dispose();
  }

  @override
  void _applyAnalysis(ProductionMaterialAnalysisView view) {
    final previousScope = _workshopUrgesScope;
    super._applyAnalysis(view);
    final scope = '${_sessionScopeKey()}|${view.analysisId}';
    if (scope != previousScope) {
      _workshopUrgesScope = scope;
      _workshopUrges = const [];
      _workshopUrgesGeneration++;
      // 换了一份分析(或换了账号)：车间在催的清单跟着重取。不在 setState 回调里同步
      // 发请求，排到下一个微任务。
      scheduleMicrotask(() => unawaited(_loadWorkshopUrges()));
    }
  }

  // ------------------------------------------------------------ 数据

  /// 下单前每个提交单元的累计已下单量(键 = [_MaterialGroup.key])，与下单后的比出
  /// 「这次刚下了哪几件、各下了多少」——不管是从哪个入口下的单都一样判。
  @override
  Map<String, double> _issuedQtySnapshot() {
    final analysis = _analysis;
    if (analysis == null) return const {};
    return {
      for (final group in _analysisIndexes(analysis).groupsByKey.values)
        group.key: _tableGroupIssuedQty(group, authoritative: true),
    };
  }

  /// 这一行在权威快照里还缺不缺(主表「还缺数量」那一列 > 0)。SHIP / REFERENCE 阶段的料
  /// 不写正式生产需求(ADR-029 §4.1)，不算「做不够」。
  bool _childShortageMissing(ProductionMaterialAnalysisMaterial material) =>
      !_isNonProductionStage(material.controlStage) &&
      _tableShownQty(material, authoritative: true).net > 0.0001;

  /// 这一件的下层要不要一起看：自制，或 BOM 上还有生产性下层的委外(含 V581 单一子件
  /// 委外——那颗子件仍要我方备)。与「父件 + 下层一起下单」同一条下钻口径。
  bool _childShortageDescends(
    ProductionMaterialAnalysisMaterial material,
    _MaterialGroup? group,
    ProductionMaterialAnalysisView analysis,
  ) {
    if (group == null) return false;
    final route = _draftRoute(group);
    return route == MaterialSupplyRoute.make ||
        (route == MaterialSupplyRoute.subcontract &&
            _hasProductionBomChildren(material, analysis));
  }

  /// 已下单的件和它们下面还缺的料。
  ///
  /// - [before] 非空：下单后的检查——只看这次刚下单 / 追加的件(累计已下单量比下单前多)。
  /// - [rootKeys] 非空：「补下层物料」页按打开时的那几件重算。
  /// - 都为空：提示条——所有已下过单的件。
  ///
  /// 同时被选中的父件与子件只作一棵树(子件由父件带出)；同一种料在几棵树下只列一次。
  List<_ChildShortageRoot> _childShortageRoots({
    Map<String, double>? before,
    Set<String>? rootKeys,
    Map<String, double> orderedQty = const {},
    Set<String> appendedKeys = const {},
  }) {
    final analysis = _analysis;
    if (analysis == null) return const [];
    final indexes = _analysisIndexes(analysis);
    final presentation = _bomPresentation(analysis);
    final byLine = {
      for (final material in analysis.materials)
        material.materialLineId: material,
    };
    final children = <String, List<ProductionMaterialAnalysisMaterial>>{};
    for (final entry in presentation.parentIdsByMaterial.entries) {
      final parent = entry.value;
      final child = byLine[entry.key];
      if (parent == null || child == null || child.isRootSupply) continue;
      children.putIfAbsent(parent, () => []).add(child);
    }
    for (final siblings in children.values) {
      siblings.sort(_compareBomSiblings);
    }

    // 树顶候选：这次刚下单的件 / 页里记着的那几件 / 所有下过单的件。
    final seeds = <String, ({double qty, bool appended})>{};
    for (final group in indexes.groupsByKey.values) {
      final issued = _tableGroupIssuedQty(group, authoritative: true);
      if (before != null) {
        final delta = issued - (before[group.key] ?? 0);
        if (delta > 0.0001) {
          seeds[group.key] = (
            qty: delta,
            appended: (before[group.key] ?? 0) > 0.0001,
          );
        }
      } else if (rootKeys != null) {
        if (rootKeys.contains(group.key)) {
          seeds[group.key] = (
            qty: orderedQty[group.key] ?? issued,
            appended: appendedKeys.contains(group.key),
          );
        }
      } else if (issued > 0.0001) {
        seeds[group.key] = (qty: issued, appended: false);
      }
    }
    if (seeds.isEmpty) return const [];

    // 祖先里已有树顶的件不单独成树：它由上面那棵树带出(父件 + 子件同时下单时只问一次)。
    final seedLines = <String, String>{
      for (final key in seeds.keys)
        indexes.groupsByKey[key]!.representative.materialLineId: key,
    };
    bool hasSeedAncestor(String lineId) {
      var parent = presentation.parentIdsByMaterial[lineId];
      final visited = <String>{};
      while (parent != null && visited.add(parent)) {
        if (seedLines.containsKey(parent)) return true;
        parent = presentation.parentIdsByMaterial[parent];
      }
      return false;
    }

    final listed = <String>{};
    var budget = _shortageRowLimit;
    final roots = <_ChildShortageRoot>[];
    final ordered = seeds.entries.toList()
      ..sort((left, right) {
        final a = indexes.groupsByKey[left.key]!.representative;
        final b = indexes.groupsByKey[right.key]!.representative;
        final byProduct = (a.analysisLineId ?? '').compareTo(
          b.analysisLineId ?? '',
        );
        return byProduct != 0 ? byProduct : _compareBomSiblings(a, b);
      });
    for (final seed in ordered) {
      final group = indexes.groupsByKey[seed.key]!;
      final root = group.representative;
      if (hasSeedAncestor(root.materialLineId)) continue;
      if (!_childShortageDescends(root, group, analysis)) continue;
      final lines = <_ChildShortageLine>[];
      void walk(
        String parentId,
        String parentLabel,
        int depth,
        Set<String> ancestors,
      ) {
        if (depth > _shortageDepthLimit || budget <= 0) return;
        for (final child
            in children[parentId] ??
                const <ProductionMaterialAnalysisMaterial>[]) {
          if (budget <= 0) return;
          if (_isNonProductionStage(child.controlStage)) continue;
          if (!ancestors.add(child.materialLineId)) continue;
          final childGroup = indexes.groupsByLine[child.materialLineId];
          if (childGroup != null &&
              _childShortageMissing(child) &&
              listed.add(childGroup.key)) {
            lines.add(
              _ChildShortageLine(
                group: childGroup,
                depth: depth,
                parentLabel: parentLabel,
              ),
            );
            budget--;
          }
          if (_childShortageDescends(child, childGroup, analysis)) {
            walk(
              child.materialLineId,
              _tableGroupLabel(childGroup!),
              depth + 1,
              {...ancestors},
            );
          }
        }
      }

      walk(root.materialLineId, _tableGroupLabel(group), 1, {
        root.materialLineId,
      });
      if (lines.isEmpty) continue;
      roots.add(
        _ChildShortageRoot(
          group: group,
          orderedQty: seed.value.qty,
          appended: seed.value.appended,
          lines: lines,
        ),
      );
    }
    return roots;
  }

  /// 提示条用：所有已下单的件下面还缺的料(按快照缓存)。
  List<_ChildShortageRoot> _childShortageBannerRootsFor(
    ProductionMaterialAnalysisView analysis,
  ) {
    if (!identical(_childShortageBannerAnalysis, analysis)) {
      _childShortageBannerAnalysis = analysis;
      _childShortageBannerRoots = _childShortageRoots();
    }
    return _childShortageBannerRoots;
  }

  /// 车间在催、而且那个任务缺的料里此刻还有计划没下够单的(按同一份快照的「还缺数量」)。
  List<MaterialAnalysisWorkshopUrge> _activeWorkshopUrges(
    ProductionMaterialAnalysisView analysis,
  ) {
    if (_workshopUrges.isEmpty) return const [];
    final indexes = _analysisIndexes(analysis);
    bool missing(String lineId) {
      final group = indexes.groupsByLine[lineId];
      return group != null && _childShortageMissing(group.representative);
    }

    return [
      for (final urge in _workshopUrges)
        if (urge.shortMaterialLineIds.any(missing)) urge,
    ];
  }

  /// 车间在催的物料行(补下层物料页给这些行挂「车间在催」红标)。
  Set<String> _urgedMaterialLineIds() => {
    for (final urge in _workshopUrges) ...urge.shortMaterialLineIds,
  };

  Future<void> _loadWorkshopUrges() async {
    final analysis = _analysis;
    if (analysis == null || !mounted) return;
    final generation = ++_workshopUrgesGeneration;
    try {
      final urges = await ref
          .read(productionPlanRepositoryProvider)
          .materialAnalysisWorkshopUrges(analysis.analysisId);
      if (!mounted ||
          generation != _workshopUrgesGeneration ||
          _analysis?.analysisId != analysis.analysisId) {
        return;
      }
      setState(() => _workshopUrges = urges);
    } catch (_) {
      // 提示条是附加信息：取不到不打扰主流程，下次下单 / 回到本页再取。
    }
  }

  /// 下完单后：车间在催的记录里计划已经下够的，马上办结并撤掉计划员的待办卡
  /// (不等后台 5 分钟一轮)，再重取一次在催清单。
  Future<void> _reconcileWorkshopUrgesAfterOrder() async {
    final analysis = _analysis;
    if (analysis == null || _workshopUrges.isEmpty) return;
    if (!_canNotify && !_canGenerate) return;
    try {
      await ref
          .read(productionPlanRepositoryProvider)
          .reconcileMaterialAnalysisWorkshopUrges(analysis.analysisId);
    } catch (_) {
      // 办结只是撤提醒：失败了由后台核对兜底，不影响已经下好的单。
    }
    await _loadWorkshopUrges();
  }

  // ------------------------------------------------------------ 下单后检查

  /// 下单 / 追加成功之后调用：下层还有缺的，弹窗问要不要现在补。[before] 来自下单前的
  /// [_issuedQtySnapshot]。
  @override
  Future<void> _checkChildShortagesAfterOrder(
    Map<String, double> before,
  ) async {
    if (!mounted) return;
    unawaited(_reconcileWorkshopUrgesAfterOrder());
    final roots = _childShortageRoots(before: before);
    if (roots.isEmpty) return;
    // 刚下单的结果提示先落定一帧，再弹「下层还缺」——两件事一前一后看得清。
    await WidgetsBinding.instance.endOfFrame;
    if (!mounted) return;
    final go = await _showChildShortageDialog(roots);
    if (!mounted || go != true) return;
    await _openChildShortagePage(roots: roots);
  }

  Future<bool?> _showChildShortageDialog(List<_ChildShortageRoot> roots) {
    final theme = Theme.of(context);
    final kinds = roots.fold<int>(0, (sum, root) => sum + root.lines.length);
    return showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        key: const Key('child-shortage-dialog'),
        titlePadding: EdgeInsets.zero,
        title: _ChildShortageDialogHeader(kinds: kinds),
        content: ConstrainedBox(
          constraints: BoxConstraints(
            maxWidth: 520,
            maxHeight: MediaQuery.sizeOf(dialogContext).height * 0.6,
          ),
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  '这些件下单了，但它们要用的下层物料还没下够单。不补的话，按现在的料做不够数。',
                  style: theme.textTheme.bodyLarge,
                ),
                const SizedBox(height: UtenSpacing.s12),
                for (final root in roots.take(4)) ...[
                  _ChildShortageRootSummary(
                    title: _tableGroupLabel(root.group),
                    orderedLabel:
                        '${root.appended ? '刚追加' : '刚下单'} '
                        '${_qty(root.orderedQty)}${root.group.representative.unitName ?? ''}',
                    lines: [
                      for (final line in root.lines.take(5))
                        (
                          name: _tableGroupLabel(line.group),
                          route: _draftRoute(line.group),
                          short:
                              '还缺 ${_qty(_tableShownQty(line.material, authoritative: true).net)}'
                              '${line.material.unitName ?? ''}',
                        ),
                    ],
                    more: root.lines.length > 5 ? root.lines.length - 5 : 0,
                  ),
                  const SizedBox(height: UtenSpacing.s8),
                ],
                if (roots.length > 4)
                  Text(
                    '…… 还有 ${roots.length - 4} 件也缺下层物料',
                    style: theme.textTheme.bodyMedium,
                  ),
              ],
            ),
          ),
        ),
        actionsAlignment: MainAxisAlignment.center,
        actions: [
          UtenButton(
            key: const Key('child-shortage-later'),
            type: UtenButtonType.ghost,
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('稍后再说'),
          ),
          UtenButton(
            key: const Key('child-shortage-go'),
            icon: Icons.playlist_add_check_rounded,
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('去补下单'),
          ),
        ],
      ),
    );
  }

  /// 打开「补下层物料」页。[roots] 为空 = 从提示条进来：所有已下单的件下面缺的料。
  Future<void> _openChildShortagePage({List<_ChildShortageRoot>? roots}) async {
    if (!mounted || _analysis == null) return;
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => _ChildShortageFillPage(
          host: this,
          rootKeys: roots == null
              ? null
              : {for (final root in roots) root.group.key},
          orderedQty: {
            for (final root in roots ?? const <_ChildShortageRoot>[])
              root.group.key: root.orderedQty,
          },
          appendedKeys: {
            for (final root in roots ?? const <_ChildShortageRoot>[])
              if (root.appended) root.group.key,
          },
        ),
      ),
    );
    if (mounted) setState(() {});
  }

  // ------------------------------------------------------------ 提示条

  /// 页面顶部提示条：车间在催(红) > 已下单的件下面还缺料(琥珀)；都没有返回 null。
  Widget? _childShortageBanner(
    ThemeData theme,
    ProductionMaterialAnalysisView analysis,
  ) {
    final urges = _activeWorkshopUrges(analysis);
    final roots = _childShortageBannerRootsFor(analysis);
    final kinds = roots.fold<int>(0, (sum, root) => sum + root.lines.length);
    if (urges.isEmpty && kinds == 0) return null;
    final urgent = urges.isNotEmpty;
    final isDark = theme.brightness == Brightness.dark;
    final accent = urgent
        ? (isDark ? UtenColors.errorOnDark : UtenColors.error)
        : (isDark ? UtenColors.warningOnDark : UtenColors.warning);
    final background = urgent
        ? (isDark ? accent.withValues(alpha: 0.16) : UtenColors.errorBg)
        : (isDark ? accent.withValues(alpha: 0.16) : UtenColors.warningBg);
    final canOrder = _canNotify || _canGenerate;
    final first = urges.isEmpty ? null : urges.first;
    final title = urgent
        ? '车间在催：${urges.length} 个任务等料开工'
        : '已下单的件里，还有 $kinds 种下层物料没下够';
    final detail = urgent
        ? [
            '${first!.workshopName ?? '车间'} ${first.lastUrgedByName ?? ''}'
                '${first.lastUrgedAt == null ? '' : ' ${_urgeTimeText(first.lastUrgedAt!)}'}'
                ' 催了${first.urgeCount > 1 ? ' ${first.urgeCount} 次' : ''}：'
                '${first.segmentCode ?? ''} ${first.productName ?? ''}',
            if (urges.length > 1) '另有 ${urges.length - 1} 个任务也在催',
          ].join('；')
        : '不补的话，上面的件做不够数。';
    return Container(
      key: Key(
        urgent ? 'child-shortage-banner-urgent' : 'child-shortage-banner',
      ),
      padding: const EdgeInsets.fromLTRB(
        UtenSpacing.s12,
        UtenSpacing.s8,
        UtenSpacing.s8,
        UtenSpacing.s8,
      ),
      decoration: BoxDecoration(
        color: background,
        borderRadius: UtenRadius.mdAll,
        border: Border(left: BorderSide(color: accent, width: 4)),
      ),
      child: Row(
        children: [
          Icon(
            urgent
                ? Icons.notifications_active_rounded
                : Icons.inventory_2_outlined,
            color: accent,
            size: 28,
          ),
          const SizedBox(width: UtenSpacing.s12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  title,
                  style: theme.textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: 2),
                Text(detail, style: theme.textTheme.bodyMedium),
              ],
            ),
          ),
          const SizedBox(width: UtenSpacing.s8),
          UtenButton(
            key: const Key('child-shortage-banner-go'),
            type: urgent ? UtenButtonType.danger : UtenButtonType.primary,
            icon: Icons.playlist_add_check_rounded,
            onPressed: canOrder && !_busy
                ? () => unawaited(_openChildShortagePage())
                : null,
            child: Text(canOrder ? '去补下单' : '没有下单权限'),
          ),
        ],
      ),
    );
  }

  String _urgeTimeText(DateTime at) {
    final local = at.toLocal();
    final now = DateTime.now();
    final minutes = now.difference(local).inMinutes;
    if (minutes < 1) return '刚刚';
    if (minutes < 60) return '$minutes 分钟前';
    String two(int value) => value.toString().padLeft(2, '0');
    final sameDay =
        local.year == now.year &&
        local.month == now.month &&
        local.day == now.day;
    return sameDay
        ? '今天 ${two(local.hour)}:${two(local.minute)}'
        : '${local.month}月${local.day}日 ${two(local.hour)}:${two(local.minute)}';
  }
}

// ============================================================ 弹窗小件

class _ChildShortageDialogHeader extends StatelessWidget {
  const _ChildShortageDialogHeader({required this.kinds});

  final int kinds;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final accent = isDark ? UtenColors.warningOnDark : UtenColors.warning;
    return Container(
      padding: const EdgeInsets.fromLTRB(24, 20, 24, 16),
      decoration: BoxDecoration(
        color: isDark ? accent.withValues(alpha: 0.16) : UtenColors.warningBg,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
      ),
      child: Row(
        children: [
          Icon(Icons.warning_amber_rounded, color: accent, size: 36),
          const SizedBox(width: UtenSpacing.s12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  '下层物料还不够',
                  style: theme.textTheme.titleLarge?.copyWith(
                    fontWeight: FontWeight.w800,
                  ),
                ),
                Text(
                  '还缺 $kinds 种料没下够单',
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// 弹窗里一件刚下单的物料：名字 + 「刚下单 1000 个」，下面列出缺的料。
class _ChildShortageRootSummary extends StatelessWidget {
  const _ChildShortageRootSummary({
    required this.title,
    required this.orderedLabel,
    required this.lines,
    required this.more,
  });

  final String title;
  final String orderedLabel;
  final List<({String name, MaterialSupplyRoute route, String short})> lines;
  final int more;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.all(UtenSpacing.s12),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerLow,
        borderRadius: UtenRadius.mdAll,
        border: Border.all(color: theme.colorScheme.outlineVariant),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Icon(
                Icons.check_circle_rounded,
                size: 20,
                color: theme.brightness == Brightness.dark
                    ? UtenColors.successOnDark
                    : UtenColors.success,
              ),
              const SizedBox(width: UtenSpacing.s8),
              Expanded(
                child: Text(
                  title,
                  style: theme.textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              UtenStatusBadge(
                label: orderedLabel,
                type: UtenStatusBadgeType.success,
              ),
            ],
          ),
          const SizedBox(height: UtenSpacing.s8),
          for (final line in lines)
            Padding(
              padding: const EdgeInsets.only(
                left: UtenSpacing.s24,
                top: UtenSpacing.s4,
              ),
              child: Row(
                children: [
                  _RouteChip(route: line.route),
                  const SizedBox(width: UtenSpacing.s8),
                  Expanded(
                    child: Text(
                      line.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodyMedium,
                    ),
                  ),
                  Text(
                    line.short,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: theme.colorScheme.error,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ],
              ),
            ),
          if (more > 0)
            Padding(
              padding: const EdgeInsets.only(
                left: UtenSpacing.s24,
                top: UtenSpacing.s4,
              ),
              child: Text('…… 还有 $more 种', style: theme.textTheme.bodySmall),
            ),
        ],
      ),
    );
  }
}

/// 供应方式小标签：采购蓝、委外紫、自制青，一眼分得开。
class _RouteChip extends StatelessWidget {
  const _RouteChip({required this.route});

  final MaterialSupplyRoute route;

  @override
  Widget build(BuildContext context) => UtenStatusBadge(
    label: route.label,
    size: UtenStatusBadgeSize.small,
    type: switch (route) {
      MaterialSupplyRoute.buy => UtenStatusBadgeType.info,
      MaterialSupplyRoute.subcontract => UtenStatusBadgeType.violet,
      MaterialSupplyRoute.make => UtenStatusBadgeType.success,
    },
    icon: switch (route) {
      MaterialSupplyRoute.buy => Icons.shopping_cart_outlined,
      MaterialSupplyRoute.subcontract => Icons.local_shipping_outlined,
      MaterialSupplyRoute.make => Icons.precision_manufacturing_outlined,
    },
  );
}
