part of 'admin_audit_log_page.dart';

Future<void> showAuditLogDetailViewer({
  required BuildContext context,
  required WidgetRef ref,
  required AuditLogEntry entry,
  ValueChanged<String>? onLocateRequest,
}) async {
  void locateRequest(BuildContext overlayContext, String requestId) {
    Navigator.pop(overlayContext);
    if (!context.mounted) return;
    if (onLocateRequest != null) {
      onLocateRequest(requestId);
      return;
    }
    context.push(RoutePath.adminAuditInvestigation(requestId));
  }

  final width = MediaQuery.sizeOf(context).width;
  if (width < 720) {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (sheetContext) => FractionallySizedBox(
        heightFactor: 0.92,
        child: _AuditDetailPanel(
          loader: () => _loadSharedAuditDetailBundle(ref, entry),
          onClose: () => Navigator.pop(sheetContext),
          onLocateRequest: (requestId) =>
              locateRequest(sheetContext, requestId),
        ),
      ),
    );
    return;
  }
  final panelWidth = (width * 0.56).clamp(640.0, 900.0).toDouble();
  await showGeneralDialog<void>(
    context: context,
    barrierDismissible: true,
    barrierLabel: '关闭审计详情',
    barrierColor: Colors.black54,
    transitionDuration: const Duration(milliseconds: 220),
    pageBuilder: (dialogContext, _, _) => SafeArea(
      child: Align(
        alignment: Alignment.centerRight,
        child: Material(
          color: Theme.of(dialogContext).colorScheme.surface,
          clipBehavior: Clip.antiAlias,
          shape: RoundedRectangleBorder(
            borderRadius: const BorderRadius.horizontal(
              left: Radius.circular(20),
            ),
            side: BorderSide(
              color: Theme.of(dialogContext).colorScheme.outlineVariant,
            ),
          ),
          child: SizedBox(
            width: panelWidth,
            height: double.infinity,
            child: _AuditDetailPanel(
              loader: () => _loadSharedAuditDetailBundle(ref, entry),
              onClose: () => Navigator.pop(dialogContext),
              onLocateRequest: (requestId) =>
                  locateRequest(dialogContext, requestId),
            ),
          ),
        ),
      ),
    ),
    transitionBuilder: (_, animation, _, child) => SlideTransition(
      position: Tween<Offset>(
        begin: const Offset(1, 0),
        end: Offset.zero,
      ).animate(CurvedAnimation(parent: animation, curve: Curves.easeOutCubic)),
      child: child,
    ),
  );
}

Future<_AuditDetailBundle> _loadSharedAuditDetailBundle(
  WidgetRef ref,
  AuditLogEntry entry,
) async {
  final repository = ref.read(auditLogRepositoryProvider);
  final detail = await repository.detail(entry.id);
  final requestId = detail.requestId?.trim();
  if (requestId == null ||
      !_AdminAuditLogPageState._requestIdPattern.hasMatch(requestId)) {
    return _AuditDetailBundle(detail: detail);
  }
  try {
    final relatedPage = await repository.list(
      size: 100,
      requestId: requestId,
      activityOnly: false,
    );
    final databaseRows = relatedPage.items
        .where((row) => row.eventSource == 'database' && row.id != detail.id)
        .toList(growable: false);
    const detailLimit = 24;
    return _AuditDetailBundle(
      detail: detail,
      relatedChanges: databaseRows.take(detailLimit).toList(growable: false),
      relatedChangesTruncated:
          databaseRows.length > detailLimit ||
          relatedPage.total > relatedPage.items.length,
    );
  } catch (_) {
    return _AuditDetailBundle(
      detail: detail,
      relatedChangesError: '关联业务变化加载失败，可稍后重试打开详情。',
    );
  }
}

class _AuditDetailBundle {
  const _AuditDetailBundle({
    required this.detail,
    this.relatedChanges = const [],
    this.relatedChangesError,
    this.relatedChangesTruncated = false,
  });

  final AuditLogDetail detail;
  final List<AuditLogEntry> relatedChanges;
  final String? relatedChangesError;
  final bool relatedChangesTruncated;
}

class _AuditDetailPanel extends StatefulWidget {
  const _AuditDetailPanel({
    required this.loader,
    required this.onClose,
    required this.onLocateRequest,
  });

  final Future<_AuditDetailBundle> Function() loader;
  final VoidCallback onClose;
  final ValueChanged<String> onLocateRequest;

  @override
  State<_AuditDetailPanel> createState() => _AuditDetailPanelState();
}

class _AuditDetailPanelState extends State<_AuditDetailPanel> {
  late Future<_AuditDetailBundle> _future;

  @override
  void initState() {
    super.initState();
    _future = widget.loader();
  }

