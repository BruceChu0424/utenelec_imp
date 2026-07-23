// 访客来访预约表单：姓名/身份证/单位/事由/开车+车牌/接待部门+接待人/到访时间。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../components/buttons/uten_button.dart';
import '../../../components/cards/uten_card.dart';
import '../../../components/inputs/uten_input.dart';
import '../../../components/layout/uten_app_bar.dart';
import '../../../components/layout/uten_bottom_action_bar.dart';
import '../../../components/layout/uten_section_header.dart';
import '../../../core/responsive/scale.dart';
import '../../../components/inputs/uten_select.dart';
import '../../../core/l10n/gen/app_localizations.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/theme/uten_colors.dart';
import '../../../core/ui/app_notification.dart';
import '../models/visitor_application.dart';
import '../providers/visitor_providers.dart';
import '../repositories/visitor_repository.dart';

class VisitorApplyPage extends ConsumerStatefulWidget {
  const VisitorApplyPage({super.key});

  @override
  ConsumerState<VisitorApplyPage> createState() => _VisitorApplyPageState();
}

class _VisitorApplyPageState extends ConsumerState<VisitorApplyPage> {
  final _nameCtl = TextEditingController();
  final _idCardCtl = TextEditingController();
  final _companyCtl = TextEditingController();
  final _purposeCtl = TextEditingController();
  final _plateCtl = TextEditingController();

  bool _hasVehicle = false;
  String? _deptId;
  String? _hostId;
  DateTime? _visitTime;
  bool _submitting = false;
  String? _error;

  @override
  void dispose() {
    _nameCtl.dispose();
    _idCardCtl.dispose();
    _companyCtl.dispose();
    _purposeCtl.dispose();
    _plateCtl.dispose();
    super.dispose();
  }

  Future<void> _pickTime() async {
    final l10n = AppLocalizations.of(context);
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);

    // 允许预约的日期范围：今天 ~ 今天 + 30 天（过远日期不接预约）。
    final firstDate = today;
    final lastDate = today.add(const Duration(days: 30));

    // initialDate：若已有选过的 visitTime，且落在允许范围内，沿用它；
    // 否则用 today，但 lastDate 早于 today 时回退到 firstDate（防御）。
    DateTime initialDate = _visitTime ?? today;
    if (initialDate.isBefore(firstDate)) initialDate = firstDate;
    if (initialDate.isAfter(lastDate)) initialDate = lastDate;

    final d = await showDatePicker(
      context: context,
      initialDate: initialDate,
      firstDate: firstDate,
      lastDate: lastDate,
    );
    if (d == null) return;
    if (!mounted) return;

    // 选今天时，initialTime 推到「现在向上取整 5 分钟」，避免打开就是过去的钟点。
    // 选未来日期时，默认 09:00（工作时段起点）。
    final TimeOfDay initialTime;
    if (_isSameDay(d, now)) {
      final roundedMinute = ((now.minute + 4) ~/ 5) * 5;
      initialTime = TimeOfDay(
        hour: roundedMinute == 60 ? (now.hour + 1) % 24 : now.hour,
        minute: roundedMinute == 60 ? 0 : roundedMinute,
      );
    } else {
      initialTime = const TimeOfDay(hour: 9, minute: 0);
    }

    final t = await showTimePicker(
      context: context,
      initialTime: initialTime,
      helpText: l10n.visitorApplyVisitTime,
    );
    if (t == null) return;
    if (!mounted) return;

    final picked = DateTime(d.year, d.month, d.day, t.hour, t.minute);

    // 校验 1：组合时间必须在未来（防 pickTime 跨过零点等边界情况）。
    if (!picked.isAfter(now)) {
      setState(() {
        _visitTime = null;
        _error = l10n.visitorApplyValidateVisitTimeFuture;
      });
      return;
    }

