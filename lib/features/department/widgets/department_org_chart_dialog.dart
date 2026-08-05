// 部门组织架构图：弹层可视化 + A4 PDF 打印。
// 入口：部门管理 → 部门概览卡「部门架构图」按钮。
// 数据：departmentRepository.subtree（部门树）+ 员工列表（includeSubtree）按部门分组。
// 打印：pdf 包生成 A4 竖版（NotoSansSC 完整中文字体）→ 系统打印对话框（core/print）。
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import '../../../components/buttons/uten_button.dart';
import '../../../core/print/pdf_printer.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../core/ui/app_notification.dart';
import '../../employee/models/employee_api_models.dart';
import '../../employee/repositories/employee_repository.dart';
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

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Dialog(
      clipBehavior: Clip.antiAlias,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 640, maxHeight: 720),
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
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  UtenButton(
                    type: UtenButtonType.filled,
                    icon: Icons.print_outlined,
                    isLoading: _printing,
                    onPressed: (_loading || _error != null) ? null : _printPdf,
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
    final employees = _byDept[node.id] ?? const <EmployeeSummary>[];
    final isRoot = depth == 0;
    return Padding(
      padding: EdgeInsets.only(left: depth == 0 ? 0 : 20, bottom: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(
              color: isRoot
                  ? theme.colorScheme.primaryContainer
                  : theme.colorScheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(10),
            ),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    node.name,
                    style: theme.textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                if (node.managerName != null)
                  Text(
                    '负责人：${node.managerName}',
                    style: theme.textTheme.bodySmall,
                  ),
                if (node.headcount != null) ...[
                  const SizedBox(width: 8),
                  Text('${node.headcount} 人', style: theme.textTheme.bodySmall),
                ],
              ],
            ),
          ),
          for (final e in employees)
            Padding(
              padding: const EdgeInsets.only(left: 16, top: 4),
              child: Row(
                children: [
                  Icon(
                    Icons.person_outline_rounded,
                    size: 14,
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      '${e.fullName} · ${e.positionName ?? ''}',
                      style: theme.textTheme.bodySmall?.copyWith(
                        fontWeight: e.departmentManager
                            ? FontWeight.w700
                            : FontWeight.w400,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          for (final child in node.children) _deptTile(context, child, depth + 1),
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

  List<pw.Widget> _pdfDept(pw.Font font, DepartmentNode node, int depth) {
    final employees = _byDept[node.id] ?? const <EmployeeSummary>[];
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
                  if (node.headcount != null) '${node.headcount} 人',
                ].join(' · '),
                style: pw.TextStyle(font: font, fontSize: 9),
              ),
            ],
          ),
        ),
      ),
      for (final e in employees)
        pw.Padding(
          padding: pw.EdgeInsets.only(left: depth * 18.0 + 14, bottom: 2),
          child: pw.Text(
            '${e.fullName} · ${e.positionName ?? ''}${e.departmentManager ? '（负责人）' : ''}',
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
