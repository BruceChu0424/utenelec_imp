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

typedef ProductionPdfPrinter =
    Future<bool> Function(Uint8List bytes, String filename);

const int _maxPrintBatchPlans = 50;
const int _maxPrintBatchCards = 200;

/// Opens a responsive preview for the persisted work-card projection.
///
/// The loader is called again immediately before printing so a cancelled or
/// reversed package is rejected instead of producing a stale reprint.
Future<void> showProductionExecutionCardPrintPreview(
  BuildContext context, {
  required Future<ProductionWorkCardView> Function() loader,
  ProductionPdfPrinter? printer,
}) {
  return showProductionExecutionCardBatchPrintPreview(
    context,
    loader: () async => [await loader()],
    printer: printer,
  );
}

/// Opens one preview for multiple confirmed plans and prints them as one PDF.
///
/// Each plan keeps its own package/segment identity and is reloaded before
/// printing. A failure in any plan aborts the whole batch; no stale subset is
/// silently printed.
Future<void> showProductionExecutionCardBatchPrintPreview(
  BuildContext context, {
  required Future<List<ProductionWorkCardView>> Function() loader,
  ProductionPdfPrinter? printer,
}) {
  return showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (_) => _ProductionExecutionCardPrintDialog(
      loader: loader,
      printer: printer ?? printPdfBytes,
    ),
  );
}

class _ProductionExecutionCardPrintDialog extends StatefulWidget {
  const _ProductionExecutionCardPrintDialog({
    required this.loader,
    required this.printer,
  });

  final Future<List<ProductionWorkCardView>> Function() loader;
  final ProductionPdfPrinter printer;

  @override
  State<_ProductionExecutionCardPrintDialog> createState() =>
      _ProductionExecutionCardPrintDialogState();
}