    // 校验 2：与该访客已有 active 申请同时段冲突检查（pending/hostReviewing/
    // approved/checkedIn；rejected/cancelled 不算）。
    final myApps = ref.read(visitorApplicationsProvider(null)).valueOrNull ?? const [];
    if (_hasConflictWithActive(picked, myApps)) {
      setState(() {
        _visitTime = null;
        _error = l10n.visitorApplyDuplicateTime;
      });
      return;
    }

    setState(() {
      _visitTime = picked;
      _error = null;
    });
  }

  bool _isSameDay(DateTime a, DateTime b) =>
      a.year == b.year && a.month == b.month && a.day == b.day;

  bool _hasConflictWithActive(
    DateTime picked,
    List<VisitorApplication> apps,
  ) {
    const active = <VisitorApplicationStatus>{
      VisitorApplicationStatus.pending,
      VisitorApplicationStatus.hostReviewing,
      VisitorApplicationStatus.approved,
      VisitorApplicationStatus.checkedIn,
    };
    for (final a in apps) {
      if (active.contains(a.status) && a.plannedVisitAt.isAtSameMomentAs(picked)) {
        return true;
      }
    }
    return false;
  }

  Future<void> _submit() async {
    final l10n = AppLocalizations.of(context);
    if (_nameCtl.text.trim().isEmpty) {
      setState(() => _error = l10n.visitorApplyValidateName);
      return;
    }
    if (_purposeCtl.text.trim().isEmpty) {
      setState(() => _error = l10n.visitorApplyValidatePurpose);
      return;
    }
    if (_hostId == null) {
      setState(() => _error = l10n.visitorApplyValidateHost);
      return;
    }
    if (_visitTime == null) {
      setState(() => _error = l10n.visitorApplyValidateVisitTime);
      return;
    }
    setState(() {
      _submitting = true;
      _error = null;
    });
    try {
      final repo = ref.read(visitorRepositoryProvider);
      final app = await repo.submit({
        'visitorName': _nameCtl.text.trim(),
        'idCardNo': _idCardCtl.text.trim().isEmpty ? null : _idCardCtl.text.trim(),
        'company': _companyCtl.text.trim().isEmpty ? null : _companyCtl.text.trim(),
        'visitPurpose': _purposeCtl.text.trim(),
        'hasVehicle': _hasVehicle,
        'plateNo': _hasVehicle ? _plateCtl.text.trim() : null,
        'hostEmployeeId': _hostId,
        'hostDepartmentId': _deptId,
        'plannedVisitAt': _visitTime!.toUtc().toIso8601String(),
      });
      if (!mounted) return;
      context.appSuccess(l10n.visitorApplySuccess);
      context.go('/visitor/apply/${app.id}');
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } catch (_) {
      if (mounted) setState(() => _error = l10n.commonError);
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final depts = ref.watch(visitorDirectoryDepartmentsProvider);
    // 接待人按所选部门子树过滤（后端实现：选父部门时也能看到所有下属员工，
    // 选叶子只看叶子）。这样访客"先去哪个部门、再找谁"流程是连贯的。
    final employees = ref.watch(visitorDirectoryEmployeesProvider(
        (departmentId: _deptId, keyword: null)));

    return Scaffold(
      appBar: UtenAppBar(title: l10n.visitorApplyTitle, showBackButton: true),
      body: Column(
        children: [
          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  UtenCard(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        UtenSectionHeader(title: l10n.visitorApplyTitle, icon: Icons.person_rounded),
                        const SizedBox(height: 12),
                        UtenInput(controller: _nameCtl, label: l10n.visitorApplyName, hint: l10n.visitorApplyNameHint),
                        const SizedBox(height: 12),
                        UtenInput(controller: _idCardCtl, label: l10n.visitorApplyIdCard, hint: l10n.visitorApplyIdCardHint),
                        const SizedBox(height: 12),
                        UtenInput(controller: _companyCtl, label: l10n.visitorApplyCompany, hint: l10n.visitorApplyCompanyHint),
                        const SizedBox(height: 12),
                        UtenInput(
                          controller: _purposeCtl,
                          label: l10n.visitorApplyPurpose,
                          hint: l10n.visitorApplyPurposeHint,
                          maxLines: 3,
                        ),
                        const SizedBox(height: 8),
                        SwitchListTile(
                          contentPadding: EdgeInsets.zero,
                          title: Text(l10n.visitorApplyVehicle),
                          value: _hasVehicle,
                          onChanged: (v) => setState(() => _hasVehicle = v),
                        ),
                        if (_hasVehicle) ...[
                          UtenInput(controller: _plateCtl, label: l10n.visitorApplyPlate, hint: l10n.visitorApplyPlateHint),
                          const SizedBox(height: 12),
                        ],
                      ],
                    ),
                  ),
                  const SizedBox(height: 16),
                  UtenCard(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        UtenSectionHeader(title: l10n.visitorDetailHost, icon: Icons.people_outline_rounded),
                        const SizedBox(height: 12),
                        _DeptPicker(
                          value: _deptId,
                          items: depts.valueOrNull ?? const [],
                          label: l10n.visitorApplyDept,
                          onChanged: (v) => setState(() {
                            _deptId = v;
                            _hostId = null;
                          }),
                        ),
                        const SizedBox(height: 12),
                        _EmployeeDropdown(
                          value: _hostId,
                          items: employees.valueOrNull ?? const [],
                          label: l10n.visitorApplyHost,
                          onChanged: (v) => setState(() => _hostId = v),
                        ),
                        const SizedBox(height: 12),
                        InkWell(
                          onTap: _pickTime,
                          child: InputDecorator(
                            decoration: InputDecoration(
                              labelText: l10n.visitorApplyVisitTime,
                              prefixIcon: Icon(Icons.event_rounded, size: context.scaled(20)),
                            ),
                            child: Text(_visitTime == null
                                ? l10n.visitorApplyVisitTime
                                : '${_visitTime!.year}-${_visitTime!.month.toString().padLeft(2, '0')}-${_visitTime!.day.toString().padLeft(2, '0')} ${_visitTime!.hour.toString().padLeft(2, '0')}:${_visitTime!.minute.toString().padLeft(2, '0')}'),
                          ),
                        ),
                      ],
                    ),
                  ),
                  if (_error != null) ...[
                    const SizedBox(height: 12),
                    Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: UtenColors.error.withValues(alpha: 0.15),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Text(_error!, style: theme.textTheme.bodySmall?.copyWith(color: UtenColors.error)),
                    ),
                  ],
                  const SizedBox(height: 16),
                ],
              ),
            ),
          ),
          UtenBottomActionBar(
            child: UtenButton(
              onPressed: _submitting ? null : _submit,
              isLoading: _submitting,
              isExpanded: true,
              size: UtenButtonSize.large,
              child: Text(_submitting ? l10n.visitorApplySubmitting : l10n.visitorApplySubmit),
            ),
          ),
        ],
      ),
    );
  }
}

