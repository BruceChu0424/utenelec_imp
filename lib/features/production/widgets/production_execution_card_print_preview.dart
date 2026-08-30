import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import '../../../components/buttons/uten_button.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/print/pdf_printer.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../core/ui/app_notification.dart';
import '../models/production_execution_planning.dart';
import '../models/production_work_card.dart';

/// Opens a responsive preview for the persisted work-card projection.
///
/// The loader is called again immediately before printing so a cancelled or
/// reversed package is rejected instead of producing a stale reprint.
Future<void> showProductionExecutionCardPrintPreview(
  BuildContext context, {
  required Future<ProductionWorkCardView> Function() loader,
}) {
  return showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (_) => _ProductionExecutionCardPrintDialog(loader: loader),
  );
}

class _ProductionExecutionCardPrintDialog extends StatefulWidget {
  const _ProductionExecutionCardPrintDialog({required this.loader});

  final Future<ProductionWorkCardView> Function() loader;

  @override
  State<_ProductionExecutionCardPrintDialog> createState() =>
      _ProductionExecutionCardPrintDialogState();
}

class _ProductionExecutionCardPrintDialogState
    extends State<_ProductionExecutionCardPrintDialog> {
  ProductionWorkCardView? _view;
  String? _error;
  bool _loading = true;
  bool _printing = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    if (!mounted) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final view = await widget.loader();
      if (!mounted) return;
      if (!view.isPrintable) {
        throw StateError('计划包不是可打印的已确认执行包');
      }
      setState(() {
        _view = view;
        _loading = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _view = null;
        _loading = false;
        _error = error is ApiException
            ? error.message
            : '生产执行工卡加载失败，请确认计划包仍处于已确认状态';
      });
    }
  }

  Future<void> _print() async {
    if (_printing) return;
    setState(() => _printing = true);
    try {
      final latest = await widget.loader();
      if (!latest.isPrintable) {
        throw StateError('计划包已失效，不能继续打印');
      }
      if (mounted) setState(() => _view = latest);
      final bytes = await buildProductionExecutionCardPdf(latest);
      await printPdfBytes(
        bytes,
        '生产计划单_${_safeFilename(latest.planBillNo ?? latest.planId)}_执行工卡.pdf',
      );
    } on ApiException catch (error) {
      if (mounted) context.appError(error.message, force: true);
    } catch (_) {
      if (mounted) {
        context.appError('生成工卡失败；请刷新计划包状态后重试', force: true);
      }
    } finally {
      if (mounted) setState(() => _printing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final size = MediaQuery.sizeOf(context);
    final compact = size.width < 600;
    return Dialog(
      insetPadding: EdgeInsets.all(compact ? UtenSpacing.s8 : UtenSpacing.s24),
      clipBehavior: Clip.antiAlias,
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: 1120,
          maxHeight: size.height * 0.92,
        ),
        child: SizedBox(
          width: double.infinity,
          child: Column(
            children: [
              _header(theme),
              const Divider(height: 1),
              Expanded(child: _body(theme)),
              const Divider(height: 1),
              _footer(compact),
            ],
          ),
        ),
      ),
    );
  }

  Widget _header(ThemeData theme) {
    final view = _view;
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        UtenSpacing.s16,
        UtenSpacing.s12,
        UtenSpacing.s8,
        UtenSpacing.s12,
      ),
      child: Row(
        children: [
          Icon(Icons.print_outlined, color: theme.colorScheme.primary),
          const SizedBox(width: UtenSpacing.s8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'A4 生产计划单 · 流水线执行工卡',
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w800,
                  ),
                ),
                Text(
                  view == null
                      ? '正在读取已确认计划包…'
                      : '${view.planBillNo ?? view.planId} · '
                            '${view.cards.length} 张执行工卡 · '
                            '计划包 ${_shortId(view.packageId)}',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
          IconButton(
            onPressed: _printing ? null : () => Navigator.pop(context),
            tooltip: '关闭生产计划打印预览',
            icon: const Icon(Icons.close_rounded),
          ),
        ],
      ),
    );
  }

  Widget _body(ThemeData theme) {
    if (_loading) {
      return const Center(child: CircularProgressIndicator(strokeWidth: 2.5));
    }
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(UtenSpacing.s24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.print_disabled_outlined,
                color: theme.colorScheme.error,
                size: 40,
              ),
              const SizedBox(height: UtenSpacing.s12),
              Text(_error!, textAlign: TextAlign.center),
              const SizedBox(height: UtenSpacing.s12),
              UtenButton(
                type: UtenButtonType.secondary,
                icon: Icons.refresh_rounded,
                onPressed: _load,
                child: const Text('重新读取'),
              ),
            ],
          ),
        ),
      );
    }
    final view = _view!;
    return ListView.builder(
      padding: const EdgeInsets.all(UtenSpacing.s12),
      itemCount: view.cards.length + 1,
      itemBuilder: (context, index) {
        if (index == 0) return _sourceNotice(theme, view);
        return Padding(
          padding: const EdgeInsets.only(top: UtenSpacing.s12),
          child: _workCardPreview(theme, view, view.cards[index - 1]),
        );
      },
    );
  }

  Widget _sourceNotice(ThemeData theme, ProductionWorkCardView view) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: theme.colorScheme.primary.withValues(alpha: 0.07),
        borderRadius: UtenRadius.smAll,
        border: Border.all(
          color: theme.colorScheme.primary.withValues(alpha: 0.28),
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.all(UtenSpacing.s12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(
              Icons.verified_outlined,
              color: theme.colorScheme.primary,
              size: 20,
            ),
            const SizedBox(width: UtenSpacing.s8),
            Expanded(
              child: Text(
                '工卡来自已确认计划包、执行分段和物料需求的只读投影。'
                '打印或补打不会锁料、开单或改变状态；货品、颜色、单位和人员名称按打印时当前主档解析。'
                '版本 V${view.executionModelVersion}.${view.packageLockVersion}。',
                style: theme.textTheme.bodySmall,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _workCardPreview(
    ThemeData theme,
    ProductionWorkCardView view,
    ProductionWorkCard card,
  ) {
    final zeroMaterialText = productionZeroMaterialReasonText(
      card.materialRequirementMode,
      card.zeroMaterialReason,
    );
    return Card(
      margin: EdgeInsets.zero,
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: UtenRadius.mdAll,
        side: BorderSide(color: theme.colorScheme.outlineVariant),
      ),
      child: Padding(
        padding: const EdgeInsets.all(UtenSpacing.s12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Wrap(
              alignment: WrapAlignment.spaceBetween,
              crossAxisAlignment: WrapCrossAlignment.center,
              runSpacing: UtenSpacing.s8,
              children: [
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '${card.segmentCode} · ${_value(card.productName)}',
                      style: theme.textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    Text(
                      [
                        card.productCode,
                        card.productSpec,
                        card.productColorName,
                        card.productUnitName,
                      ].where(_present).join(' · '),
                      style: theme.textTheme.bodySmall,
                    ),
                  ],
                ),
                Chip(
                  avatar: Icon(
                    card.status == 'READY'
                        ? Icons.play_circle_outline
                        : Icons.hourglass_bottom_rounded,
                    size: 18,
                  ),
                  label: Text(
                    _statusLabel(
                      card.status,
                      autoPromoteWhenReady: card.autoPromoteWhenReady,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: UtenSpacing.s8),
            Wrap(
              spacing: UtenSpacing.s16,
              runSpacing: UtenSpacing.s8,
              children: [
                _previewField('实排数量', _qty(card.plannedQty)),
                _previewField(
                  '车间 / 班组',
                  '${_value(card.workshopName)} / ${_value(card.teamName)}',
                ),
                _previewField('负责人', _value(card.responsibleEmployeeName)),
                _previewField(
                  '计划开工 / 完工',
                  '${_value(card.planBeginDate)} / ${_value(card.planEndDate)}',
                ),
                _previewField('发料仓', _value(view.warehouseName)),
                _previewField('领料单', _value(card.drawBillNos)),
              ],
            ),
            const SizedBox(height: UtenSpacing.s8),
            if (zeroMaterialText != null)
              Container(
                padding: const EdgeInsets.all(UtenSpacing.s12),
                decoration: BoxDecoration(
                  color: theme.colorScheme.primaryContainer.withValues(
                    alpha: 0.45,
                  ),
                  borderRadius: UtenRadius.smAll,
                ),
                child: Text(
                  zeroMaterialText,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
              )
            else
              SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: DataTable(
                  headingRowHeight: 40,
                  dataRowMinHeight: 40,
                  dataRowMaxHeight: 56,
                  columns: const [
                    DataColumn(label: Text('物料编号 / 名称')),
                    DataColumn(label: Text('规格 / 颜色')),
                    DataColumn(label: Text('单位')),
                    DataColumn(label: Text('用量口径')),
                    DataColumn(numeric: true, label: Text('需求数量')),
                    DataColumn(numeric: true, label: Text('现货承诺')),
                    DataColumn(numeric: true, label: Text('缺口')),
                    DataColumn(label: Text('供给路线')),
                  ],
                  rows: [
                    for (final material in card.materials)
                      DataRow(
                        cells: [
                          DataCell(
                            Text(
                              [
                                material.goodsCode,
                                material.goodsName,
                              ].where(_present).join(' · '),
                            ),
                          ),
                          DataCell(
                            Text(
                              [
                                material.spec,
                                material.colorName,
                              ].where(_present).join(' · '),
                            ),
                          ),
                          DataCell(Text(_value(material.unitName))),
                          DataCell(
                            Text(
                              formatProductionWorkCardMaterialUsage(material),
                            ),
                          ),
                          DataCell(Text(_qty(material.requiredQty))),
                          DataCell(Text(_qty(material.stockAllocatedQty))),
                          DataCell(Text(_qty(material.shortageQty))),
                          DataCell(Text(_routeLabel(material.supplyRoute))),
                        ],
                      ),
                  ],
                ),
              ),
            if (_present(card.requestNote) || _present(card.remark)) ...[
              const SizedBox(height: UtenSpacing.s8),
              Text(
                '要求：${[card.requestNote, card.remark].where(_present).join('；')}',
                style: theme.textTheme.bodySmall,
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _previewField(String label, String value) {
    return ConstrainedBox(
      constraints: const BoxConstraints(minWidth: 150, maxWidth: 260),
      child: Text('$label：$value'),
    );
  }

  Widget _footer(bool compact) {
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.all(UtenSpacing.s12),
        child: Wrap(
          alignment: WrapAlignment.end,
          spacing: UtenSpacing.s8,
          runSpacing: UtenSpacing.s8,
          children: [
            UtenButton(
              type: UtenButtonType.secondary,
              onPressed: _printing ? null : () => Navigator.pop(context),
              child: const Text('关闭'),
            ),
            UtenButton(
              icon: Icons.print_outlined,
              isLoading: _printing,
              onPressed: _view?.isPrintable == true && !_printing
                  ? _print
                  : null,
              child: Text(compact ? '打印全部' : '打印全部 A4 计划工卡'),
            ),
          ],
        ),
      ),
    );
  }
}

/// Generates one landscape A4 work card per persisted execution segment.
Future<Uint8List> buildProductionExecutionCardPdf(
  ProductionWorkCardView view,
) async {
  if (!view.isPrintable) {
    throw StateError('Only a confirmed V1 package can produce work cards');
  }
  final fontData = await rootBundle.load('assets/fonts/NotoSansSCFull.ttf');
  final font = pw.Font.ttf(fontData);
  final document = pw.Document(
    title: '生产计划单_${view.planBillNo ?? view.planId}_执行工卡',
    author: 'Uten IMP',
    creator: 'Uten IMP production planning',
    subject: 'Confirmed production execution package work cards',
    theme: pw.ThemeData.withFont(base: font, bold: font),
  );

  for (final card in view.cards) {
    document.addPage(
      pw.MultiPage(
        pageFormat: PdfPageFormat.a4.landscape,
        margin: const pw.EdgeInsets.fromLTRB(24, 22, 24, 22),
        header: (_) => _pdfHeader(view, card),
        footer: (context) => _pdfFooter(context, view, card),
        build: (_) => [
          _pdfMetadata(view, card),
          pw.SizedBox(height: 8),
          _pdfMaterialTable(card),
          pw.SizedBox(height: 8),
          _pdfNotes(card),
          pw.SizedBox(height: 14),
          _pdfSignatures(),
        ],
      ),
    );
  }
  return document.save();
}

pw.Widget _pdfHeader(ProductionWorkCardView view, ProductionWorkCard card) {
  final product = [
    card.productNo,
    card.productCode,
    card.productName,
    card.productSpec,
    card.productModel,
  ].where(_present).join(' / ');
  final quantity = [
    _qty(card.plannedQty),
    card.productUnitName,
  ].where(_present).join(' ');
  final assignment = [
    card.workshopName,
    card.teamName,
    card.responsibleEmployeeName,
  ].where(_present).join(' / ');
  return pw.Padding(
    padding: const pw.EdgeInsets.only(bottom: 8),
    child: pw.Row(
      crossAxisAlignment: pw.CrossAxisAlignment.start,
      children: [
        pw.Expanded(
          child: pw.Column(
            crossAxisAlignment: pw.CrossAxisAlignment.start,
            children: [
              pw.Text(
                '中山市优腾电器有限公司',
                style: const pw.TextStyle(
                  fontSize: 10,
                  fontWeight: pw.FontWeight.bold,
                ),
              ),
              pw.SizedBox(height: 2),
              pw.Text(
                '生产计划单（流水线执行工卡）',
                style: const pw.TextStyle(
                  fontSize: 18,
                  fontWeight: pw.FontWeight.bold,
                ),
              ),
              pw.SizedBox(height: 3),
              pw.Text(
                '计划单 ${_value(view.planBillNo)}  ·  执行分段 ${card.segmentCode}'
                '  ·  开单 ${_value(view.planBillDate)}  ·  交期 ${_value(view.deliveryDate)}',
                style: const pw.TextStyle(fontSize: 9),
              ),
              pw.SizedBox(height: 4),
              pw.Text(
                _value(product),
                style: const pw.TextStyle(
                  fontSize: 12,
                  fontWeight: pw.FontWeight.bold,
                ),
              ),
              pw.SizedBox(height: 2),
              pw.Text(
                '本批数量 ${_value(quantity)}  ·  '
                '${_value(assignment)}  ·  '
                '${_value(card.planBeginDate)} 至 ${_value(card.planEndDate)}',
                style: const pw.TextStyle(fontSize: 9),
              ),
            ],
          ),
        ),
        pw.BarcodeWidget(
          barcode: pw.Barcode.code128(),
          data: card.segmentCode,
          width: 170,
          height: 36,
          drawText: false,
          textStyle: const pw.TextStyle(fontSize: 8),
        ),
      ],
    ),
  );
}

pw.Widget _pdfMetadata(ProductionWorkCardView view, ProductionWorkCard card) {
  final product = [
    card.productCode,
    card.productName,
    card.productSpec,
    card.productModel,
  ].where(_present).join(' / ');
  final rows = <List<String>>[
    [
      '产品',
      product,
      '颜色 / 单位',
      '${_value(card.productColorName)} / ${_value(card.productUnitName)}',
    ],
    [
      '实排数量',
      _qty(card.plannedQty),
      '执行状态',
      _statusLabel(
        card.status,
        autoPromoteWhenReady: card.autoPromoteWhenReady,
      ),
    ],
    [
      '车间 / 班组',
      '${_value(card.workshopName)} / ${_value(card.teamName)}',
      '负责人',
      _value(card.responsibleEmployeeName),
    ],
    [
      '计划开工 / 完工',
      '${_value(card.planBeginDate)} / ${_value(card.planEndDate)}',
      '发料仓',
      '${_value(view.warehouseCode)} ${_value(view.warehouseName)}',
    ],
    [
      '销售订单 / 来源行',
      '${_value(card.salesOrderNo)} / ${card.sourceLineNo ?? '—'}',
      '领料单',
      _value(card.drawBillNos),
    ],
    [
      '审核人 / 确认时间',
      '${_value(view.approverName)} / ${_timestamp(view.confirmedAt)}',
      '计划包版本',
      'V${view.executionModelVersion}.${view.packageLockVersion}',
    ],
  ];
  return pw.Table(
    border: pw.TableBorder.all(width: 0.5, color: PdfColors.grey700),
    columnWidths: const {
      0: pw.FixedColumnWidth(78),
      1: pw.FlexColumnWidth(2.5),
      2: pw.FixedColumnWidth(94),
      3: pw.FlexColumnWidth(2.2),
    },
    children: [
      for (final row in rows)
        pw.TableRow(
          children: [
            _pdfCell(row[0], bold: true, background: PdfColors.grey200),
            _pdfCell(row[1]),
            _pdfCell(row[2], bold: true, background: PdfColors.grey200),
            _pdfCell(row[3]),
          ],
        ),
    ],
  );
}

pw.Widget _pdfMaterialTable(ProductionWorkCard card) {
  final zeroMaterialText = productionZeroMaterialReasonText(
    card.materialRequirementMode,
    card.zeroMaterialReason,
  );
  if (zeroMaterialText != null) {
    return pw.Container(
      width: double.infinity,
      padding: const pw.EdgeInsets.all(10),
      decoration: pw.BoxDecoration(
        color: PdfColors.grey200,
        border: pw.Border.all(width: 0.6, color: PdfColors.grey700),
      ),
      child: pw.Text(
        zeroMaterialText,
        style: const pw.TextStyle(fontSize: 10, fontWeight: pw.FontWeight.bold),
      ),
    );
  }
  const headers = [
    '序号',
    '物料编号 / 名称',
    '规格 / 颜色',
    '单位',
    '用量口径',
    '需求数量',
    '现货承诺',
    '缺口',
    '供给路线',
  ];
  return pw.Table(
    border: pw.TableBorder.all(width: 0.45, color: PdfColors.grey700),
    columnWidths: const {
      0: pw.FixedColumnWidth(32),
      1: pw.FlexColumnWidth(2.4),
      2: pw.FlexColumnWidth(1.8),
      3: pw.FixedColumnWidth(42),
      4: pw.FixedColumnWidth(112),
      5: pw.FixedColumnWidth(62),
      6: pw.FixedColumnWidth(62),
      7: pw.FixedColumnWidth(54),
      8: pw.FixedColumnWidth(62),
    },
    children: [
      pw.TableRow(
        repeat: true,
        children: [
          for (final header in headers)
            _pdfCell(
              header,
              bold: true,
              center: true,
              background: PdfColors.grey200,
            ),
        ],
      ),
      for (var index = 0; index < card.materials.length; index++)
        pw.TableRow(
          children: [
            _pdfCell('${index + 1}', center: true),
            _pdfCell(
              [
                card.materials[index].goodsCode,
                card.materials[index].goodsName,
              ].where(_present).join(' / '),
            ),
            _pdfCell(
              [
                card.materials[index].spec,
                card.materials[index].colorName,
              ].where(_present).join(' / '),
            ),
            _pdfCell(_value(card.materials[index].unitName), center: true),
            _pdfCell(
              formatProductionWorkCardMaterialUsage(card.materials[index]),
              center: true,
            ),
            _pdfCell(_qty(card.materials[index].requiredQty), center: true),
            _pdfCell(
              _qty(card.materials[index].stockAllocatedQty),
              center: true,
            ),
            _pdfCell(_qty(card.materials[index].shortageQty), center: true),
            _pdfCell(
              _routeLabel(card.materials[index].supplyRoute),
              center: true,
            ),
          ],
        ),
    ],
  );
}

pw.Widget _pdfNotes(ProductionWorkCard card) {
  final notes = [card.requestNote, card.remark].where(_present).join('；');
  return pw.Container(
    width: double.infinity,
    padding: const pw.EdgeInsets.all(6),
    decoration: pw.BoxDecoration(
      border: pw.Border.all(width: 0.5, color: PdfColors.grey700),
    ),
    child: pw.Text(
      '生产要求 / 备注：${notes.isEmpty ? '—' : notes}',
      style: const pw.TextStyle(fontSize: 8.5),
    ),
  );
}

pw.Widget _pdfSignatures() {
  return pw.Row(
    mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
    children: [
      for (final label in const ['调度确认', '车间接收', '领料交接', '完工确认'])
        pw.SizedBox(
          width: 145,
          child: pw.Text(
            '$label：________________',
            style: const pw.TextStyle(fontSize: 9),
          ),
        ),
    ],
  );
}

pw.Widget _pdfFooter(
  pw.Context context,
  ProductionWorkCardView view,
  ProductionWorkCard card,
) {
  return pw.Padding(
    padding: const pw.EdgeInsets.only(top: 8),
    child: pw.Row(
      mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
      children: [
        pw.Expanded(
          child: pw.Text(
            '打印件非业务事实源 · 名称按当前主档解析 · 计划包 ${_shortId(view.packageId)} · 分段 ${card.segmentCode}',
            style: const pw.TextStyle(fontSize: 7.5, color: PdfColors.grey700),
          ),
        ),
        pw.Text(
          '打印 ${_timestamp(view.generatedAt)}  ·  第 ${context.pageNumber} / ${context.pagesCount} 页',
          style: const pw.TextStyle(fontSize: 7.5, color: PdfColors.grey700),
        ),
      ],
    ),
  );
}

pw.Widget _pdfCell(
  String value, {
  bool bold = false,
  bool center = false,
  PdfColor? background,
}) {
  return pw.Container(
    color: background,
    padding: const pw.EdgeInsets.symmetric(horizontal: 4, vertical: 3),
    child: pw.Text(
      value,
      textAlign: center ? pw.TextAlign.center : pw.TextAlign.left,
      style: pw.TextStyle(
        fontSize: 8,
        fontWeight: bold ? pw.FontWeight.bold : pw.FontWeight.normal,
      ),
    ),
  );
}

String _statusLabel(String status, {bool autoPromoteWhenReady = true}) =>
    switch (status) {
      'READY' => '可开工',
      'WAITING' => autoPromoteWhenReady ? '待料 / 齐套自动转产' : '人工暂缓',
      'DISPATCHED' => '已派工',
      'IN_PROGRESS' => '生产中',
      'COMPLETED' => '已完成',
      'CANCELLED' => '已取消',
      'REVERSED' => '已反向',
      _ => status,
    };

String _routeLabel(String route) => switch (route) {
  'BUY' => '采购',
  'MAKE' => '自制',
  'SUBCONTRACT' => '委外',
  _ => route,
};

String formatProductionWorkCardMaterialUsage(
  ProductionWorkCardMaterial material,
) {
  final value = formatProductionPlanningUsage(material.perProductQty);
  return material.requirementMode == 'EXACT_SNAPSHOT'
      ? '按包/批(本段平均) $value'
      : '单支用量 $value';
}

String _qty(double value) => formatProductionPlanningQuantity(value);

String _value(String? value) => _present(value) ? value!.trim() : '—';

bool _present(String? value) => value != null && value.trim().isNotEmpty;

String _timestamp(String? raw) {
  final value = DateTime.tryParse(raw ?? '')?.toLocal();
  if (value == null) return _value(raw);
  String two(int number) => number.toString().padLeft(2, '0');
  return '${value.year}-${two(value.month)}-${two(value.day)} '
      '${two(value.hour)}:${two(value.minute)}';
}

String _shortId(String value) => value.length <= 12
    ? value
    : '${value.substring(0, 8)}…${value.substring(value.length - 4)}';

String _safeFilename(String value) =>
    value.replaceAll(RegExp(r'[\\/:*?"<>|]+'), '_');