class _ProductionExecutionCardPrintDialogState
    extends State<_ProductionExecutionCardPrintDialog> {
  List<ProductionWorkCardView> _views = const [];
  String? _error;
  bool _loading = true;
  String? _printingTarget;

  bool get _printing => _printingTarget != null;
  int get _cardCount =>
      _views.fold(0, (total, view) => total + view.cards.length);

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
      final views = _validateViews(await widget.loader());
      if (!mounted) return;
      setState(() {
        _views = views;
        _loading = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _views = const [];
        _loading = false;
        _error = error is ApiException
            ? error.message
            : error is StateError
            ? error.message
            : '生产计划工卡加载失败，请确认所有计划包仍处于已确认状态';
      });
    }
  }

  List<ProductionWorkCardView> _validateViews(
    List<ProductionWorkCardView> views,
  ) {
    if (views.isEmpty || views.any((view) => !view.isPrintable)) {
      throw StateError('计划包不是可打印的已确认执行包');
    }
    final cardCount = views.fold<int>(
      0,
      (total, view) => total + view.cards.length,
    );
    if (views.length > _maxPrintBatchPlans || cardCount > _maxPrintBatchCards) {
      throw StateError(
        '单次最多打印 $_maxPrintBatchPlans 张计划、$_maxPrintBatchCards 张工卡，请分批处理',
      );
    }
    final identities = <String>{};
    final planIds = <String>{};
    final segmentIds = <String>{};
    final segmentCodes = <String>{};
    for (final view in views) {
      if (!_present(view.planId) || !_present(view.packageId)) {
        throw StateError('批量打印包含无效的计划或计划包身份');
      }
      final identity = '${view.planId}|${view.packageId}';
      if (!planIds.add(view.planId)) {
        throw StateError('批量打印不能包含同一生产计划的多个计划包');
      }
      if (!identities.add(identity)) {
        throw StateError('批量打印包含重复的生产计划包');
      }
      for (final card in view.cards) {
        if (!_isExecutionCardPrintableStatus(card.status)) {
          throw StateError('已取消或已反向的执行分段不能打印');
        }
        if (!_present(card.segmentId) || !_present(card.segmentCode)) {
          throw StateError('批量打印包含无效的执行分段身份');
        }
        if (!segmentIds.add(card.segmentId)) {
          throw StateError('批量打印包含重复的执行分段');
        }
        if (!segmentCodes.add(card.segmentCode)) {
          throw StateError('批量打印包含重复的分段条码');
        }
      }
    }
    return List.unmodifiable(views);
  }

  Future<void> _printAll() async {
    if (_printing) return;
    setState(() => _printingTarget = 'all');
    try {
      final latest = _validateViews(await widget.loader());
      if (mounted) setState(() => _views = latest);
      final bytes = await buildProductionExecutionCardBatchPdf(latest);
      final filename = latest.length == 1
          ? '生产计划单_${_safeFilename(latest.single.planBillNo ?? latest.single.planId)}_执行工卡.pdf'
          : '生产计划单_批量${latest.length}张计划_'
                '${latest.fold<int>(0, (total, view) => total + view.cards.length)}张工卡.pdf';
      final completed = await widget.printer(bytes, filename);
      if (!completed && mounted) context.appWarning('打印流程未完成');
    } on ApiException catch (error) {
      if (mounted) context.appError(error.message, force: true);
    } on StateError catch (error) {
      if (mounted) context.appError(error.message, force: true);
    } catch (_) {
      if (mounted) {
        context.appError('生成批量工卡失败；请刷新计划包状态后重试', force: true);
      }
    } finally {
      if (mounted) setState(() => _printingTarget = null);
    }
  }

  Future<void> _printOne(
    ProductionWorkCardView selectedView,
    ProductionWorkCard selectedCard,
  ) async {
    if (_printing) return;
    final target =
        '${selectedView.planId}|${selectedView.packageId}|${selectedCard.segmentId}';
    setState(() => _printingTarget = target);
    try {
      final latest = _validateViews(await widget.loader());
      final latestView = latest.singleWhere(
        (view) =>
            view.planId == selectedView.planId &&
            view.packageId == selectedView.packageId,
      );
      final latestCard = latestView.cards.singleWhere(
        (card) => card.segmentId == selectedCard.segmentId,
      );
      if (mounted) setState(() => _views = latest);
      final bytes = await buildProductionExecutionCardPdf(
        latestView,
        segmentIds: {latestCard.segmentId},
      );
      final completed = await widget.printer(
        bytes,
        '生产计划单_${_safeFilename(latestView.planBillNo ?? latestView.planId)}_'
        '${_safeFilename(latestCard.segmentCode)}.pdf',
      );
      if (!completed && mounted) context.appWarning('打印流程未完成');
    } on ApiException catch (error) {
      if (mounted) context.appError(error.message, force: true);
    } on StateError catch (error) {
      if (mounted) context.appError(error.message, force: true);
    } catch (_) {
      if (mounted) {
        context.appError('本次复核中有计划包或工卡失效；请重新读取后再试', force: true);
      }
    } finally {
      if (mounted) setState(() => _printingTarget = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final size = MediaQuery.sizeOf(context);
    final compact = size.width < 600;
    final dialog = Dialog(
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
              _footer(),
            ],
          ),
        ),
      ),
    );
    return PopScope(canPop: !_printing, child: dialog);
  }

  Widget _header(ThemeData theme) {
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
                  _views.isEmpty
                      ? '正在读取已确认计划包…'
                      : _views.length == 1
                      ? '${_views.single.planBillNo ?? _views.single.planId} · '
                            '${_views.single.cards.length} 张执行工卡 · '
                            '计划包 ${_shortId(_views.single.packageId)}'
                      : '${_views.length} 张生产计划 · '
                            '$_cardCount 张执行工卡 · 打印前整批复核',
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
    final entries = <({ProductionWorkCardView view, ProductionWorkCard card})>[
      for (final view in _views)
        for (final card in view.cards) (view: view, card: card),
    ];
    return ListView.builder(
      padding: const EdgeInsets.all(UtenSpacing.s12),
      itemCount: entries.length + 1,
      itemBuilder: (context, index) {
        if (index == 0) return _sourceNotice(theme);
        final entry = entries[index - 1];
        return Padding(
          padding: const EdgeInsets.only(top: UtenSpacing.s12),
          child: _workCardPreview(
            theme,
            entry.view,
            entry.card,
            showPlanNo: _views.length > 1,
          ),
        );
      },
    );
  }

  Widget _sourceNotice(ThemeData theme) {
    final versions = {
      for (final view in _views)
        'V${view.executionModelVersion}.${view.packageLockVersion}',
    }.join('、');
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
                '本次共 ${_views.length} 张生产计划、$_cardCount 张执行工卡。'
                '工卡来自已确认计划包、执行分段和物料需求的只读投影。'
                '打印或补打不会锁料、开单或改变状态；货品、颜色、单位和人员名称按打印时当前主档解析。'
                '计划包版本 $versions。',
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
    ProductionWorkCard card, {
    required bool showPlanNo,
  }) {
    final zeroMaterialText = productionZeroMaterialReasonText(
      card.materialRequirementMode,
      card.zeroMaterialReason,
    );
    final operationalNotice = _workCardOperationalNotice(card);
    final target = '${view.planId}|${view.packageId}|${card.segmentId}';
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
            LayoutBuilder(
              builder: (context, constraints) {
                final identity = Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      [
                        if (showPlanNo) view.planBillNo ?? view.planId,
                        card.segmentCode,
                        _value(card.productName),
                      ].join(' · '),
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
                );
                final actions = Wrap(
                  spacing: UtenSpacing.s8,
                  runSpacing: UtenSpacing.s8,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
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
                    UtenButton(
                      key: ValueKey(
                        'production-work-card-print-${card.segmentId}',
                      ),
                      type: UtenButtonType.tonal,
                      size: UtenButtonSize.small,
                      icon: Icons.print_outlined,
                      isLoading: _printingTarget == target,
                      onPressed: _printing ? null : () => _printOne(view, card),
                      child: const Text('打印本张'),
                    ),
                  ],
                );
                if (constraints.maxWidth < 520) {
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      identity,
                      const SizedBox(height: UtenSpacing.s8),
                      Align(alignment: Alignment.centerLeft, child: actions),
                    ],
                  );
                }
                return Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(child: identity),
                    const SizedBox(width: UtenSpacing.s8),
                    actions,
                  ],
                );
              },
            ),
            if (operationalNotice != null) ...[
              const SizedBox(height: UtenSpacing.s8),
              Container(
                key: ValueKey('production-work-card-status-${card.segmentId}'),
                padding: const EdgeInsets.all(UtenSpacing.s12),
                decoration: BoxDecoration(
                  color: card.status == 'COMPLETED'
                      ? theme.colorScheme.surfaceContainerHighest
                      : theme.colorScheme.tertiaryContainer.withValues(
                          alpha: 0.55,
                        ),
                  borderRadius: UtenRadius.smAll,
                  border: Border.all(
                    color: card.status == 'COMPLETED'
                        ? theme.colorScheme.outlineVariant
                        : theme.colorScheme.tertiary.withValues(alpha: 0.5),
                  ),
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(
                      card.status == 'COMPLETED'
                          ? Icons.archive_outlined
                          : Icons.local_shipping_outlined,
                      size: 20,
                    ),
                    const SizedBox(width: UtenSpacing.s8),
                    Expanded(
                      child: Text(
                        operationalNotice,
                        style: theme.textTheme.bodySmall?.copyWith(
                          fontWeight: FontWeight.w700,
                          height: 1.4,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
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

  Widget _footer() {
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
              isLoading: _printingTarget == 'all',
              onPressed: _views.isNotEmpty && !_printing ? _printAll : null,
              child: Text('打印全部（$_cardCount 张工卡）'),
            ),
          ],
        ),
      ),
    );
  }
}