/// 接待部门选择器：点击 → 底部抽屉（级联导航，按部门树一层层进入，breadcrumb 可回退）。
/// 视觉：关闭态对齐 UtenSelect（label/prefixIcon/outline），避免与表单其他字段割裂。
class _DeptPicker extends StatelessWidget {
  const _DeptPicker({
    required this.value,
    required this.items,
    required this.label,
    required this.onChanged,
  });

  final String? value;
  final List<DeptDirItem> items;
  final String label;
  final ValueChanged<String?> onChanged;

  String? get _selectedName {
    if (value == null) return null;
    for (final d in items) {
      if (d.id == value) return d.name;
    }
    return null;
  }

  Future<void> _open(BuildContext context) async {
    final picked = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (sheetCtx) => _DeptCascadingSheet(
        items: items,
        value: value,
        initialAncestors: _ancestorsOf(value, items),
      ),
    );
    if (picked != null) onChanged(picked);
  }

  /// 由 id 反推它在 items 里的祖先链（根 → … → 直接父）。用于打开抽屉时恢复上次路径。
  static List<String> _ancestorsOf(String? id, List<DeptDirItem> items) {
    if (id == null) return const [];
    final byId = {for (final d in items) d.id: d};
    final out = <String>[];
    String? cur = byId[id]?.parentId;
    while (cur != null && byId.containsKey(cur)) {
      out.insert(0, cur);
      cur = byId[cur]?.parentId;
    }
    return out;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final selectedName = _selectedName;

    return InkWell(
      onTap: () => _open(context),
      borderRadius: BorderRadius.circular(10),
      child: InputDecorator(
        decoration: InputDecoration(
          labelText: label,
          prefixIcon: const Icon(Icons.account_tree_outlined),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(10),
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(10),
            borderSide: BorderSide(color: theme.colorScheme.outline),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(10),
            borderSide: BorderSide(color: theme.colorScheme.primary, width: 2),
          ),
          contentPadding:
              const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          suffixIcon: Icon(
            Icons.keyboard_arrow_down_rounded,
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        child: Text(
          selectedName ?? '请选择接待部门',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            fontSize: 14,
            color: selectedName == null
                ? theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.7)
                : theme.colorScheme.onSurface,
          ),
        ),
      ),
    );
  }
}

