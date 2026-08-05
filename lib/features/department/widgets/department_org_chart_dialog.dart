// 部门组织架构图（v2 重构，ADR-021 §七）：
// - 节点卡片化：部门名 + 人数 + 负责人 chip 一体；层级用引导线 + 色彩区分；
// - 领导归入班组：负责人即使档案挂在总经办等上级组织，也在其负责的节点内
//   以「负责人」首行呈现（非直属时标注「挂职」）；成员行带领导/班组管理徽章；
// - 节点可展开/收起（默认展开，点节点头切换）；
// - 打印架构图按 employee:export 权限点门控（无权限隐藏按钮）。
// 入口：部门管理 → 部门概览卡「部门架构图」按钮。
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import '../../../components/buttons/uten_button.dart';
import '../../../core/print/pdf_printer.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../core/ui/app_notification.dart';
import '../../../shared/auth/permissions.dart';
import '../../employee/models/employee_api_models.dart';
import '../../employee/repositories/employee_repository.dart';
import '../../employee/widgets/employee_leadership_badge.dart';
import '../models/department_node.dart';
import '../repositories/department_repository.dart';

/// 弹出部门架构图弹层。
Future<void> showDepartmentOrgChart({
  required BuildContext context,
  required DepartmentNode node,
}) {
  return showDialog<void>(
    context: context,
    builder: (_) => DepartmentOrgChartDialog(node: node),
  );
}

class DepartmentOrgChartDialog extends ConsumerStatefulWidget {
  const DepartmentOrgChartDialog({super.key, required this.node});

  final DepartmentNode node;

  @override
  ConsumerState<DepartmentOrgChartDialog> createState() =>
      _DepartmentOrgChartDialogState();
}

