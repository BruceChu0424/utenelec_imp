// 结算方式管理页（基础资料 · 扁平字典 + 账期策略维护，V453）。
//
// 结算方式是销售/采购/委外结账条件与应付到期日的 UUID 权威字典（ADR-035/047）。
// 本页只做两件事：看全量（含禁用行、系统角色、账期口径）和维护账期策略与
// 可选改名（settlement_method:edit）；系统角色（CASH/MONTHLY）口径由迁移锁定，
// 页面置灰并提示。新增仍走 settlement_method:create（可随带账期）。
// 停用/删除不在此页开放：活动客户/供应商默认与单据引用受 DB 守卫保护。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../components/buttons/uten_back_button.dart';
import '../../../components/buttons/uten_button.dart';
import '../../../components/data_display/uten_status_badge.dart';
import '../../../components/inputs/uten_search_bar.dart';
import '../../../components/layout/uten_app_bar.dart';
import '../../../components/layout/uten_content_container.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/router/nav_helpers.dart';
import '../../../core/router/route_names.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../core/ui/action_feedback.dart';
import '../../../shared/auth/permissions.dart';
import '../models/settlement_method_admin.dart';
import '../repositories/reference_method_repository.dart';
import '../widgets/master_edit_dialog.dart';

class SettlementMethodPage extends ConsumerStatefulWidget {
  const SettlementMethodPage({super.key});

  @override
  ConsumerState<SettlementMethodPage> createState() =>
      _SettlementMethodPageState();
}

class _SettlementMethodPageState extends ConsumerState<SettlementMethodPage> {
  List<SettlementMethodAdminItem>? _items;
  bool _loading = false;
  String? _error;
  String _keyword = '';

  bool get _canCreate => ref
      .read(currentPermissionsProvider)
      .contains(Perm.settlementMethodCreate);