/// 接待部门级联抽屉：自顶向下钻入，breadcrumb 可回退；叶子（无子部门）可选。
/// 后端已过滤掉公司根节点，因此"根"是过滤后 parentId 不在 items 里的那批部门
///（通常就是 总经办）。
class _DeptCascadingSheet extends StatefulWidget {
  const _DeptCascadingSheet({
    required this.items,
    required this.value,
    required this.initialAncestors,
  });

  final List<DeptDirItem> items;
  final String? value;
  final List<String> initialAncestors;

  @override
  State<_DeptCascadingSheet> createState() => _DeptCascadingSheetState();
}

class _DeptCascadingSheetState extends State<_DeptCascadingSheet> {
  /// 从根到当前节点的部门 id 链（不含当前显示的子级）。
  late List<String> _ancestors;

  @override
  void initState() {
    super.initState();
    _ancestors = List<String>.from(widget.initialAncestors);
  }

  /// 当前显示的父节点 id（null 表示顶层）。
  String? get _currentParentId => _ancestors.isEmpty ? null : _ancestors.last;

  /// 当前父节点下的子部门。顶层时 parentId 为 null，匹配「parentId 不在
  /// items 里」的部门（即过滤后树的根——一般是总经办）。
  List<DeptDirItem> get _currentChildren {
    final parentId = _currentParentId;
    final ids = widget.items.map((d) => d.id).toSet();
    return widget.items.where((d) {
      if (parentId == null) {
        return d.parentId == null || !ids.contains(d.parentId);
      }
      return d.parentId == parentId;
    }).toList();
  }

  /// 面包屑（从根到当前父节点的名称链）。
  List<DeptDirItem> get _breadcrumbs {
    final byId = {for (final d in widget.items) d.id: d};
    return [
      for (final id in _ancestors)
        if (byId[id] != null) byId[id]!,
    ];
  }

  bool _hasChildren(DeptDirItem d) =>
      widget.items.any((c) => c.parentId == d.id);

  void _drillInto(DeptDirItem d) {
    setState(() => _ancestors = [..._ancestors, d.id]);
  }

