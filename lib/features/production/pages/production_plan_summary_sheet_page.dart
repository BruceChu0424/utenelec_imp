// 生产备料计划汇总单（生产计划单一键生成与全链路溯源设计 §五 末项）。
//
// 一张汇总单 = 公司头 + 缺车间清单 + 三分区（自制件/采购件/委外件）+ 署名区，
// 不把全部物料混在一张大表，也不拆成一堆零散单据（ERPNext Production Plan 形态）。
// 数据来自当前物料分析视图（页面内存传入，不重算），采购/委外按货品聚合缺口，
// 状态列直接引用真实下游单号（生产计划号 / 采购申请号 / 委外申请号），可打印成 PDF。
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import '../../../components/buttons/uten_back_button.dart';
import '../../../components/buttons/uten_button.dart';
import '../../../components/layout/uten_app_bar.dart';
import '../../../core/print/pdf_printer.dart';
import '../../../core/theme/uten_colors.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../core/ui/app_notification.dart';
import '../../../shared/providers/session_provider.dart';
import '../models/production_material_analysis.dart';
import '../repositories/production_repository.dart';

class ProductionPlanSummarySheetPage extends ConsumerStatefulWidget {
  const ProductionPlanSummarySheetPage({super.key, required this.analysis});

  final ProductionMaterialAnalysisView analysis;

  @override
  ConsumerState<ProductionPlanSummarySheetPage> createState() =>
      _ProductionPlanSummarySheetPageState();
}