  void _reload() {
    setState(() => _future = widget.loader());
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<_AuditDetailBundle>(
      future: _future,
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return const Center(
            child: CircularProgressIndicator(strokeWidth: 2.5),
          );
        }
        if (snapshot.hasError || snapshot.data == null) {
          final message = snapshot.error is ApiException
              ? (snapshot.error! as ApiException).message
              : '审计详情加载失败';
          return Column(
            children: [
              _AuditDetailHeader(title: '审计详情', onClose: widget.onClose),
              Expanded(
                child: Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        message,
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.error,
                        ),
                      ),
                      const SizedBox(height: UtenSpacing.s12),
                      OutlinedButton.icon(
                        onPressed: _reload,
                        icon: const Icon(Icons.refresh_rounded),
                        label: const Text('重试'),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          );
        }
        return _AuditDetailContent(
          detail: snapshot.data!.detail,
          relatedChanges: snapshot.data!.relatedChanges,
          relatedChangesError: snapshot.data!.relatedChangesError,
          relatedChangesTruncated: snapshot.data!.relatedChangesTruncated,
          onRetryRelatedChanges: _reload,
          onClose: widget.onClose,
          onLocateRequest: widget.onLocateRequest,
        );
      },
    );
  }
}

class _AuditDetailContent extends StatelessWidget {
  const _AuditDetailContent({
    required this.detail,
    required this.relatedChanges,
    required this.relatedChangesTruncated,
    required this.onRetryRelatedChanges,
    required this.onClose,
    required this.onLocateRequest,
    this.relatedChangesError,
  });