  void _jumpTo(int index) {
    // 跳到第 index 级（index = 0 表示顶层），保留到这一级的路径。
    setState(() => _ancestors = _ancestors.sublist(0, index));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = AppLocalizations.of(context);
    final children = _currentChildren;

    return SafeArea(
      top: false,
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.sizeOf(context).height * 0.75,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // 标题
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 4, 20, 8),
              child: Text(
                l10n.visitorApplyDept,
                style: theme.textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
            // 面包屑：根 > L1 > L2 > …
            if (_breadcrumbs.isNotEmpty)
              _BreadcrumbBar(
                breadcrumbs: _breadcrumbs,
                onTap: _jumpTo,
              ),
            const Divider(height: 1),
            // 当前层部门列表
            Flexible(
              child: children.isEmpty
                  ? Padding(
                      padding: const EdgeInsets.symmetric(vertical: 48),
                      child: Center(
                        child: Text(
                          '此节点下没有子部门',
                          style: theme.textTheme.bodyMedium?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ),
                    )
                  : ListView.separated(
                      shrinkWrap: true,
                      itemCount: children.length,
                      separatorBuilder: (_, _) =>
                          const Divider(height: 1, indent: 16, endIndent: 16),
                      itemBuilder: (context, i) {
                        final d = children[i];
                        final hasChildren = _hasChildren(d);
                        final isSelected = d.id == widget.value;
                        return ListTile(
                          leading: isSelected
                              ? Icon(Icons.check_rounded,
                                  color: theme.colorScheme.primary)
                              : Icon(
                                  hasChildren
                                      ? Icons.account_tree_outlined
                                      : Icons.business_outlined,
                                  color: hasChildren
                                      ? theme.colorScheme.onSurfaceVariant
                                      : theme.colorScheme.onSurface,
                                ),
                          title: Text(d.name),
                          trailing: hasChildren
                              ? Icon(
                                  Icons.chevron_right_rounded,
                                  color: theme.colorScheme.onSurfaceVariant,
                                )
                              : isSelected
                                  ? Container(
                                      width: 8,
                                      height: 28,
                                      decoration: BoxDecoration(
                                        color: theme.colorScheme.primary,
                                        borderRadius: BorderRadius.circular(2),
                                      ),
                                    )
                                  : const Icon(
                                      Icons.radio_button_unchecked_rounded,
                                      color: Color(0xFFCBD5E1),
                                      size: 20,
                                    ),
                          onTap: () {
                            if (hasChildren) {
                              _drillInto(d);
                            } else {
                              Navigator.of(context).pop(d.id);
                            }
                          },
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

class _BreadcrumbBar extends StatelessWidget {
  const _BreadcrumbBar({required this.breadcrumbs, required this.onTap});

  final List<DeptDirItem> breadcrumbs;
  final ValueChanged<int> onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SizedBox(
      height: 40,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        itemCount: breadcrumbs.length + 1,
        separatorBuilder: (_, _) => Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4),
          child: Icon(
            Icons.chevron_right_rounded,
            size: 16,
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        itemBuilder: (context, i) {
          if (i == 0) {
            return Center(
              child: InkWell(
                onTap: () => onTap(0),
                borderRadius: BorderRadius.circular(6),
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  child: Text(
                    '根',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.primary,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ),
            );
          }
          final d = breadcrumbs[i - 1];
          final isLast = i == breadcrumbs.length;
          return Center(
            child: InkWell(
              onTap: isLast ? null : () => onTap(i),
              borderRadius: BorderRadius.circular(6),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                child: Text(
                  d.name,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: isLast
                        ? theme.colorScheme.onSurface
                        : theme.colorScheme.primary,
                    fontWeight: isLast ? FontWeight.w600 : FontWeight.w500,
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}

class _EmployeeDropdown extends StatelessWidget {
  const _EmployeeDropdown({required this.value, required this.items, required this.label, required this.onChanged});
  final String? value;
  final List<EmployeeDirItem> items;
  final String label;
  final ValueChanged<String?> onChanged;

  @override
  Widget build(BuildContext context) {
    return UtenSelect<String>(
      label: label,
      value: value,
      prefixIcon: Icons.person_search_rounded,
      items: [
        for (final e in items)
          DropdownMenuItem(
            value: e.id,
            child: Text(
              e.departmentName == null ? e.name : '${e.name}(${e.departmentName})',
              overflow: TextOverflow.ellipsis,
            ),
          ),
      ],
      onChanged: onChanged,
    );
  }
}