class _ProductionPlanSummarySheetPageState
    extends ConsumerState<ProductionPlanSummarySheetPage> {
  /// goodsId → 默认车间名（车间偏好学习值；未维护的进缺车间清单）。
  Map<String, String> _defaultWorkshops = const {};
  bool _workshopsLoaded = false;
  bool _printing = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _loadWorkshops());
  }

  Future<void> _loadWorkshops() async {
    final goodsIds = {
      for (final product in widget.analysis.products)
        if (product.goodsId != null) product.goodsId!,
    };
    var result = <String, String>{};
    try {
      final fetched = await ref
          .read(productionPlanRepositoryProvider)
          .defaultWorkshops(goodsIds);
      result = {
        for (final entry in fetched.entries)
          entry.key: entry.value.departmentName ?? entry.value.departmentId,
      };
    } catch (_) {
      // 预填失败不阻断汇总单：全部按「未维护」列出。
    }
    if (!mounted) return;
    setState(() {
      _defaultWorkshops = result;
      _workshopsLoaded = true;
    });
  }

  // ===== 数据加工 =====

  /// 自制件分区行：一个产品一行（根产品 + MAKE_COMPONENT 子件）。
  List<_MakeRow> get _makeRows => [
    for (final product in widget.analysis.products)
      _MakeRow(
        label: product.goodsName ?? product.goodsCode ?? '未命名',
        code: product.goodsCode,
        unit: product.unitName,
        requiredQty: product.requestedQty,
        readyQty: product.readyNowQty,
        workshop: product.goodsId == null
            ? null
            : _defaultWorkshops[product.goodsId!],
        status: _makeStatus(product),
        source: product.sourceType == 'MAKE_COMPONENT'
            ? '自制备料任务'
            : (product.orderNo ?? product.sourceRef ?? '生产需求'),
      ),
  ];

  String _makeStatus(ProductionMaterialAnalysisProduct product) {
    if (product.latestPlanNo != null) return product.latestPlanNo!;
    if (product.approvedQty > 0) return '计划已下达';
    if (product.submittedQty > 0) return '计划审批中';
    return '待安排';
  }

  /// 采购/委外分区行：按货品（+颜色）聚合缺口，同货多路径不重复开口。
  List<_SupplyRow> _supplyRows(MaterialSupplyRoute route) {
    final groups = <String, _SupplyRow>{};
    for (final material in widget.analysis.materials) {
      // 建议路线不是业务事实：未明确采用前不得进入采购/委外执行分区。
      if (material.confirmedRoute != route ||
          material.requiredQty <= 0 ||
          material.shortageQty <= 0) {
        continue;
      }
      final key =
          '${material.goodsId ?? material.goodsCode ?? material.goodsName}'
          '|${material.colorId ?? ''}|${material.unitId ?? material.unitName ?? ''}';
      final notifiedDoc = material.notifiedTargets
          .where(
            (t) =>
                t.target == route &&
                t.status != 'CANCELLED' &&
                (t.documentNo?.isNotEmpty == true),
          )
          .map((t) => t.documentNo!)
          .toSet();
      final existing = groups[key];
      groups[key] = _SupplyRow(
        label: material.goodsName ?? material.goodsCode ?? '未命名物料',
        code: material.goodsCode,
        spec: material.spec,
        unit: material.unitName,
        requiredQty: (existing?.requiredQty ?? 0) + material.requiredQty,
        allocatedQty:
            (existing?.allocatedQty ?? 0) + material.allocatedAvailableQty,
        shortageQty: (existing?.shortageQty ?? 0) + material.shortageQty,
        documents: {...?existing?.documents, ...notifiedDoc},
      );
    }
    final rows = groups.values.toList()
      ..sort((a, b) => (b.shortageQty).compareTo(a.shortageQty));
    return rows;
  }

  /// 路线未确认的缺口必须单独阻断，不能借系统建议偷偷进入执行分区。
  List<_PendingRouteRow> get _pendingRouteRows {
    final groups = <String, _PendingRouteRow>{};
    for (final material in widget.analysis.materials) {
      if (material.requiredQty <= 0 ||
          material.shortageQty <= 0 ||
          material.confirmedRoute != null) {
        continue;
      }
      final key =
          '${material.goodsId ?? material.goodsCode ?? material.goodsName}'
          '|${material.colorId ?? ''}|${material.unitId ?? material.unitName ?? ''}';
      final existing = groups[key];
      groups[key] = _PendingRouteRow(
        label: material.goodsName ?? material.goodsCode ?? '未命名物料',
        code: material.goodsCode,
        unit: material.unitName,
        shortageQty: (existing?.shortageQty ?? 0) + material.shortageQty,
        suggestion: material.sourceSuggestion,
      );
    }
    return groups.values.toList()
      ..sort((left, right) => right.shortageQty.compareTo(left.shortageQty));
  }

  /// 缺车间清单：有默认车间接口结果后仍无车间的自制件。
  List<_MakeRow> get _missingWorkshopRows => _makeRows
      .where((row) => row.workshop == null || row.workshop!.isEmpty)
      .toList(growable: false);

  String get _warehouseName {
    final id = widget.analysis.warehouseId;
    if (id == null) return '未指定';
    for (final warehouse in widget.analysis.warehouses) {
      if (warehouse.warehouseId == id) {
        return warehouse.warehouseName ?? '未命名仓库';
      }
    }
    return '未指定';
  }

  String get _makerName {
    final user = ref.read(sessionProvider).user;
    return user?.name ?? '—';
  }

  String get _today {
    final now = DateTime.now();
    String two(int n) => n.toString().padLeft(2, '0');
    return '${now.year}-${two(now.month)}-${two(now.day)}';
  }

  // ===== 页面 =====

  @override
  Widget build(BuildContext context) {
    final buyRows = _supplyRows(MaterialSupplyRoute.buy);
    final subcontractRows = _supplyRows(MaterialSupplyRoute.subcontract);
    return Scaffold(
      backgroundColor: Theme.of(context).colorScheme.surfaceContainerLow,
      appBar: UtenAppBar(
        title: '备料计划汇总单',
        leading: UtenBackButton(onPressed: () => Navigator.of(context).pop()),
      ),
      body: SafeArea(
        child: !_workshopsLoaded
            ? const Center(child: CircularProgressIndicator())
            : SingleChildScrollView(
                padding: const EdgeInsets.all(UtenSpacing.s16),
                child: Center(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 794),
                    child: Material(
                      key: const Key('plan-summary-paper'),
                      color: Colors.white,
                      elevation: 3,
                      borderRadius: UtenRadius.smAll,
                      child: Padding(
                        padding: const EdgeInsets.all(UtenSpacing.s24),
                        child: _paperBody(buyRows, subcontractRows),
                      ),
                    ),
                  ),
                ),
              ),
      ),
      bottomNavigationBar: _bottomBar(),
    );
  }

  static const _ink = UtenColors.docInk;
  static const _inkSoft = UtenColors.docInkSoft;
  static const _line = UtenColors.docLine;
  static const _danger = UtenColors.docDanger;

  Widget _paperBody(
    List<_SupplyRow> buyRows,
    List<_SupplyRow> subcontractRows,
  ) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Text(
          '中山市优腾电器有限公司',
          textAlign: TextAlign.center,
          style: TextStyle(
            color: _ink,
            fontSize: 15,
            fontWeight: FontWeight.w700,
            letterSpacing: 3,
          ),
        ),
        const SizedBox(height: UtenSpacing.s4),
        const Text(
          '生产备料计划汇总单',
          textAlign: TextAlign.center,
          style: TextStyle(
            color: _ink,
            fontSize: 22,
            fontWeight: FontWeight.w800,
          ),
        ),
        const SizedBox(height: UtenSpacing.s8),
        Wrap(
          alignment: WrapAlignment.center,
          spacing: UtenSpacing.s16,
          runSpacing: UtenSpacing.s4,
          children: [
            _headFact('开单日期', _today),
            _headFact('制单人', _makerName),
            _headFact('分析仓库', _warehouseName),
            _headFact('分析版本', 'v${widget.analysis.version}'),
          ],
        ),
        const SizedBox(height: UtenSpacing.s16),
        if (_pendingRouteRows.isNotEmpty) ...[
          _pendingRouteBlock(),
          const SizedBox(height: UtenSpacing.s16),
        ],
        if (_missingWorkshopRows.isNotEmpty) ...[
          _missingWorkshopBlock(),
          const SizedBox(height: UtenSpacing.s16),
        ],
        _makeSection(),
        const SizedBox(height: UtenSpacing.s16),
        _supplySection('二、采购件（通知采购部）', buyRows, '采购申请'),
        const SizedBox(height: UtenSpacing.s16),
        _supplySection('三、委外件（通知委外商）', subcontractRows, '委外申请'),
        const SizedBox(height: UtenSpacing.s24),
        _signatureRow(),
      ],
    );
  }

  Widget _headFact(String label, String value) => RichText(
    text: TextSpan(
      style: const TextStyle(color: _ink, fontSize: 12, height: 1.5),
      children: [
        TextSpan(
          text: '$label：',
          style: const TextStyle(fontWeight: FontWeight.w700),
        ),
        TextSpan(text: value),
      ],
    ),
  );

  Widget _missingWorkshopBlock() => Container(
    key: const Key('plan-summary-missing-workshop'),
    padding: const EdgeInsets.all(UtenSpacing.s12),
    decoration: BoxDecoration(
      color: _danger.withValues(alpha: 0.06),
      borderRadius: UtenRadius.mdAll,
      border: Border.all(color: _danger.withValues(alpha: 0.5)),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Row(
          children: [
            Icon(Icons.warning_amber_rounded, size: 18, color: _danger),
            SizedBox(width: UtenSpacing.s4),
            Text(
              '缺车间清单（生成计划单前必须指定）',
              style: TextStyle(color: _danger, fontWeight: FontWeight.w800),
            ),
          ],
        ),
        const SizedBox(height: UtenSpacing.s4),
        for (final row in _missingWorkshopRows)
          Text(
            '· ${row.label}${row.code == null ? '' : '（${row.code}）'}',
            style: const TextStyle(color: _danger, fontSize: 12, height: 1.6),
          ),
        const Text(
          '在计划单中指定并审核后，系统会记住各组件的默认生产车间，下次自动预填。',
          style: TextStyle(color: _inkSoft, fontSize: 11, height: 1.5),
        ),
      ],
    ),
  );

  Widget _pendingRouteBlock() => Container(
    key: const Key('plan-summary-pending-routes'),
    padding: const EdgeInsets.all(UtenSpacing.s12),
    decoration: BoxDecoration(
      color: _danger.withValues(alpha: 0.06),
      borderRadius: UtenRadius.mdAll,
      border: Border.all(color: _danger.withValues(alpha: 0.5)),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Row(
          children: [
            Icon(Icons.alt_route_rounded, size: 18, color: _danger),
            SizedBox(width: UtenSpacing.s4),
            Text(
              '待确认供料路线（确认前不会通知任何部门）',
              style: TextStyle(color: _danger, fontWeight: FontWeight.w800),
            ),
          ],
        ),
        const SizedBox(height: UtenSpacing.s4),
        for (final row in _pendingRouteRows)
          Text(
            '· ${row.label}${row.code == null ? '' : '（${row.code}）'}：'
            '缺 ${_qty(row.shortageQty)}${row.unit ?? ''}'
            '${row.suggestion == null ? '' : '，系统建议${_routeLabel(row.suggestion!)}'}',
            style: const TextStyle(color: _danger, fontSize: 12, height: 1.6),
          ),
        const Text(
          '请返回物料分析，明确点击“采用采购 / 委外 / 自制”后再生成汇总。',
          style: TextStyle(color: _inkSoft, fontSize: 11, height: 1.5),
        ),
      ],
    ),
  );

  Widget _sectionTitle(String title) => Container(
    padding: const EdgeInsets.symmetric(
      horizontal: UtenSpacing.s8,
      vertical: UtenSpacing.s4,
    ),
    color: UtenColors.docPaperTint,
    child: Text(
      title,
      style: const TextStyle(color: _ink, fontWeight: FontWeight.w800),
    ),
  );

  Widget _makeSection() {
    final rows = _makeRows;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _sectionTitle('一、自制件（按组件安排车间生产）'),
        _tableHeader(const ['产品 / 组件', '本批需求', '可生产', '默认车间', '状态', '来源']),
        if (rows.isEmpty)
          _emptyRow('本批没有自制件')
        else
          for (final row in rows)
            _tableRow([
              '${row.label}${row.code == null ? '' : '\n${row.code}'}',
              '${_qty(row.requiredQty)}${row.unit ?? ''}',
              '${_qty(row.readyQty)}${row.unit ?? ''}',
              row.workshop?.isNotEmpty == true ? row.workshop! : '待指定',
              row.status,
              row.source,
            ], warn: row.workshop == null || row.workshop!.isEmpty),
      ],
    );
  }

  Widget _supplySection(String title, List<_SupplyRow> rows, String docLabel) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _sectionTitle(title),
        _tableHeader(const ['物料', '需求', '本批已分配', '缺口', '状态']),
        if (rows.isEmpty)
          _emptyRow('本批没有${docLabel == '采购申请' ? '采购' : '委外'}缺料')
        else
          for (final row in rows)
            _tableRow([
              '${row.label}${row.code == null ? '' : '\n${row.code}'}'
                  '${row.spec == null ? '' : ' · ${row.spec}'}',
              '${_qty(row.requiredQty)}${row.unit ?? ''}',
              _qty(row.allocatedQty),
              _qty(row.shortageQty),
              row.documents.isEmpty ? '待通知' : row.documents.join('\n'),
            ], warn: row.shortageQty > 0 && row.documents.isEmpty),
      ],
    );
  }

  Widget _tableHeader(List<String> columns) => Container(
    padding: const EdgeInsets.symmetric(
      horizontal: UtenSpacing.s8,
      vertical: UtenSpacing.s4,
    ),
    decoration: const BoxDecoration(
      border: Border(bottom: BorderSide(color: _line)),
    ),
    child: Row(
      children: [
        for (var i = 0; i < columns.length; i++)
          Expanded(
            flex: i == 0 ? 3 : 2,
            child: Text(
              columns[i],
              style: const TextStyle(
                color: _inkSoft,
                fontSize: 11,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
      ],
    ),
  );

  Widget _tableRow(List<String> cells, {bool warn = false}) => Container(
    padding: const EdgeInsets.symmetric(
      horizontal: UtenSpacing.s8,
      vertical: UtenSpacing.s8,
    ),
    decoration: BoxDecoration(
      color: warn ? _danger.withValues(alpha: 0.04) : null,
      border: const Border(bottom: BorderSide(color: _line)),
    ),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (var i = 0; i < cells.length; i++)
          Expanded(
            flex: i == 0 ? 3 : 2,
            child: Text(
              cells[i],
              style: TextStyle(
                color: warn && i > 0 ? _danger : _ink,
                fontSize: 12,
                height: 1.5,
                fontWeight: i == 0 ? FontWeight.w600 : FontWeight.normal,
              ),
            ),
          ),
      ],
    ),
  );

  Widget _emptyRow(String text) => Container(
    padding: const EdgeInsets.all(UtenSpacing.s12),
    decoration: const BoxDecoration(
      border: Border(bottom: BorderSide(color: _line)),
    ),
    child: Text(
      text,
      textAlign: TextAlign.center,
      style: const TextStyle(color: _inkSoft, fontSize: 12),
    ),
  );

  Widget _signatureRow() => const Row(
    children: [
      Expanded(child: _SignatureCell('制单')),
      Expanded(child: _SignatureCell('审核')),
      Expanded(child: _SignatureCell('车间会签')),
      Expanded(child: _SignatureCell('采购')),
      Expanded(child: _SignatureCell('委外')),
    ],
  );

  Widget _bottomBar() => Material(
    elevation: 8,
    color: Theme.of(context).colorScheme.surface,
    child: SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.all(UtenSpacing.s12),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.end,
          children: [
            UtenButton(
              key: const Key('plan-summary-print'),
              icon: Icons.print_outlined,
              isLoading: _printing,
              onPressed: !_workshopsLoaded || _printing ? null : _print,
              child: const Text('打印 / 导出 PDF'),
            ),
          ],
        ),
      ),
    ),
  );

  // ===== PDF =====

  Future<void> _print() async {
    if (_printing) return;
    setState(() => _printing = true);
    try {
      final bytes = await _buildPdf();
      if (!mounted) return;
      final ok = await printPdfBytes(bytes, '生产备料计划汇总单-$_today.pdf');
      if (!mounted) return;
      if (!ok) context.appWarning('打印流程未完成');
    } catch (error) {
      if (!mounted) return;
      context.appError('生成 PDF 失败：$error', force: true);
    } finally {
      if (mounted) setState(() => _printing = false);
    }
  }

  Future<Uint8List> _buildPdf() async {
    final fontData = await rootBundle.load('assets/fonts/NotoSansSCFull.ttf');
    final font = pw.Font.ttf(fontData);
    final doc = pw.Document(
      theme: pw.ThemeData.withFont(base: font, bold: font),
    );
    final buyRows = _supplyRows(MaterialSupplyRoute.buy);
    final subcontractRows = _supplyRows(MaterialSupplyRoute.subcontract);
    doc.addPage(
      pw.MultiPage(
        pageFormat: PdfPageFormat.a4,
        margin: const pw.EdgeInsets.all(32),
        build: (context) => [
          pw.Center(
            child: pw.Text(
              '中山市优腾电器有限公司',
              style: const pw.TextStyle(
                fontSize: 12,
                fontWeight: pw.FontWeight.bold,
                letterSpacing: 2,
              ),
            ),
          ),
          pw.SizedBox(height: 4),
          pw.Center(
            child: pw.Text(
              '生产备料计划汇总单',
              style: const pw.TextStyle(
                fontSize: 18,
                fontWeight: pw.FontWeight.bold,
              ),
            ),
          ),
          pw.SizedBox(height: 6),
          pw.Center(
            child: pw.Text(
              '开单日期：$_today    制单人：$_makerName    '
              '分析仓库：$_warehouseName    分析版本：v${widget.analysis.version}',
              style: const pw.TextStyle(fontSize: 9),
            ),
          ),
          pw.SizedBox(height: 12),
          if (_missingWorkshopRows.isNotEmpty) ...[
            pw.Container(
              padding: const pw.EdgeInsets.all(8),
              decoration: pw.BoxDecoration(
                border: pw.Border.all(color: PdfColors.red700),
              ),
              child: pw.Column(
                crossAxisAlignment: pw.CrossAxisAlignment.start,
                children: [
                  pw.Text(
                    '缺车间清单（生成计划单前必须指定）',
                    style: const pw.TextStyle(
                      fontSize: 10,
                      fontWeight: pw.FontWeight.bold,
                      color: PdfColors.red700,
                    ),
                  ),
                  for (final row in _missingWorkshopRows)
                    pw.Text(
                      '· ${row.label}${row.code == null ? '' : '（${row.code}）'}',
                      style: const pw.TextStyle(
                        fontSize: 9,
                        color: PdfColors.red700,
                      ),
                    ),
                ],
              ),
            ),
            pw.SizedBox(height: 10),
          ],
          if (_pendingRouteRows.isNotEmpty) ...[
            pw.Container(
              padding: const pw.EdgeInsets.all(8),
              decoration: pw.BoxDecoration(
                border: pw.Border.all(color: PdfColors.red700),
              ),
              child: pw.Column(
                crossAxisAlignment: pw.CrossAxisAlignment.start,
                children: [
                  pw.Text(
                    '待确认供料路线（确认前不会通知任何部门）',
                    style: const pw.TextStyle(
                      fontSize: 10,
                      fontWeight: pw.FontWeight.bold,
                      color: PdfColors.red700,
                    ),
                  ),
                  for (final row in _pendingRouteRows)
                    pw.Text(
                      '· ${row.label}${row.code == null ? '' : '（${row.code}）'}：'
                      '缺 ${_qty(row.shortageQty)}${row.unit ?? ''}'
                      '${row.suggestion == null ? '' : '，系统建议${_routeLabel(row.suggestion!)}'}',
                      style: const pw.TextStyle(
                        fontSize: 9,
                        color: PdfColors.red700,
                      ),
                    ),
                ],
              ),
            ),
            pw.SizedBox(height: 10),
          ],
          _pdfSectionTitle('一、自制件（按组件安排车间生产）'),
          _pdfTable(
            const ['产品 / 组件', '本批需求', '可生产', '默认车间', '状态', '来源'],
            [
              for (final row in _makeRows)
                [
                  '${row.label}${row.code == null ? '' : '\n${row.code}'}',
                  '${_qty(row.requiredQty)}${row.unit ?? ''}',
                  '${_qty(row.readyQty)}${row.unit ?? ''}',
                  row.workshop?.isNotEmpty == true ? row.workshop! : '待指定',
                  row.status,
                  row.source,
                ],
            ],
          ),
          pw.SizedBox(height: 10),
          _pdfSectionTitle('二、采购件（通知采购部）'),
          _pdfTable(
            const ['物料', '需求', '本批已分配', '缺口', '状态'],
            [for (final row in buyRows) _pdfSupplyCells(row)],
          ),
          pw.SizedBox(height: 10),
          _pdfSectionTitle('三、委外件（通知委外商）'),
          _pdfTable(
            const ['物料', '需求', '本批已分配', '缺口', '状态'],
            [for (final row in subcontractRows) _pdfSupplyCells(row)],
          ),
          pw.SizedBox(height: 24),
          pw.Row(
            mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
            children: [
              for (final label in const ['制单', '审核', '车间会签', '采购', '委外'])
                pw.Text(
                  '$label：____________',
                  style: const pw.TextStyle(fontSize: 10),
                ),
            ],
          ),
        ],
      ),
    );
    return doc.save();
  }

  List<String> _pdfSupplyCells(_SupplyRow row) => [
    '${row.label}${row.code == null ? '' : '\n${row.code}'}'
        '${row.spec == null ? '' : ' · ${row.spec}'}',
    '${_qty(row.requiredQty)}${row.unit ?? ''}',
    _qty(row.allocatedQty),
    _qty(row.shortageQty),
    row.documents.isEmpty ? '待通知' : row.documents.join('\n'),
  ];

  pw.Widget _pdfSectionTitle(String title) => pw.Container(
    width: double.infinity,
    padding: const pw.EdgeInsets.symmetric(horizontal: 6, vertical: 4),
    color: const PdfColor(0.95, 0.97, 0.96),
    child: pw.Text(
      title,
      style: const pw.TextStyle(fontSize: 11, fontWeight: pw.FontWeight.bold),
    ),
  );

  pw.Widget _pdfTable(
    List<String> columns,
    List<List<String>> rows,
  ) => pw.Table(
    border: const pw.TableBorder(
      horizontalInside: pw.BorderSide(
        color: PdfColor(0.85, 0.89, 0.87),
        width: 0.5,
      ),
      bottom: pw.BorderSide(color: PdfColor(0.85, 0.89, 0.87), width: 0.5),
    ),
    columnWidths: {
      for (var i = 0; i < columns.length; i++)
        i: i == 0 ? const pw.FlexColumnWidth(3) : const pw.FlexColumnWidth(2),
    },
    children: [
      pw.TableRow(
        children: [
          for (final column in columns)
            pw.Padding(
              padding: const pw.EdgeInsets.symmetric(
                horizontal: 6,
                vertical: 3,
              ),
              child: pw.Text(
                column,
                style: const pw.TextStyle(
                  fontSize: 8,
                  fontWeight: pw.FontWeight.bold,
                  color: PdfColor(0.32, 0.38, 0.35),
                ),
              ),
            ),
        ],
      ),
      if (rows.isEmpty)
        pw.TableRow(
          children: [
            pw.Padding(
              padding: const pw.EdgeInsets.all(8),
              child: pw.Text('本批无此类明细', style: const pw.TextStyle(fontSize: 9)),
            ),
            for (var i = 1; i < columns.length; i++) pw.SizedBox(),
          ],
        )
      else
        for (final row in rows)
          pw.TableRow(
            children: [
              for (final cell in row)
                pw.Padding(
                  padding: const pw.EdgeInsets.symmetric(
                    horizontal: 6,
                    vertical: 4,
                  ),
                  child: pw.Text(
                    cell,
                    style: const pw.TextStyle(fontSize: 9, lineSpacing: 1.2),
                  ),
                ),
            ],
          ),
    ],
  );
}