  final AuditLogDetail detail;
  final List<AuditLogEntry> relatedChanges;
  final String? relatedChangesError;
  final bool relatedChangesTruncated;
  final VoidCallback onRetryRelatedChanges;
  final VoidCallback onClose;
  final ValueChanged<String> onLocateRequest;

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 4,
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(UtenSpacing.s16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _AuditDetailHeader(
                title: '审计详情 #${detail.id}',
                subtitle:
                    AuditEventPresentation.salesViewNarrative(
                      action: detail.action,
                      targetName: detail.targetName,
                    ) ??
                    detail.summary ??
                    _AdminAuditLogPageState._actionLabel(detail.action),
                onLocateRequest: detail.requestId?.trim().isNotEmpty == true
                    ? () => onLocateRequest(detail.requestId!)
                    : null,
                onClose: onClose,
              ),
              const TabBar(
                isScrollable: true,
                tabAlignment: TabAlignment.start,
                tabs: [
                  Tab(icon: Icon(Icons.subject_outlined), text: '概览'),
                  Tab(icon: Icon(Icons.compare_arrows_rounded), text: '数据变更'),
                  Tab(icon: Icon(Icons.devices_other_rounded), text: '设备证据'),
                  Tab(icon: Icon(Icons.troubleshoot_rounded), text: '排查信息'),
                ],
              ),
              const SizedBox(height: UtenSpacing.s12),
              Expanded(
                child: TabBarView(
                  children: [
                    _AuditOverviewTab(detail: detail),
                    _AuditChangeTab(
                      detail: detail,
                      relatedChanges: relatedChanges,
                      relatedChangesError: relatedChangesError,
                      relatedChangesTruncated: relatedChangesTruncated,
                      onRetryRelatedChanges: onRetryRelatedChanges,
                    ),
                    _AuditDeviceTab(detail: detail),
                    _AuditTechnicalTab(detail: detail),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 概览页：一张"操作叙事卡"按 谁 → 何时/在哪 → 做了什么 → 改了什么 的顺序讲完整事件，
/// 再配风险说明与排查线索。信息按"读故事"的顺序组织，而不是按数据库字段罗列。
class _AuditOverviewTab extends StatelessWidget {
  const _AuditOverviewTab({required this.detail});

  final AuditLogDetail detail;

  /// 结果优先用后端翻译好的中文(如 密码错误)，兜底本地映射。
  static String _outcomeText(AuditLogDetail detail) {
    final label = detail.resultLabel?.trim();
    if (label?.isNotEmpty == true) return label!;
    final local = _AdminAuditLogPageState._resultLabel(detail.result);
    if (local.isNotEmpty) return local;
    return '—';
  }

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.only(bottom: UtenSpacing.s16),
      children: [
        _AuditStoryCard(detail: detail),
        const SizedBox(height: UtenSpacing.s12),
        _AuditRiskCard(
          riskLevel: detail.riskLevel,
          riskReason: detail.riskReason,
        ),
        const SizedBox(height: UtenSpacing.s12),
        _AuditEnvironmentCard(detail: detail),
      ],
    );
  }
}

/// 操作叙事卡：回答"谁、在几点、在哪个页面、做了什么、对象是哪张单据、具体改了什么"。
class _AuditStoryCard extends StatelessWidget {
  const _AuditStoryCard({required this.detail});

  final AuditLogDetail detail;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final displayName = AuditEventPresentation.actorLabel(
      actorDisplay: detail.actorDisplay,
      actorName: detail.actorName,
      actorAccount: detail.actorAccount,
    );
    final initial = displayName.isNotEmpty ? displayName.characters.first : '?';
    final headline =
        AuditEventPresentation.salesViewNarrative(
          action: detail.action,
          targetName: detail.targetName,
        ) ??
        (detail.summary?.trim().isNotEmpty == true
            ? detail.summary!
            : detail.actionLabel?.trim().isNotEmpty == true
            ? detail.actionLabel!
            : _AdminAuditLogPageState._actionLabel(detail.action));
    final objectText = _objectText(detail);
    final changes = _parseChangeEntries(detail);
    return UtenCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // ── 卡片标题 + 操作结果 ──────────────────────────────
          Row(
            children: [
              Icon(Icons.fact_check_outlined, color: theme.colorScheme.primary),
              const SizedBox(width: UtenSpacing.s8),
              Expanded(
                child: Text(
                  '这次操作做了什么',
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: UtenSpacing.s12),
          // ── 谁 ─────────────────────────────────────────────
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              CircleAvatar(
                radius: 24,
                backgroundColor: theme.colorScheme.primaryContainer,
                child: Text(
                  initial,
                  style: theme.textTheme.titleMedium?.copyWith(
                    color: theme.colorScheme.onPrimaryContainer,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              const SizedBox(width: UtenSpacing.s12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      displayName,
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    if (detail.actorName?.trim().isNotEmpty == true &&
                        detail.actorAccount?.trim().isNotEmpty == true)
                      Text(
                        '账号 ${detail.actorAccount}',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                  ],
                ),
              ),
              _AuditResultBadge(
                result: detail.result,
                resultLabel: detail.resultLabel,
                statusCode: detail.statusCode,
              ),
            ],
          ),
          if (detail.actorDepartment?.trim().isNotEmpty == true ||
              detail.actorPosition?.trim().isNotEmpty == true) ...[
            const SizedBox(height: UtenSpacing.s8),
            Wrap(
              spacing: UtenSpacing.s8,
              runSpacing: UtenSpacing.s8,
              children: [
                if (detail.actorDepartment?.trim().isNotEmpty == true)
                  _OrgChip(
                    icon: Icons.apartment_outlined,
                    label: '部门',
                    value: detail.actorDepartment!,
                  ),
                if (detail.actorPosition?.trim().isNotEmpty == true)
                  _OrgChip(
                    icon: Icons.badge_outlined,
                    label: '职位',
                    value: detail.actorPosition!,
                  ),
              ],
            ),
          ],
          const Divider(height: UtenSpacing.s24),
          // ── 何时 / 在哪 ─────────────────────────────────────
          Wrap(
            spacing: UtenSpacing.s8,
            runSpacing: UtenSpacing.s8,
            children: [
              _AuditContextChip(
                icon: Icons.schedule_rounded,
                text: _AdminAuditLogPageState._fmtTime(detail.createdAt),
              ),
              if (detail.pageLabel?.trim().isNotEmpty == true)
                _AuditContextChip(
                  icon: Icons.web_asset_outlined,
                  text: detail.pageLabel!,
                ),
              _AuditContextChip(
                icon: Icons.storage_outlined,
                text: _sourceLabel(detail.eventSource),
              ),
            ],
          ),
          const SizedBox(height: UtenSpacing.s12),
          // ── 做了什么：完整中文句子(动作 + 对象 + 单号 + 关键变化)──
          Container(
            width: double.infinity,
            padding: const EdgeInsets.fromLTRB(UtenSpacing.s12, 2, 0, 2),
            decoration: BoxDecoration(
              border: Border(
                left: BorderSide(color: theme.colorScheme.primary, width: 3),
              ),
            ),
            child: Text(
              headline,
              style: theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w700,
                height: 1.6,
              ),
            ),
          ),
          // ── 对象：哪张单据 / 哪个档案 ────────────────────────
          if (objectText != null) ...[
            const SizedBox(height: UtenSpacing.s12),
            Row(
              children: [
                Icon(
                  Icons.sell_outlined,
                  size: 18,
                  color: theme.colorScheme.tertiary,
                ),
                const SizedBox(width: UtenSpacing.s8),
                Text(
                  '操作对象',
                  style: theme.textTheme.labelMedium?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(width: UtenSpacing.s8),
                Flexible(
                  child: Text(
                    objectText,
                    overflow: TextOverflow.ellipsis,
                    maxLines: 2,
                    style: theme.textTheme.bodyLarge?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ],
            ),
          ],
          // ── 具体变更：什么字段、从什么值改成了什么值 ──────────
          if (changes.isNotEmpty) ...[
            const SizedBox(height: UtenSpacing.s16),
            Text(
              '具体变更',
              style: theme.textTheme.labelLarge?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: UtenSpacing.s8),
            ...changes.map((entry) => _AuditChangeRow(entry: entry)),
          ],
        ],
      ),
    );
  }

  static String? _objectText(AuditLogDetail detail) {
    final label = detail.objectLabel?.trim().isNotEmpty == true
        ? detail.objectLabel!
        : _objectTypeLabel(detail.targetType);
    final displayName = AuditEventPresentation.safeBusinessReference(
      detail.targetDisplayName,
    );
    final businessCode = AuditEventPresentation.safeBusinessReference(
      detail.targetBusinessCode,
    );
    final legacyCode = AuditEventPresentation.safeBusinessReference(
      detail.targetLegacyCode,
    );
    if (displayName != null || businessCode != null || legacyCode != null) {
      return [
        if (label.isNotEmpty) label,
        if (displayName != null && displayName != label) displayName,
        if (businessCode != null) '业务编号 $businessCode',
        if (legacyCode != null) '旧系统编号 $legacyCode',
      ].join(' · ');
    }
    final salesObject = AuditEventPresentation.salesViewObjectText(
      action: detail.action,
      targetName: detail.targetName,
    );
    if (salesObject != null) return salesObject;
    final name = AuditEventPresentation.safeBusinessReference(
      detail.targetName,
    );
    if (label.isEmpty) {
      return name?.isNotEmpty == true ? name : null;
    }
    return name?.isNotEmpty == true ? '$label · $name' : label;
  }
}

/// 风险说明卡：等级徽标 + 风险原因 + 免责说明。
class _AuditRiskCard extends StatelessWidget {
  const _AuditRiskCard({required this.riskLevel, required this.riskReason});

  final String riskLevel;
  final String? riskReason;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = _riskColor(context, riskLevel);
    return Container(
      padding: const EdgeInsets.all(UtenSpacing.s16),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.10),
        borderRadius: UtenRadius.lgAll,
        border: Border.all(color: color.withValues(alpha: 0.35)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _AuditRiskIcon(level: riskLevel),
          const SizedBox(width: UtenSpacing.s12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _AuditRiskBadge(level: riskLevel),
                const SizedBox(height: UtenSpacing.s8),
                Text(
                  riskReason ?? '未提供风险说明',
                  style: theme.textTheme.bodyMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                    height: 1.5,
                  ),
                ),
                const SizedBox(height: UtenSpacing.s4),
                Text(
                  '风险等级由固定规则计算，用于排查优先级，不代表已经发生安全事故。',
                  style: theme.textTheme.bodySmall?.copyWith(
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

/// 业务语义卡：概览只保留普通核查人员需要的中文信息。
class _AuditEnvironmentCard extends StatelessWidget {
  const _AuditEnvironmentCard({required this.detail});

  final AuditLogDetail detail;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return UtenCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                Icons.travel_explore_rounded,
                color: theme.colorScheme.primary,
              ),
              const SizedBox(width: UtenSpacing.s8),
              Text(
                '操作说明',
                style: theme.textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
          const SizedBox(height: UtenSpacing.s16),
          Wrap(
            spacing: UtenSpacing.s24,
            runSpacing: UtenSpacing.s16,
            children: [
              _AuditFact(
                label: '做了什么',
                value:
                    AuditEventPresentation.salesViewActionLabel(
                      detail.action,
                    ) ??
                    detail.actionLabel ??
                    _AdminAuditLogPageState._actionLabel(detail.action),
              ),
              _AuditFact(
                label: '结果',
                value: _AuditOverviewTab._outcomeText(detail),
              ),
              _AuditFact(
                label: '事件类型',
                value: _categoryLabel(detail.eventCategory),
              ),
              if (detail.pageLabel?.trim().isNotEmpty == true)
                _AuditFact(label: '操作位置', value: detail.pageLabel!),
            ],
          ),
          const SizedBox(height: UtenSpacing.s12),
          Text(
            '操作关联编号、网络地址、请求路径和原始编码统一收在“排查信息”中。',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}

/// 时间 / 页面 / 记录来源小标签("何时、在哪"的上下文)。
class _AuditContextChip extends StatelessWidget {
  const _AuditContextChip({required this.icon, required this.text});

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: UtenSpacing.s8,
        vertical: 4,
      ),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.6),
        borderRadius: UtenRadius.smAll,
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 13, color: theme.colorScheme.onSurfaceVariant),
          const SizedBox(width: UtenSpacing.s4),
          Flexible(
            child: Text(
              text,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 一条具体变更：字段名 + [旧值] → [新值]；非字段说明(如"共填写 N 项信息")整行展示。
class _AuditChangeRow extends StatelessWidget {
  const _AuditChangeRow({required this.entry});

  final _AuditChangeEntry entry;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    if (entry.field == null) {
      return Padding(
        padding: const EdgeInsets.only(top: UtenSpacing.s4),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.only(top: 7),
              child: Container(
                width: 5,
                height: 5,
                decoration: BoxDecoration(
                  color: theme.colorScheme.primary,
                  shape: BoxShape.circle,
                ),
              ),
            ),
            const SizedBox(width: UtenSpacing.s8),
            Expanded(
              child: Text(
                entry.info ?? '',
                style: theme.textTheme.bodyMedium?.copyWith(height: 1.5),
              ),
            ),
          ],
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.only(top: UtenSpacing.s8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 104,
            child: Text(
              entry.field!,
              style: theme.textTheme.labelMedium?.copyWith(
                fontWeight: FontWeight.w700,
                height: 1.6,
              ),
            ),
          ),
          const SizedBox(width: UtenSpacing.s8),
          Expanded(
            child: Wrap(
              spacing: UtenSpacing.s4,
              runSpacing: UtenSpacing.s4,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                _AuditValueChip(value: entry.oldValue ?? '空', changed: false),
                Icon(
                  Icons.arrow_forward_rounded,
                  size: 14,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
                _AuditValueChip(value: entry.newValue ?? '空', changed: true),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// 变更值胶囊：旧值灰底、新值主题色底，让"改成什么"一眼突出。
class _AuditValueChip extends StatelessWidget {
  const _AuditValueChip({required this.value, required this.changed});

  final String value;
  final bool changed;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final background = changed
        ? theme.colorScheme.primaryContainer
        : theme.colorScheme.surfaceContainerHighest;
    final foreground = changed
        ? theme.colorScheme.onPrimaryContainer
        : theme.colorScheme.onSurfaceVariant;
    return Container(
      constraints: const BoxConstraints(maxWidth: 280),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
      decoration: BoxDecoration(
        color: background,
        borderRadius: UtenRadius.smAll,
      ),
      child: Text(
        // 时间戳等原始值统一经字段字典可读化(ISO → yyyy-MM-dd HH:mm(北京时间))
        AuditFieldLabels.valueOf(value),
        overflow: TextOverflow.ellipsis,
        maxLines: 1,
        style: theme.textTheme.bodySmall?.copyWith(
          color: foreground,
          fontWeight: FontWeight.w600,
          fontFeatures: const [FontFeature.tabularFigures()],
        ),
      ),
    );
  }
}

/// 后端 changeSummary("字段：旧 → 新；…"，分号分隔)解析结果。
class _AuditChangeEntry {
  const _AuditChangeEntry._({
    this.field,
    this.oldValue,
    this.newValue,
    this.info,
  });

  const _AuditChangeEntry.ofField(
    String field,
    String oldValue,
    String newValue,
  ) : this._(field: field, oldValue: oldValue, newValue: newValue);

  const _AuditChangeEntry.ofNote(String info) : this._(info: info);

  /// 中文字段名；为 null 表示这是一条说明行(info 有值)。
  final String? field;
  final String? oldValue;
  final String? newValue;
  final String? info;
}

List<_AuditChangeEntry> _parseChangeEntries(AuditLogDetail detail) {
  return _parseChangeSummary(detail.changeSummary);
}

List<_AuditChangeEntry> _parseChangeSummary(String? value) {
  final raw = value?.trim();
  if (raw == null || raw.isEmpty) return const [];
  return raw
      .split('；')
      .map((line) => line.trim())
      .where((line) => line.isNotEmpty)
      .map((line) {
        // "字段：旧值 → 新值"：第一个冒号前是字段名，最后一个" → "两侧是前后值
        final colon = line.indexOf('：');
        final arrow = line.indexOf(' → ');
        if (colon > 0 && arrow > colon) {
          final rest = line.substring(colon + 1);
          final separator = rest.lastIndexOf(' → ');
          if (separator > 0) {
            return _AuditChangeEntry.ofField(
              line.substring(0, colon),
              rest.substring(0, separator),
              rest.substring(separator + 3),
            );
          }
        }
        return _AuditChangeEntry.ofNote(line);
      })
      .toList();
}

/// 部门/职位小标签。
class _OrgChip extends StatelessWidget {
  const _OrgChip({required this.icon, this.label, this.value});

  final IconData icon;
  final String? label;
  final String? value;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: UtenSpacing.s8,
        vertical: 4,
      ),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerLow,
        borderRadius: UtenRadius.mdAll,
        border: Border.all(color: theme.colorScheme.outlineVariant),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 15, color: theme.colorScheme.primary),
          const SizedBox(width: 4),
          Text(
            '${label ?? ''} ${value ?? ''}'.trim(),
            style: theme.textTheme.bodySmall?.copyWith(
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}

class _AuditChangeTab extends ConsumerStatefulWidget {
  const _AuditChangeTab({
    required this.detail,
    required this.relatedChanges,
    required this.relatedChangesTruncated,
    required this.onRetryRelatedChanges,
    this.relatedChangesError,
  });

  final AuditLogDetail detail;
  final List<AuditLogEntry> relatedChanges;
  final String? relatedChangesError;
  final bool relatedChangesTruncated;
  final VoidCallback onRetryRelatedChanges;

  @override
  ConsumerState<_AuditChangeTab> createState() => _AuditChangeTabState();
}

class _AuditChangeTabState extends ConsumerState<_AuditChangeTab> {
  bool _namesRequested = false;

  Map<String, dynamic> _decode(String? raw) {
    if (raw == null || raw.trim().isEmpty) return const {};
    try {
      final value = jsonDecode(raw);
      return value is Map<String, dynamic> ? value : const {};
    } catch (_) {
      return const {};
    }
  }

  /// 把快照里"长得像 UUID"的值按字段语义批量预解析成名称(仓库/货品/员工…)。
  Future<void> _ensureNames(
    Map<String, dynamic> before,
    Map<String, dynamic> after,
  ) async {
    if (_namesRequested) return;
    _namesRequested = true;
    final service = ref.read(masterNameServiceProvider);
    final goodsIds = <String>{};
    final employeeIds = <String>{};
    for (final entry in [...before.entries, ...after.entries]) {
      for (final value in [entry.value, after[entry.key]]) {
        if (!AuditFieldLabels.looksLikeUuid(value)) continue;
        final kind = _refKindOf(entry.key);
        if (kind == _RefKind.goods) goodsIds.add(value as String);
        if (kind == _RefKind.employee) employeeIds.add(value as String);
      }
    }
    try {
      await service.ensureLoaded();
      await Future.wait([
        service.loadGoodsNames(goodsIds),
        service.loadEmployeeNames(employeeIds.toList()),
      ]);
      if (mounted) setState(() {});
    } catch (_) {
      // 名称解析是辅助信息，失败时保持短 ID 展示。
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final before = _decode(widget.detail.beforeJson);
    final after = _decode(widget.detail.afterJson);
    final keys = {...before.keys, ...after.keys}.toList()..sort();
    final changed = keys
        .where((key) => jsonEncode(before[key]) != jsonEncode(after[key]))
        .toList(growable: false);
    if (changed.isNotEmpty && !_namesRequested) {
      WidgetsBinding.instance.addPostFrameCallback(
        (_) => _ensureNames(before, after),
      );
    }
    final service = ref.watch(masterNameServiceProvider);
    final related = widget.relatedChanges;
    return ListView(
      padding: const EdgeInsets.only(bottom: UtenSpacing.s16),
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                related.isNotEmpty
                    ? '本次操作产生 ${related.length} 组业务变化'
                    : changed.isEmpty
                    ? '没有字段级快照'
                    : '共 ${changed.length} 个字段发生变化',
                style: theme.textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
            const UtenStatusBadge(
              label: '敏感字段已剔除',
              type: UtenStatusBadgeType.info,
              size: UtenStatusBadgeSize.small,
            ),
          ],
        ),
        const SizedBox(height: UtenSpacing.s12),
        if (widget.relatedChangesError != null) ...[
          _AuditErrorCard(
            message: widget.relatedChangesError!,
            onRetry: widget.onRetryRelatedChanges,
          ),
          const SizedBox(height: UtenSpacing.s12),
        ],
        if (related.isNotEmpty) ...[
          for (final change in related) ...[
            _AuditRelatedChangeCard(entry: change),
            const SizedBox(height: UtenSpacing.s8),
          ],
          if (widget.relatedChangesTruncated)
            Text(
              '关联变化较多，本页仅展示前 24 组；可按操作关联编号进一步排查。',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          const SizedBox(height: UtenSpacing.s12),
        ],
        if (changed.isEmpty && related.isEmpty)
          UtenCard(
            child: Text(
              '这条记录可能是读取或安全事件，也可能没有产生字段变化。可在“排查信息”中查看关联线索。',
              style: theme.textTheme.bodyMedium?.copyWith(height: 1.5),
            ),
          )
        else if (changed.isNotEmpty) ...[
          Text(
            related.isEmpty ? '字段变化' : '当前记录的字段快照',
            style: theme.textTheme.titleSmall?.copyWith(
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: UtenSpacing.s8),
          UtenCard(
            padding: EdgeInsets.zero,
            child: Column(
              children: [
                for (var index = 0; index < changed.length; index++) ...[
                  _AuditDiffRow(
                    field: AuditFieldLabels.labelOf(changed[index]),
                    before: _displayValue(
                      service,
                      changed[index],
                      before[changed[index]],
                    ),
                    after: _displayValue(
                      service,
                      changed[index],
                      after[changed[index]],
                    ),
                  ),
                  if (index != changed.length - 1) const Divider(height: 1),
                ],
              ],
            ),
          ),
        ],
        if (widget.detail.beforeJson?.trim().isNotEmpty == true ||
            widget.detail.afterJson?.trim().isNotEmpty == true) ...[
          const SizedBox(height: UtenSpacing.s12),
          _AuditJsonExpansion(
            label: '查看变更前原始数据',
            rawJson: widget.detail.beforeJson,
          ),
          const SizedBox(height: UtenSpacing.s8),
          _AuditJsonExpansion(
            label: '查看变更后原始数据',
            rawJson: widget.detail.afterJson,
          ),
        ],
      ],
    );
  }

  /// UUID 值 → "名称(短ID)"；无法解析时缩短展示；其余值翻译布尔/空。
  static String _displayValue(
    MasterNameService service,
    String field,
    dynamic value,
  ) {
    if (AuditFieldLabels.looksLikeUuid(value)) {
      final id = value as String;
      final resolved = _resolveRef(service, field, id);
      return resolved == null ? _shortId(id) : '$resolved(${_shortId(id)})';
    }
    return AuditFieldLabels.valueOf(value);
  }

  static String? _resolveRef(
    MasterNameService service,
    String field,
    String id,
  ) {
    String? pick(String name) => name == '—' || name.isEmpty ? null : name;
    return switch (_refKindOf(field)) {
      _RefKind.warehouse => pick(service.warehouse(id)),
      _RefKind.currency => pick(service.currency(id)),
      _RefKind.color => pick(service.color(id)),
      _RefKind.unit => pick(service.unit(id)),
      _RefKind.goods => pick(service.goods(id)),
      _RefKind.supplier => pick(service.supplier(id)),
      _RefKind.department => pick(service.department(id)),
      _RefKind.employee => pick(service.employee(id)),
      _RefKind.unknown => null,
    };
  }

  static _RefKind _refKindOf(String field) {
    final key = field.toLowerCase();
    if (key.contains('warehouse')) return _RefKind.warehouse;
    if (key.contains('currency')) return _RefKind.currency;
    if (key.contains('color')) return _RefKind.color;
    if (key.contains('unit_id') || key.endsWith('_unit')) return _RefKind.unit;
    if (key.contains('goods') || key.contains('material') || key == 'item_id') {
      return _RefKind.goods;
    }
    if (key.contains('supplier')) return _RefKind.supplier;
    if (key.contains('department')) return _RefKind.department;
    if (key.contains('employee') ||
        key.contains('supervisor') ||
        key.endsWith('_by') ||
        key == 'user_id' ||
        key == 'operator_id' ||
        key == 'maker_id') {
      return _RefKind.employee;
    }
    return _RefKind.unknown;
  }
}

class _AuditRelatedChangeCard extends ConsumerStatefulWidget {
  const _AuditRelatedChangeCard({required this.entry});

  final AuditLogEntry entry;

  @override
  ConsumerState<_AuditRelatedChangeCard> createState() =>
      _AuditRelatedChangeCardState();
}

class _AuditRelatedChangeCardState
    extends ConsumerState<_AuditRelatedChangeCard> {
  Future<AuditLogDetail>? _detailFuture;

  void _loadDetail() {
    setState(() {
      _detailFuture = ref
          .read(auditLogRepositoryProvider)
          .detail(widget.entry.id);
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final entry = widget.entry;
    final previewEntries = _parseChangeSummary(entry.changeSummary);
    final object = entry.objectLabel?.trim().isNotEmpty == true
        ? entry.objectLabel!.trim()
        : _objectTypeLabel(entry.targetType);
    final displayName = AuditEventPresentation.safeBusinessReference(
      entry.targetDisplayName,
    );
    final businessCode = AuditEventPresentation.safeBusinessReference(
      entry.targetBusinessCode,
    );
    final legacyCode = AuditEventPresentation.safeBusinessReference(
      entry.targetLegacyCode,
    );
    final compatibleName = AuditEventPresentation.safeBusinessReference(
      entry.targetName,
    );
    final pageLabel = entry.pageLabel?.trim();
    final structuredTitle = [
      if (object.isNotEmpty) object,
      if (displayName != null && displayName != object) displayName,
      if (businessCode != null) '业务编号 $businessCode',
      if (legacyCode != null) '旧系统编号 $legacyCode',
      if (displayName == null &&
          businessCode == null &&
          legacyCode == null &&
          compatibleName != null)
        compatibleName,
    ].join(' · ');
    final fallbackTitle =
        compatibleName ??
        (pageLabel?.isNotEmpty == true ? pageLabel! : '对象名称与业务编号未记录的业务变化');
    final title = structuredTitle.isNotEmpty ? structuredTitle : fallbackTitle;
    return UtenCard(
      padding: EdgeInsets.zero,
      child: ExpansionTile(
        key: ValueKey('audit-related-change-${entry.id}'),
        onExpansionChanged: (expanded) {
          if (expanded && _detailFuture == null) _loadDetail();
        },
        title: Text(title, style: const TextStyle(fontWeight: FontWeight.w700)),
        subtitle: entry.summary?.trim().isNotEmpty == true
            ? Text(entry.summary!, maxLines: 2, overflow: TextOverflow.ellipsis)
            : const Text('已记录脱敏业务变化'),
        children: [
          const Divider(height: 1),
          Padding(
            padding: const EdgeInsets.all(UtenSpacing.s12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (previewEntries.isNotEmpty) ...[
                  Text(
                    '变化摘要',
                    style: theme.textTheme.labelLarge?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: UtenSpacing.s4),
                  for (final preview in previewEntries)
                    _AuditChangeRow(entry: preview),
                  const SizedBox(height: UtenSpacing.s12),
                ],
                FutureBuilder<AuditLogDetail>(
                  future: _detailFuture,
                  builder: (context, snapshot) {
                    if (snapshot.connectionState != ConnectionState.done) {
                      return const Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          LinearProgressIndicator(minHeight: 2),
                          SizedBox(height: UtenSpacing.s8),
                          Text('正在加载这一组的完整字段详情…'),
                        ],
                      );
                    }
                    if (snapshot.hasError || snapshot.data == null) {
                      return Row(
                        children: [
                          Expanded(
                            child: Text(
                              '这组字段详情加载失败，可单独重试。',
                              style: TextStyle(color: theme.colorScheme.error),
                            ),
                          ),
                          TextButton(
                            onPressed: _loadDetail,
                            child: const Text('重试'),
                          ),
                        ],
                      );
                    }
                    final fullEntries = _relatedDetailEntries(snapshot.data!);
                    if (fullEntries.isEmpty) {
                      return Text(
                        previewEntries.isEmpty
                            ? '该关联记录没有可展示的字段变化。'
                            : '没有更多字段详情。',
                        style: theme.textTheme.bodyMedium,
                      );
                    }
                    return Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '完整字段详情',
                          style: theme.textTheme.labelLarge?.copyWith(
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        const SizedBox(height: UtenSpacing.s4),
                        for (final fullEntry in fullEntries)
                          _AuditChangeRow(entry: fullEntry),
                      ],
                    );
                  },
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

List<_AuditChangeEntry> _relatedDetailEntries(AuditLogDetail detail) {
  Map<String, dynamic> decode(String? raw) {
    if (raw == null || raw.trim().isEmpty) return const {};
    try {
      final value = jsonDecode(raw);
      return value is Map<String, dynamic> ? value : const {};
    } catch (_) {
      return const {};
    }
  }

  String safeValue(dynamic value) {
    if (AuditFieldLabels.looksLikeUuid(value)) return '关联对象';
    if (value is Map || value is List) return '结构化内容';
    return AuditFieldLabels.valueOf(value);
  }

  final before = decode(detail.beforeJson);
  final after = decode(detail.afterJson);
  final keys = {...before.keys, ...after.keys}.toList()..sort();
  final snapshotEntries = keys
      .where((key) => jsonEncode(before[key]) != jsonEncode(after[key]))
      .take(20)
      .map(
        (key) => _AuditChangeEntry.ofField(
          AuditFieldLabels.labelOf(key),
          safeValue(before[key]),
          safeValue(after[key]),
        ),
      )
      .toList(growable: false);
  return snapshotEntries.isNotEmpty
      ? snapshotEntries
      : _parseChangeEntries(detail);
}

enum _RefKind {
  warehouse,
  currency,
  color,
  unit,
  goods,
  supplier,
  department,
  employee,
  unknown,
}

class _AuditDiffRow extends StatelessWidget {
  const _AuditDiffRow({required this.field, this.before, this.after});

  /// 已中文化的字段标签
  final String field;
  final dynamic before;
  final dynamic after;

  String _value(dynamic value) {
    if (value == null) return '—';
    if (value is Map || value is List) {
      return const JsonEncoder.withIndent('  ').convert(value);
    }
    return value.toString();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.all(UtenSpacing.s12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              Flexible(
                child: SelectableText(
                  field,
                  style: theme.textTheme.labelLarge?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: UtenSpacing.s8),
          LayoutBuilder(
            builder: (context, constraints) {
              final oldValue = _AuditDiffValue(
                label: '变更前',
                value: _value(before),
              );
              final newValue = _AuditDiffValue(
                label: '变更后',
                value: _value(after),
              );
              if (constraints.maxWidth < 560) {
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    oldValue,
                    const SizedBox(height: UtenSpacing.s8),
                    newValue,
                  ],
                );
              }
              return Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(child: oldValue),
                  const Padding(
                    padding: EdgeInsets.all(UtenSpacing.s8),
                    child: Icon(Icons.arrow_forward_rounded),
                  ),
                  Expanded(child: newValue),
                ],
              );
            },
          ),
        ],
      ),
    );
  }
}

class _AuditDiffValue extends StatelessWidget {
  const _AuditDiffValue({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.all(UtenSpacing.s8),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerLow,
        borderRadius: UtenRadius.mdAll,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: theme.textTheme.labelSmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: UtenSpacing.s4),
          SelectableText(value, style: theme.textTheme.bodySmall),
        ],
      ),
    );
  }
}

class _AuditJsonExpansion extends StatelessWidget {
  const _AuditJsonExpansion({required this.label, required this.rawJson});

  final String label;
  final String? rawJson;

  @override
  Widget build(BuildContext context) {
    return UtenCard(
      padding: EdgeInsets.zero,
      child: ExpansionTile(
        title: Text(label),
        children: [
          const Divider(height: 1),
          Padding(
            padding: const EdgeInsets.all(UtenSpacing.s12),
            child: Align(
              alignment: Alignment.centerLeft,
              child: SelectableText(
                _AuditJsonPanel._pretty(rawJson),
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  fontFamily: 'monospace',
                  height: 1.45,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

enum _LocalReceiptAuthorizationState { idle, loading, authorized, failed }