class _DepartmentOrgChartDialogState
    extends ConsumerState<DepartmentOrgChartDialog> {
  DepartmentNode? _root;
  Map<String, List<EmployeeSummary>> _byDept = const {};
  final Set<String> _collapsed = {};
  bool _loading = true;
  bool _printing = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final tree = await ref
          .read(departmentRepositoryProvider)
          .subtree(widget.node.id);
      final employees = await _loadAllEmployees();
      if (!mounted) return;
      setState(() {
        _root = tree.isEmpty ? widget.node : tree.first;
        _byDept = _groupByDept(employees);
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _error = '加载架构图数据失败，请稍后重试';
        _loading = false;
      });
    }
  }

  Future<List<EmployeeSummary>> _loadAllEmployees() async {
    final repo = ref.read(employeeRepositoryProvider);
    final all = <EmployeeSummary>[];
    var page = 1;
    while (true) {
      final r = await repo.list(
        page: page,
        size: 100,
        departmentId: widget.node.id,
        includeSubtree: true,
      );
      all.addAll(r.items);
      if (page >= r.totalPages || all.length >= 500) break;
      page++;
    }
    return all;
  }

  Map<String, List<EmployeeSummary>> _groupByDept(
    List<EmployeeSummary> employees,
  ) {
    final map = <String, List<EmployeeSummary>>{};
    for (final e in employees) {
      final key = e.departmentId;
      if (key == null) continue;
      map.putIfAbsent(key, () => []).add(e);
    }
    return map;
  }

  /// 节点成员（负责人排最前；负责人非直属时不重复出现在成员里）。
  List<EmployeeSummary> _membersOf(DepartmentNode node) {
    final employees = List<EmployeeSummary>.from(
      _byDept[node.id] ?? const <EmployeeSummary>[],
    );
    if (node.managerId != null) {
      employees.removeWhere((e) => e.id == node.managerId);
    }
    return employees;
  }

  /// 负责人是否为本节点直属员工（false = 挂职，如高层档案在总经办）。
  bool _managerIsDirect(DepartmentNode node) {
    if (node.managerId == null) return false;
    return (_byDept[node.id] ?? const <EmployeeSummary>[])
        .any((e) => e.id == node.managerId);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final canExport = ref
        .watch(currentPermissionsProvider)
        .contains(Perm.employeeExport);
    return Dialog(
      clipBehavior: Clip.antiAlias,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 680, maxHeight: 760),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 14, 8, 8),
              child: Row(
                children: [
                  Icon(
                    Icons.account_tree_outlined,
                    color: theme.colorScheme.primary,
                  ),
                  const SizedBox(width: UtenSpacing.s8),
                  Expanded(
                    child: Text(
                      '${widget.node.name} · 组织架构图',
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  IconButton(
                    tooltip: '关闭',
                    onPressed: () => Navigator.of(context).pop(),
                    icon: const Icon(Icons.close_rounded),
                  ),
                ],
              ),
            ),
            const Divider(height: 1),
            Flexible(
              child: _loading
                  ? const Center(
                      child: Padding(
                        padding: EdgeInsets.all(48),
                        child: CircularProgressIndicator(),
                      ),
                    )
                  : _error != null
                  ? Center(
                      child: Padding(
                        padding: const EdgeInsets.all(32),
                        child: Text(_error!),
                      ),
                    )
                  : ListView(
                      padding: const EdgeInsets.all(UtenSpacing.s16),
                      children: [_deptTile(context, _root!, 0)],
                    ),
            ),
            const Divider(height: 1),
            Padding(
              padding: const EdgeInsets.all(UtenSpacing.s12),
              child: Row(
                children: [
                  if (!canExport)
                    Expanded(
                      child: Text(
                        '如需打印件请联系有导出权限的同事',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                  const Spacer(),
                  if (canExport)
                    UtenButton(
                      icon: Icons.print_outlined,
                      isLoading: _printing,
                      onPressed: (_loading || _error != null)
                          ? null
                          : _printPdf,
                      child: const Text('打印架构图'),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ---- 弹层可视化 ----

  Widget _deptTile(BuildContext context, DepartmentNode node, int depth) {
    final theme = Theme.of(context);
    final members = _membersOf(node);
    final isRoot = depth == 0;
    final collapsed = _collapsed.contains(node.id);
    final hasChildren = node.children.isNotEmpty;
    final headcount = node.headcount ?? members.length;

    final card = Container(
      margin: const EdgeInsets.only(bottom: UtenSpacing.s8),
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        borderRadius: UtenRadius.lgAll,
        border: Border.all(
          color: isRoot
              ? theme.colorScheme.primary.withValues(alpha: 0.5)
              : theme.colorScheme.outlineVariant,
        ),
        boxShadow: isRoot
            ? [
                BoxShadow(
                  color: theme.colorScheme.primary.withValues(alpha: 0.08),
                  blurRadius: 8,
                  offset: const Offset(0, 2),
                ),
              ]
            : null,
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 节点头：名称 + 人数 + 负责人 chip + 折叠钮
          InkWell(
            onTap: hasChildren
                ? () => setState(() {
                    collapsed
                        ? _collapsed.remove(node.id)
                        : _collapsed.add(node.id);
                  })
                : null,
            child: Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(
                horizontal: UtenSpacing.s12,
                vertical: UtenSpacing.s8,
              ),
              color: isRoot
                  ? theme.colorScheme.primaryContainer
                  : theme.colorScheme.surfaceContainerHighest
                        .withValues(alpha: 0.6),
              child: Row(
                children: [
                  if (hasChildren)
                    Icon(
                      collapsed
                          ? Icons.chevron_right_rounded
                          : Icons.expand_more_rounded,
                      size: 18,
                      color: theme.colorScheme.onSurfaceVariant,
                    )
                  else
                    const SizedBox(width: 18),
                  const SizedBox(width: 4),
                  Expanded(
                    child: Text(
                      node.name,
                      style: theme.textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  if (node.managerName != null)
                    _managerChip(theme, node.managerName!),
                  const SizedBox(width: UtenSpacing.s8),
                  Text(
                    '$headcount 人',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
          ),
          // 负责人归入班组：以首行呈现（非直属标注挂职）
          if (node.managerId != null && node.managerName != null)
            _memberRow(
              theme,
              name: node.managerName!,
              position: _managerIsDirect(node) ? null : '非本部门直属（挂职）',
              badgeLabel: '负责人',
              icon: Icons.star_rounded,
              highlight: true,
            ),
          // 成员行（含领导/班组管理徽章）
          for (final e in members)
            _memberRow(
              theme,
              name: e.fullName,
              position: e.positionName,
              badgeLabel: employeeLeadershipLabel(
                departmentManager: e.departmentManager,
                positionLevel: e.positionLevel,
                leaderRank: e.leaderRank,
              ),
              icon: Icons.person_outline_rounded,
            ),
          if (node.managerId == null && members.isEmpty && !hasChildren)
            Padding(
              padding: const EdgeInsets.all(UtenSpacing.s12),
              child: Text(
                '暂无人员',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ),
        ],
      ),
    );

    final childrenWidgets = collapsed
        ? const <Widget>[]
        : [for (final child in node.children) _deptTile(context, child, depth + 1)];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        card,
        if (childrenWidgets.isNotEmpty)
          // 子级：左侧引导线 + 缩进，层级关系一目了然
          Container(
            margin: const EdgeInsets.only(left: 18, bottom: UtenSpacing.s8),
            padding: const EdgeInsets.only(left: UtenSpacing.s12),
            decoration: BoxDecoration(
              border: Border(
                left: BorderSide(
                  color: theme.colorScheme.outlineVariant,
                  width: 2,
                ),
              ),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: childrenWidgets,
            ),
          ),
      ],
    );
  }

  Widget _managerChip(ThemeData theme, String name) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: theme.colorScheme.tertiaryContainer,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.star_rounded,
            size: 12,
            color: theme.colorScheme.onTertiaryContainer,
          ),
          const SizedBox(width: 3),
          Text(
            '负责人 $name',
            style: theme.textTheme.labelSmall?.copyWith(
              color: theme.colorScheme.onTertiaryContainer,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }

  Widget _memberRow(
    ThemeData theme, {
    required String name,
    String? position,
    String? badgeLabel,
    required IconData icon,
    bool highlight = false,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: UtenSpacing.s12,
        vertical: 6,
      ),
      child: Row(
        children: [
          Icon(
            icon,
            size: 16,
            color: highlight
                ? theme.colorScheme.primary
                : theme.colorScheme.onSurfaceVariant,
          ),
          const SizedBox(width: UtenSpacing.s8),
          Expanded(
            child: Text(
              [name, ?position].join(position == null ? '' : ' · '),
              style: theme.textTheme.bodySmall?.copyWith(
                fontWeight: highlight ? FontWeight.w700 : FontWeight.w400,
              ),
            ),
          ),
          if (badgeLabel != null)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(
                color: theme.colorScheme.secondaryContainer,
                borderRadius: BorderRadius.circular(999),
              ),
              child: Text(
                badgeLabel,
                style: theme.textTheme.labelSmall?.copyWith(
                  color: theme.colorScheme.onSecondaryContainer,
                ),
              ),
            ),
        ],
      ),
    );
  }

  // ---- PDF 打印（A4 竖版，NotoSansSC 完整中文字体） ----

  Future<void> _printPdf() async {
    final root = _root;
    if (root == null || _printing) return;
    setState(() => _printing = true);
    try {
      final fontData = await rootBundle.load('assets/fonts/NotoSansSCFull.ttf');
      final font = pw.Font.ttf(fontData);
      final doc = pw.Document();
      doc.addPage(
        pw.MultiPage(
          pageFormat: PdfPageFormat.a4,
          margin: const pw.EdgeInsets.all(28),
          build: (ctx) => [
            pw.Center(
              child: pw.Text(
                '${widget.node.name} · 组织架构图',
                style: pw.TextStyle(
                  font: font,
                  fontSize: 16,
                  fontWeight: pw.FontWeight.bold,
                ),
              ),
            ),
            pw.SizedBox(height: 4),
            pw.Center(
              child: pw.Text(
                '打印日期：${DateTime.now().toString().substring(0, 10)}',
                style: pw.TextStyle(font: font, fontSize: 9),
              ),
            ),
            pw.SizedBox(height: 12),
            ..._pdfDept(font, root, 0),
          ],
        ),
      );
      await printPdfBytes(await doc.save(), '${widget.node.name}-组织架构图.pdf');
    } catch (_) {
      if (!mounted) return;
      context.appError('生成打印件失败，请稍后重试');
    } finally {
      if (mounted) setState(() => _printing = false);
    }
  }

  String _pdfMemberLine(EmployeeSummary e) {
    final label = employeeLeadershipLabel(
      departmentManager: e.departmentManager,
      positionLevel: e.positionLevel,
      leaderRank: e.leaderRank,
    );
    return '${e.fullName} · ${e.positionName ?? ''}'
        '${label == null ? '' : '（$label）'}';
  }

  List<pw.Widget> _pdfDept(pw.Font font, DepartmentNode node, int depth) {
    final members = _membersOf(node);
    final widgets = <pw.Widget>[
      pw.Padding(
        padding: pw.EdgeInsets.only(left: depth * 18.0, bottom: 4),
        child: pw.Container(
          width: double.infinity,
          color: depth == 0
              ? const PdfColor.fromInt(0xFFDDE7F5)
              : const PdfColor.fromInt(0xFFF1F1F1),
          padding: const pw.EdgeInsets.symmetric(horizontal: 8, vertical: 5),
          child: pw.Row(
            mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
            children: [
              pw.Text(
                node.name,
                style: pw.TextStyle(
                  font: font,
                  fontSize: 11,
                  fontWeight: pw.FontWeight.bold,
                ),
              ),
              pw.Text(
                [
                  if (node.managerName != null) '负责人：${node.managerName}',
                  '${node.headcount ?? members.length} 人',
                ].join(' · '),
                style: pw.TextStyle(font: font, fontSize: 9),
              ),
            ],
          ),
        ),
      ),
      // 负责人归入班组（首行；非直属标注挂职）
      if (node.managerId != null && node.managerName != null)
        pw.Padding(
          padding: pw.EdgeInsets.only(left: depth * 18.0 + 14, bottom: 2),
          child: pw.Text(
            '★ ${node.managerName}（负责人'
            '${_managerIsDirect(node) ? '' : '，非本部门直属（挂职）'}）',
            style: pw.TextStyle(
              font: font,
              fontSize: 9,
              fontWeight: pw.FontWeight.bold,
            ),
          ),
        ),
      for (final e in members)
        pw.Padding(
          padding: pw.EdgeInsets.only(left: depth * 18.0 + 14, bottom: 2),
          child: pw.Text(
            _pdfMemberLine(e),
            style: pw.TextStyle(
              font: font,
              fontSize: 9,
              fontWeight: e.departmentManager
                  ? pw.FontWeight.bold
                  : pw.FontWeight.normal,
            ),
          ),
        ),
      for (final child in node.children) ..._pdfDept(font, child, depth + 1),
    ];
    return widgets;
  }
}