class _MakeRow {
  const _MakeRow({
    required this.label,
    this.code,
    this.unit,
    required this.requiredQty,
    required this.readyQty,
    this.workshop,
    required this.status,
    required this.source,
  });

  final String label;
  final String? code;
  final String? unit;
  final double requiredQty;
  final double readyQty;
  final String? workshop;
  final String status;
  final String source;
}

class _SupplyRow {
  const _SupplyRow({
    required this.label,
    this.code,
    this.spec,
    this.unit,
    required this.requiredQty,
    required this.allocatedQty,
    required this.shortageQty,
    required this.documents,
  });

  final String label;
  final String? code;
  final String? spec;
  final String? unit;
  final double requiredQty;
  final double allocatedQty;
  final double shortageQty;
  final Set<String> documents;
}

class _PendingRouteRow {
  const _PendingRouteRow({
    required this.label,
    this.code,
    this.unit,
    required this.shortageQty,
    this.suggestion,
  });

  final String label;
  final String? code;
  final String? unit;
  final double shortageQty;
  final MaterialSupplyRoute? suggestion;
}

String _routeLabel(MaterialSupplyRoute route) => switch (route) {
  MaterialSupplyRoute.buy => '采购',
  MaterialSupplyRoute.subcontract => '委外',
  MaterialSupplyRoute.make => '自制',
};

class _SignatureCell extends StatelessWidget {
  const _SignatureCell(this.label);

  final String label;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: UtenSpacing.s8),
    child: Text(
      '$label：____________',
      style: const TextStyle(
        color: UtenColors.docInkSoft,
        fontSize: 11,
        height: 1.8,
      ),
    ),
  );
}

String _qty(double? value) {
  if (value == null) return '—';
  if (value == value.roundToDouble()) return value.toStringAsFixed(0);
  return value
      .toStringAsFixed(4)
      .replaceFirst(RegExp(r'0+$'), '')
      .replaceFirst(RegExp(r'\.$'), '');
}