  bool get _canEdit =>
      ref.read(currentPermissionsProvider).contains(Perm.settlementMethodEdit);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final items = await ref
          .read(referenceMethodRepositoryProvider)
          .settlementAdminList();
      if (!mounted) return;
      setState(() {
        _items = items;
        _loading = false;
      });
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.message;
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _error = '加载结算方式失败';
        _loading = false;
      });
    }
  }

  List<SettlementMethodAdminItem> get _filtered {
    final items = _items ?? const <SettlementMethodAdminItem>[];
    final kw = _keyword.trim();
    if (kw.isEmpty) return items;
    return items
        .where(
          (m) =>
              m.name.toLowerCase().contains(kw.toLowerCase()) ||
              (m.code ?? '').toLowerCase().contains(kw.toLowerCase()),
        )
        .toList();
  }

  // ---- 新增（可随带账期） ------------------------------------------------

  void _showCreate() {
    showMasterEditDialog(
      context: context,
      title: '新增结算方式', // TODO(l10n): 补 arb
      fields: _termsFields(),
      initialValues: const {
        'termsBase': 'RECEIPT_DATE',
        'dueRule': 'NET_DAYS',
        'defaultDueDays': '0',
        'monthsAhead': '0',
      },
      onSubmit: _doCreate,
    );
  }

  Future<bool> _doCreate(Map<String, dynamic> body) async {
    final name = (body['name'] as String?)?.trim() ?? '';
    if (name.isEmpty) {
      context.appError('结算方式名称不能为空');
      return false;
    }
    final ok = await context.guardRun(
      () async {
        await ref
            .read(referenceMethodRepositoryProvider)
            .createSettlement(name, terms: _termsOf(body));
      },
      success: '结算方式已创建', // TODO(l10n): 补 arb
      errorFallback: '创建失败，请稍后重试', // TODO(l10n): 补 arb
    );
    if (!ok) return false;
    await _load();
    return true;
  }

  // ---- 账期维护 ----------------------------------------------------------

  void _showEditTerms(SettlementMethodAdminItem m) {
    if (m.lockedBySystemRole) {
      context.appInfo('系统角色(${m.systemRole})的账期口径由迁移锁定：现金=收货当天到期，月结=月末+30天');
      return;
    }
    if (!_canEdit) {
      context.appInfo('${m.name}：${settlementTermsSummary(m)}');
      return;
    }
    showMasterEditDialog(
      context: context,
      title: '维护账期 · ${m.name}', // TODO(l10n): 补 arb
      fields: _termsFields(hintName: m.name),
      initialValues: {
        'name': m.name,
        'termsBase': m.termsBase,
        'dueRule': m.dueRule,
        'defaultDueDays': m.defaultDueDays.toString(),
        'fixedDayOfMonth': m.fixedDayOfMonth?.toString() ?? '',
        'monthsAhead': m.monthsAhead.toString(),
      },
      onSubmit: (body) => _doUpdateTerms(m, body),
    );
  }

  Future<bool> _doUpdateTerms(
    SettlementMethodAdminItem m,
    Map<String, dynamic> body,
  ) async {
    final ok = await context.guardRun(
      () async {
        await ref
            .read(referenceMethodRepositoryProvider)
            .updateSettlementTerms(m.id, body);
      },
      success: '账期已更新', // TODO(l10n): 补 arb
      errorFallback: '更新失败，请稍后重试', // TODO(l10n): 补 arb
    );
    if (!ok) return false;
    await _load();
    return true;
  }

  /// 组装提交用的账期策略体（新建套 terms 键；编辑直接平铺——两端各自与后端
  /// DTO 对齐）。固定日仅在 FIXED_DAY_OF_MONTH 时上送，其余规则强制 null。
  Map<String, dynamic> _termsOf(Map<String, dynamic> body) {
    final rule = body['dueRule'] as String?;
    final fixedDay = body['fixedDayOfMonth'];
    return {
      'name': body['name'],
      'termsBase': body['termsBase'],
      'dueRule': rule,
      'defaultDueDays': body['defaultDueDays'],
      'fixedDayOfMonth': rule == 'FIXED_DAY_OF_MONTH' ? fixedDay : null,
      'monthsAhead': body['monthsAhead'],
    };
  }

  // ---- 字段定义 ----------------------------------------------------------

  List<MasterFieldDef> _termsFields({String? hintName}) => [
    MasterFieldDef(
      key: 'name',
      label: '名称',
      required: true,
      group: '基础',
      hint: hintName,
    ),
    MasterFieldDef(
      key: 'termsBase',
      label: '到期基准',
      type: MasterFieldType.select,
      required: true,
      options: [
        for (final entry in settlementTermsBaseLabels.entries)
          MasterSelectOption(value: entry.key, label: entry.value),
      ],
      group: '账期',
      hint: '质检验收/对账确认/发票基准开放前，到期日保持未定并阻断月结冻结',
    ),
    MasterFieldDef(
      key: 'dueRule',
      label: '到期规则',
      type: MasterFieldType.select,
      required: true,
      options: [
        for (final entry in settlementDueRuleLabels.entries)
          MasterSelectOption(value: entry.key, label: entry.value),
      ],
      group: '账期',
    ),
    const MasterFieldDef(
      key: 'defaultDueDays',
      label: '默认天数',
      type: MasterFieldType.integer,
      required: true,
      group: '账期',
      hint: '0-3650；供应商正数结算天数优先于该默认值',
    ),
    const MasterFieldDef(
      key: 'fixedDayOfMonth',
      label: '固定日',
      type: MasterFieldType.integer,
      group: '账期',
      hint: '1-31；仅「固定日」规则填写，其它规则留空',
    ),
    const MasterFieldDef(
      key: 'monthsAhead',
      label: '跨月数',
      type: MasterFieldType.integer,
      required: true,
      group: '账期',
      hint: '0-120；月末/固定日规则跨几个月后到期',
    ),
  ];

  // ---- 展示 --------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final items = _filtered;
    final total = _items?.length ?? 0;
    return Scaffold(
      appBar: UtenAppBar(
        title: '结算方式',
        leading: UtenBackButton(
          onPressed: () => backTo(context, defaultPath: RouteName.basicinfo),
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh_rounded),
            tooltip: '刷新',
            onPressed: _load,
          ),
        ],
      ),
      body: SafeArea(
        child: UtenContentContainer(
          child: Padding(
            padding: const EdgeInsets.only(top: UtenSpacing.s8),
            child: Column(
              children: [
                Padding(
                  padding: const EdgeInsets.only(
                    bottom: UtenSpacing.s8,
                    left: UtenSpacing.s4,
                    right: UtenSpacing.s4,
                  ),
                  child: Row(
                    children: [
                      Icon(
                        Icons.event_note_rounded,
                        size: 18,
                        color: theme.colorScheme.primary,
                      ),
                      const SizedBox(width: UtenSpacing.s8),
                      Text(
                        '结算方式 ($total)',
                        style: theme.textTheme.titleSmall?.copyWith(
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(width: UtenSpacing.s12),
                      Expanded(
                        child: UtenSearchBar(
                          hint: '搜索结算方式(名称/编号)',
                          initialValue: _keyword,
                          onChanged: (kw) =>
                              setState(() => _keyword = kw), // 本地过滤，小字典
                        ),
                      ),
                      if (_canCreate) ...[
                        const SizedBox(width: UtenSpacing.s8),
                        UtenButton(
                          type: UtenButtonType.tonal,
                          icon: Icons.add_rounded,
                          onPressed: _showCreate,
                          child: const Text('添加结算方式'), // TODO(l10n): 补 arb
                        ),
                      ],
                    ],
                  ),
                ),
                Expanded(
                  child: _loading && _items == null
                      ? const Center(
                          child: CircularProgressIndicator(strokeWidth: 2.5),
                        )
                      : _error != null
                      ? _ErrorRetry(message: _error!, onRetry: _load)
                      : items.isEmpty
                      ? Center(
                          child: Text(
                            _keyword.trim().isEmpty ? '暂无结算方式' : '没有匹配的结算方式',
                            style: theme.textTheme.bodyMedium?.copyWith(
                              color: theme.colorScheme.outline,
                            ),
                          ),
                        )
                      : Scrollbar(
                          child: ListView.separated(
                            padding: const EdgeInsets.only(
                              bottom: UtenSpacing.s16,
                              left: UtenSpacing.s4,
                              right: UtenSpacing.s4,
                            ),
                            itemCount: items.length,
                            separatorBuilder: (_, _) =>
                                const SizedBox(height: UtenSpacing.s8),
                            itemBuilder: (context, i) => _MethodCard(
                              item: items[i],
                              onTap: _showEditTerms,
                            ),
                          ),
                        ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _MethodCard extends StatelessWidget {
  const _MethodCard({required this.item, required this.onTap});

  final SettlementMethodAdminItem item;
  final void Function(SettlementMethodAdminItem item) onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final disabled = item.status != '使用';
    final locked = item.lockedBySystemRole;
    return Card(
      margin: EdgeInsets.zero,
      child: InkWell(
        borderRadius: BorderRadius.circular(UtenRadius.lg),
        onTap: () => onTap(item),
        child: Padding(
          padding: const EdgeInsets.all(UtenSpacing.s12),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(
                locked ? Icons.lock_outline_rounded : Icons.event_note_rounded,
                size: 20,
                color: locked
                    ? theme.colorScheme.tertiary
                    : theme.colorScheme.primary,
              ),
              const SizedBox(width: UtenSpacing.s12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Flexible(
                          child: Text(
                            item.code?.isNotEmpty == true
                                ? '${item.name}(${item.code})'
                                : item.name,
                            style: theme.textTheme.titleSmall?.copyWith(
                              fontWeight: FontWeight.w600,
                              color: disabled
                                  ? theme.colorScheme.outline
                                  : null,
                              decoration: disabled
                                  ? TextDecoration.lineThrough
                                  : null,
                            ),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        if (locked) ...[
                          const SizedBox(width: UtenSpacing.s8),
                          UtenStatusBadge(
                            label: settlementSystemRoleLabel(item.systemRole),
                            type: UtenStatusBadgeType.info,
                            size: UtenStatusBadgeSize.small,
                          ),
                        ],
                        if (disabled) ...[
                          const SizedBox(width: UtenSpacing.s8),
                          const UtenStatusBadge(
                            label: '已停用',
                            type: UtenStatusBadgeType.neutral,
                            size: UtenStatusBadgeSize.small,
                          ),
                        ],
                      ],
                    ),
                    const SizedBox(height: UtenSpacing.s4),
                    Text(
                      settlementTermsSummary(item),
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: UtenSpacing.s8),
              Icon(
                Icons.chevron_right_rounded,
                size: 20,
                color: theme.colorScheme.outline,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ErrorRetry extends StatelessWidget {
  const _ErrorRetry({required this.message, required this.onRetry});

  final String message;
  final Future<void> Function() onRetry;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(message, style: theme.textTheme.bodyMedium),
          const SizedBox(height: UtenSpacing.s12),
          UtenButton(
            type: UtenButtonType.tonal,
            icon: Icons.refresh_rounded,
            onPressed: () => onRetry(),
            child: const Text('重试'), // TODO(l10n): 补 arb
          ),
        ],
      ),
    );
  }
}