/// Generates one landscape A4 work card per persisted execution segment.
Future<Uint8List> buildProductionExecutionCardPdf(
  ProductionWorkCardView view, {
  Set<String>? segmentIds,
}) async {
  if (!view.isPrintable) {
    throw StateError('Only a confirmed V1 package can produce work cards');
  }
  if (segmentIds?.isEmpty == true) {
    throw StateError('At least one execution segment must be selected');
  }
  final cards = segmentIds == null
      ? view.cards
      : view.cards
            .where((card) => segmentIds.contains(card.segmentId))
            .toList(growable: false);
  if (cards.isEmpty) {
    throw StateError('No matching persisted execution card can be printed');
  }
  if (cards.length > _maxPrintBatchCards) {
    throw StateError('Too many execution cards in one print job');
  }
  if (segmentIds != null && cards.length != segmentIds.length) {
    throw StateError('One or more selected execution segments no longer exist');
  }
  if (cards.any((card) => !_isExecutionCardPrintableStatus(card.status))) {
    throw StateError('Cancelled or reversed execution cards cannot be printed');
  }
  return _buildProductionExecutionCardPdf([
    for (final card in cards) (view: view, card: card),
  ], title: '生产计划单_${view.planBillNo ?? view.planId}_执行工卡');
}

/// Generates one PDF containing every card from multiple confirmed plans.
///
/// The operation is all-or-nothing: an empty, duplicate, or invalid package
/// rejects the whole batch rather than printing a misleading partial subset.
Future<Uint8List> buildProductionExecutionCardBatchPdf(
  List<ProductionWorkCardView> views,
) async {
  if (views.isEmpty || views.any((view) => !view.isPrintable)) {
    throw StateError('Every batch item must be a confirmed V1 work-card view');
  }
  final cardCount = views.fold<int>(
    0,
    (total, view) => total + view.cards.length,
  );
  if (views.length > _maxPrintBatchPlans || cardCount > _maxPrintBatchCards) {
    throw StateError('Print batch exceeds the supported plan or card limit');
  }
  final identities = <String>{};
  final planIds = <String>{};
  final segmentIds = <String>{};
  final segmentCodes = <String>{};
  for (final view in views) {
    if (!_present(view.planId) || !_present(view.packageId)) {
      throw StateError('Print batch contains a blank plan or package identity');
    }
    if (!planIds.add(view.planId)) {
      throw StateError('Multiple packages for one plan cannot share a batch');
    }
    if (!identities.add('${view.planId}|${view.packageId}')) {
      throw StateError('Duplicate production plan package in print batch');
    }
    for (final card in view.cards) {
      if (!_present(card.segmentId) || !_present(card.segmentCode)) {
        throw StateError('Print batch contains a blank segment identity');
      }
      if (!segmentIds.add(card.segmentId) ||
          !segmentCodes.add(card.segmentCode)) {
        throw StateError('Print batch contains a duplicate segment or barcode');
      }
    }
  }
  final entries = <({ProductionWorkCardView view, ProductionWorkCard card})>[
    for (final view in views)
      for (final card in view.cards) (view: view, card: card),
  ];
  if (entries.any(
    (entry) => !_isExecutionCardPrintableStatus(entry.card.status),
  )) {
    throw StateError('Cancelled or reversed execution cards cannot be printed');
  }
  return _buildProductionExecutionCardPdf(
    entries,
    title: '生产计划单_批量${views.length}张计划_${entries.length}张工卡',
  );
}

Future<Uint8List> _buildProductionExecutionCardPdf(
  List<({ProductionWorkCardView view, ProductionWorkCard card})> entries, {
  required String title,
}) async {
  final fontData = await rootBundle.load('assets/fonts/NotoSansSCFull.ttf');
  final font = pw.Font.ttf(fontData);
  final document = pw.Document(
    title: title,
    author: 'Uten IMP',
    creator: 'Uten IMP production planning',
    subject: 'Confirmed production execution package work cards',
    theme: pw.ThemeData.withFont(base: font, bold: font),
  );

  for (final entry in entries) {
    document.addPage(
      pw.MultiPage(
        pageFormat: PdfPageFormat.a4.landscape,
        margin: const pw.EdgeInsets.fromLTRB(24, 22, 24, 22),
        header: (_) => _pdfHeader(entry.view, entry.card),
        footer: (context) => _pdfFooter(context, entry.view, entry.card),
        build: (_) => [
          _pdfMetadata(entry.view, entry.card),
          if (_workCardOperationalNotice(entry.card) != null) ...[
            pw.SizedBox(height: 6),
            _pdfOperationalNotice(entry.card),
          ],
          pw.SizedBox(height: 8),
          _pdfMaterialTable(entry.card),
          pw.SizedBox(height: 8),
          _pdfNotes(entry.card),
          pw.SizedBox(height: 14),
          _pdfSignatures(),
          pw.SizedBox(height: 12),
          _pdfShopFloorRecordArea(),
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
                '当前状态 ${_statusLabel(card.status, autoPromoteWhenReady: card.autoPromoteWhenReady)}  ·  '
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

pw.Widget _pdfOperationalNotice(ProductionWorkCard card) {
  final notice = _workCardOperationalNotice(card)!;
  return pw.Container(
    width: double.infinity,
    padding: const pw.EdgeInsets.all(7),
    decoration: pw.BoxDecoration(
      color: PdfColors.grey200,
      border: pw.Border.all(width: 0.7, color: PdfColors.grey700),
    ),
    child: pw.Text(
      notice,
      style: const pw.TextStyle(fontSize: 9, fontWeight: pw.FontWeight.bold),
    ),
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

pw.Widget _pdfShopFloorRecordArea() {
  return pw.Container(
    width: double.infinity,
    height: 112,
    padding: const pw.EdgeInsets.fromLTRB(8, 6, 8, 4),
    decoration: pw.BoxDecoration(
      border: pw.Border.all(width: 0.6, color: PdfColors.grey700),
    ),
    child: pw.Column(
      crossAxisAlignment: pw.CrossAxisAlignment.start,
      children: [
        pw.Text(
          '现场记录（异常 / 换料 / 停线 / 交接；手写内容不回写系统）',
          style: const pw.TextStyle(
            fontSize: 8.5,
            fontWeight: pw.FontWeight.bold,
          ),
        ),
        pw.SizedBox(height: 5),
        for (var index = 0; index < 4; index++)
          pw.Expanded(
            child: pw.Container(
              width: double.infinity,
              decoration: const pw.BoxDecoration(
                border: pw.Border(
                  bottom: pw.BorderSide(width: 0.35, color: PdfColors.grey500),
                ),
              ),
            ),
          ),
      ],
    ),
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
      // 与全站流程词表同口径（等待物料 → 等待车间领料 → 生产中 → 已完工）。
      'READY' => '等待车间领料',
      'WAITING' => autoPromoteWhenReady ? '等待物料' : '人工暂缓',
      'DISPATCHED' => '等待车间领料（历史工单）',
      'IN_PROGRESS' => '生产中',
      'COMPLETED' => '已完工 · 仅供存档',
      'CANCELLED' => '已取消',
      'REVERSED' => '已反向',
      _ => status,
    };

String? _workCardOperationalNotice(ProductionWorkCard card) {
  final zeroMaterial = card.materialRequirementMode == 'ZERO_MATERIAL';
  return switch (card.status) {
    'READY' when zeroMaterial => '无需领料 · 可开工：本段无生产领料需求，可直接报工；首次报工会登记实际开工。',
    'READY' => '等待车间领料：库存已预留并生成领料需求；仓库实际发料完成后可直接报工。',
    'WAITING' =>
      card.autoPromoteWhenReady
          ? '等待物料：物料齐套并完成仓库实发后才可报工。'
          : '人工暂缓：必须先解除暂缓，再完成齐套和仓库实发后报工。',
    'DISPATCHED' when zeroMaterial => '历史兼容工单：本段无领料需求，可直接报工；首次报工会统一执行状态。',
    'DISPATCHED' => '历史兼容工单：仓库实际发料完成后可直接报工。',
    'COMPLETED' => '已完工 · 仅供存档：本打印件不得再次作为生产、领料或排产指令。',
    _ => null,
  };
}

bool _isExecutionCardPrintableStatus(String status) => switch (status) {
  'READY' || 'WAITING' || 'DISPATCHED' || 'IN_PROGRESS' || 'COMPLETED' => true,
  _ => false,
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
