// 销售客户文件识别的核对面板(ADR-134, SPEC §7.3)。
//
// 两步、大白话、默认值先行(docs/00-项目准则/13-适老化UX基线.md):
//  1. 客户: 自动对上只显示一行「客户: X ✓ [换一个]」; 需要核对/没找到时给建议、
//     「选其它客户…」与「用文件信息新建客户」; 可补进客户资料的信息一句话 + 一个勾。
//  2. 货品: 默认只看「需要核对」的行, 已自动对应的行收起; 每行给大白话原因、候选下拉
//     (名称(编号) · 颜色 · 系列 + 理由)、「从货品资料选择…」、组合件「拆成 N 行」、
//     「设为货品英文名」; 底部固定一行汇总 + 一个大按钮「全部导入 (N 行)」。
// 界面不出现置信度数字、识别方式、服务商/模型等技术词。行多时按需构建(SliverList)。
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../components/buttons/uten_button.dart';
import '../../../components/feedback/uten_inline_notice.dart';
import '../../../components/inputs/uten_dropdown_field.dart';
import '../../../core/l10n/gen/app_localizations.dart';
import '../../../core/theme/uten_colors.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../shared/ai/ai_tone.dart';
import '../models/sales_doc.dart';
import 'sales_intake_apply.dart';
import 'sales_intake_l10n.dart';
import 'sales_intake_models.dart';

/// 面板里选中的客户。
class SalesIntakePickedClient {
  const SalesIntakePickedClient({required this.id, required this.name});

  final String id;
  final String name;
}

/// 面板里「从货品资料选择…」选中的货品(标价看不到时为 null)。
class SalesIntakePickedGoods {
  const SalesIntakePickedGoods({
    required this.id,
    this.code,
    this.name,
    this.model,
    this.series,
    this.spec,
    this.colorId,
    this.colorName,
    this.unitId,
    this.unitName,
    this.price,
  });

  final String id;
  final String? code;
  final String? name;
  final String? model;
  final String? series;
  final String? spec;
  final String? colorId;
  final String? colorName;
  final String? unitId;
  final String? unitName;
  final String? price;
}

/// 面板对外的动作(由启动器注入真实选择器/接口, 测试注入假实现)。
class SalesIntakeReviewActions {
  const SalesIntakeReviewActions({
    required this.pickClient,
    required this.pickGoods,
    required this.createClient,
    this.canHandoffToQuote = false,
  });

  final Future<SalesIntakePickedClient?> Function(BuildContext context)
  pickClient;
  final Future<SalesIntakePickedGoods?> Function(BuildContext context)
  pickGoods;

  /// 用文件信息新建客户; 返回选中的客户(新建的或已存在的), 失败返回 null(已提示)。
  final Future<SalesIntakePickedClient?> Function(
    BuildContext context,
    SalesIntakeNewClientProposal proposal,
  )
  createClient;

  /// 订货单上有没标价的货品时, 是否提供「改为新建报价单」。
  final bool canHandoffToQuote;
}

/// 面板结果。
sealed class SalesIntakeReviewOutcome {
  const SalesIntakeReviewOutcome();
}

/// 按选择导入。
class SalesIntakeReviewApply extends SalesIntakeReviewOutcome {
  const SalesIntakeReviewApply(this.decisions);

  final SalesIntakeDecisions decisions;
}

/// 改为新建报价单(同一次识别, 不用重新上传)。
class SalesIntakeReviewHandoffToQuote extends SalesIntakeReviewOutcome {
  const SalesIntakeReviewHandoffToQuote();
}

/// 打开核对面板; 取消返回 null。
Future<SalesIntakeReviewOutcome?> showSalesIntakeReviewPanel(
  BuildContext context, {
  required SalesIntakeResult result,
  required SalesDocType docType,
  required SalesIntakeReviewActions actions,
  String? presetClientId,
  String? presetClientName,
}) {
  return showDialog<SalesIntakeReviewOutcome>(
    context: context,
    barrierDismissible: false,
    builder: (dialogContext) {
      final size = MediaQuery.sizeOf(dialogContext);
      final panel = SalesIntakeReviewPanel(
        result: result,
        docType: docType,
        actions: actions,
        presetClientId: presetClientId,
        presetClientName: presetClientName,
      );
      if (size.width < 700) return Dialog.fullscreen(child: panel);
      // 圆角沿用主题 dialogTheme(全站弹窗 18)。
      return Dialog(
        insetPadding: const EdgeInsets.all(UtenSpacing.s24),
        clipBehavior: Clip.antiAlias,
        child: SizedBox(
          width: math.min(1080, size.width - UtenSpacing.s48),
          height: math.min(size.height * 0.92, 980),
          child: panel,
        ),
      );
    },
  );
}

enum _LineFilter { review, all }

class SalesIntakeReviewPanel extends StatefulWidget {
  const SalesIntakeReviewPanel({
    super.key,
    required this.result,
    required this.docType,
    required this.actions,
    this.presetClientId,
    this.presetClientName,
  });

  final SalesIntakeResult result;
  final SalesDocType docType;
  final SalesIntakeReviewActions actions;
  final String? presetClientId;
  final String? presetClientName;

  @override
  State<SalesIntakeReviewPanel> createState() => _SalesIntakeReviewPanelState();
}

class _SalesIntakeReviewPanelState extends State<SalesIntakeReviewPanel> {
  late final SalesIntakeDecisions _decisions;
  late final List<SalesIntakeLine> _reviewLines;
  late final List<SalesIntakeLine> _matchedLines;
  _LineFilter _filter = _LineFilter.review;
  bool _matchedExpanded = false;
  bool _clientEditing = false;
  bool _enrichmentExpanded = false;
  bool _busy = false;

  /// 需要核对的行里用户手动加进来的货品候选(按行键)。
  final Map<String, List<SalesIntakeCandidate>> _extraCandidates = {};

  /// 在「已自动对应」里点了「修改」展开成完整卡片的行。
  final Set<String> _expandedMatched = {};

  SalesIntakeResult get _result => widget.result;
  bool get _masked => _result.priceMasked;

  @override
  void initState() {
    super.initState();
    _decisions = SalesIntakeDecisions.initial(
      _result,
      docType: widget.docType,
      presetClientId: widget.presetClientId,
      presetClientName: widget.presetClientName,
    );
    _reviewLines = [];
    _matchedLines = [];
    for (final line in _result.lines) {
      final needs = salesIntakeLineNeedsReview(
        line,
        _decisions.decisionFor(line),
        docType: widget.docType,
        priceMasked: _masked,
      );
      (needs ? _reviewLines : _matchedLines).add(line);
    }
    if (_reviewLines.isEmpty) _filter = _LineFilter.all;
    _clientEditing = !_result.client.status.resolved;
  }

  int get _importRowCount {
    var total = 0;
    for (final line in _result.lines) {
      total += salesIntakeRowCount(
        line,
        _decisions.decisionFor(line),
        docType: widget.docType,
        priceMasked: _masked,
      );
    }
    return total;
  }

  int get _yellowRowCount {
    var total = 0;
    for (final line in _result.lines) {
      final d = _decisions.decisionFor(line);
      final rows = salesIntakeRowCount(
        line,
        d,
        docType: widget.docType,
        priceMasked: _masked,
      );
      if (rows == 0) continue;
      final pricingOpen = !_masked && !(d.goods?.hasUsableDiscount ?? false);
      if (d.split ||
          (line.status != SalesIntakeLineStatus.matched && !d.userConfirmed) ||
          pricingOpen ||
          line.suggestedQty != null ||
          line.warning(SalesIntakeWarningCode.unitNotPcs) != null) {
        total += rows;
      }
    }
    return total;
  }

  int get _skippedLineCount => _result.lines
      .where(
        (line) =>
            salesIntakeRowCount(
              line,
              _decisions.decisionFor(line),
              docType: widget.docType,
              priceMasked: _masked,
            ) ==
            0,
      )
      .length;

  /// 服务端候选 + 手工选的货品(已在候选里的不重复列出)。
  List<SalesIntakeCandidate> _candidatesFor(SalesIntakeLine line) {
    final ids = {for (final c in line.candidates) c.goodsId};
    return [
      ...line.candidates,
      for (final c
          in _extraCandidates[line.key] ?? const <SalesIntakeCandidate>[])
        if (!ids.contains(c.goodsId)) c,
    ];
  }

  Future<void> _pickClient() async {
    final picked = await widget.actions.pickClient(context);
    if (!mounted || picked == null) return;
    setState(() {
      _decisions
        ..clientId = picked.id
        ..clientName = picked.name;
      _clientEditing = false;
    });
  }

  Future<void> _createClient() async {
    final proposal = _result.client.newClientProposal;
    if (proposal == null) return;
    setState(() => _busy = true);
    try {
      final created = await widget.actions.createClient(context, proposal);
      if (!mounted || created == null) return;
      setState(() {
        _decisions
          ..clientId = created.id
          ..clientName = created.name;
        _clientEditing = false;
      });
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _pickGoodsFor(
    SalesIntakeLine line, {
    SalesIntakePartDecision? part,
  }) async {
    final picked = await widget.actions.pickGoods(context);
    if (!mounted || picked == null) return;
    final l10n = salesIntakeL10n(context);
    final candidate = salesIntakeManualCandidate(
      goodsId: picked.id,
      code: picked.code,
      name: picked.name,
      model: picked.model,
      series: picked.series,
      spec: picked.spec,
      colorId: picked.colorId,
      colorName: picked.colorName,
      unitId: picked.unitId,
      unitName: picked.unitName,
      listPrice: picked.price,
      bundlePart: part != null,
      line: line,
      currency: _result.currency,
      priceMasked: _masked,
      reason: l10n.salesIntakePickedManually,
    );
    setState(() {
      if (part != null) {
        _selectPart(part, candidate);
        return;
      }
      final list = _extraCandidates.putIfAbsent(line.key, () => []);
      list.removeWhere((c) => c.goodsId == candidate.goodsId);
      list.add(candidate);
      _selectGoods(line, candidate);
    });
  }

  bool _partBlocked(SalesIntakeCandidate? goods) => salesIntakePartBlocked(
    docType: widget.docType,
    goods: goods,
    priceMasked: _masked,
  );

  /// 组合件部件选了货品: 记为人工确认, 能导入就勾上(订货单上没标价的部件不能勾)。
  void _selectPart(SalesIntakePartDecision part, SalesIntakeCandidate? goods) {
    part
      ..goods = goods
      ..userConfirmed = goods != null
      ..include = goods != null && !_partBlocked(goods);
  }

  /// 用户明确选了一个货品: 记为人工确认, 能导入就勾上。
  void _selectGoods(SalesIntakeLine line, SalesIntakeCandidate? goods) {
    final d = _decisions.decisionFor(line);
    d
      ..goods = goods
      ..userConfirmed = goods != null
      ..include =
          goods != null &&
          !salesIntakeGoodsBlocked(
            docType: widget.docType,
            goods: goods,
            priceMasked: _masked,
          );
    // 换了货品: 英文名勾选按服务端默认口径重新判断(只对服务端推荐的货品默认勾)。
    d.setNameEn =
        d.setNameEn &&
        goods != null &&
        (goods.nameEn == null || goods.nameEn!.isEmpty) &&
        line.nameEnText != null;
  }

  @override
  Widget build(BuildContext context) {
    final l10n = salesIntakeL10n(context);
    final theme = Theme.of(context);
    final importCount = _importRowCount;
    final visibleLines = _filter == _LineFilter.review
        ? _reviewLines
        : _result.lines;
    return Material(
      color: theme.colorScheme.surface,
      child: Column(
        children: [
          _PanelHeader(
            title: l10n.salesIntakeReviewTitle,
            subtitle: l10n.salesIntakeReviewSubtitle(
              _result.file.name ?? '',
              _result.lines.length,
            ),
            onClose: _busy ? null : () => Navigator.of(context).pop(),
            closeTooltip: l10n.salesIntakeClose,
          ),
          Expanded(
            child: CustomScrollView(
              key: const ValueKey('sales-intake-review-scroll'),
              slivers: [
                SliverPadding(
                  padding: const EdgeInsets.fromLTRB(
                    UtenSpacing.s20,
                    UtenSpacing.s16,
                    UtenSpacing.s20,
                    0,
                  ),
                  sliver: SliverList.list(
                    children: [
                      ..._buildNotices(context, l10n),
                      _StepCard(
                        step: 1,
                        title: l10n.salesIntakeStepClient,
                        child: _buildClientStep(context, l10n),
                      ),
                      const SizedBox(height: UtenSpacing.s16),
                      _buildGoodsHeader(context, l10n),
                      const SizedBox(height: UtenSpacing.s8),
                      if (_filter == _LineFilter.review && _reviewLines.isEmpty)
                        UtenInlineNotice(
                          message: l10n.salesIntakeNoReviewLines,
                        ),
                    ],
                  ),
                ),
                SliverPadding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: UtenSpacing.s20,
                  ),
                  sliver: SliverList.builder(
                    itemCount: visibleLines.length,
                    itemBuilder: (context, index) {
                      final line = visibleLines[index];
                      final compact =
                          _filter == _LineFilter.all &&
                          !_reviewLines.contains(line) &&
                          !_expandedMatched.contains(line.key);
                      return Padding(
                        padding: const EdgeInsets.only(bottom: UtenSpacing.s8),
                        child: compact
                            ? _matchedTile(context, l10n, line)
                            : _lineCard(context, l10n, line),
                      );
                    },
                  ),
                ),
                if (_filter == _LineFilter.review && _matchedLines.isNotEmpty)
                  SliverPadding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: UtenSpacing.s20,
                    ),
                    sliver: SliverList.list(
                      children: [
                        _MatchedToggle(
                          label: l10n.salesIntakeMatchedCollapsed(
                            _matchedLines.length,
                          ),
                          actionLabel: _matchedExpanded
                              ? l10n.salesIntakeCollapse
                              : l10n.salesIntakeExpand,
                          expanded: _matchedExpanded,
                          onTap: () => setState(
                            () => _matchedExpanded = !_matchedExpanded,
                          ),
                        ),
                        const SizedBox(height: UtenSpacing.s8),
                      ],
                    ),
                  ),
                if (_filter == _LineFilter.review && _matchedExpanded)
                  SliverPadding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: UtenSpacing.s20,
                    ),
                    sliver: SliverList.builder(
                      itemCount: _matchedLines.length,
                      itemBuilder: (context, index) {
                        final line = _matchedLines[index];
                        return Padding(
                          padding: const EdgeInsets.only(
                            bottom: UtenSpacing.s8,
                          ),
                          child: _expandedMatched.contains(line.key)
                              ? _lineCard(context, l10n, line)
                              : _matchedTile(context, l10n, line),
                        );
                      },
                    ),
                  ),
                const SliverToBoxAdapter(
                  child: SizedBox(height: UtenSpacing.s24),
                ),
              ],
            ),
          ),
          _Footer(
            summary: importCount == 0
                ? l10n.salesIntakeNothingToImport
                : l10n.salesIntakeSummary(
                    importCount,
                    _yellowRowCount,
                    _skippedLineCount,
                  ),
            importLabel: l10n.salesIntakeImportAll(importCount),
            cancelLabel: l10n.salesIntakeCancel,
            onImport: importCount == 0 || _busy
                ? null
                : () => Navigator.of(
                    context,
                  ).pop(SalesIntakeReviewApply(_decisions)),
            onCancel: _busy ? null : () => Navigator.of(context).pop(),
          ),
        ],
      ),
    );
  }

  // ------------------------------------------------------------------ 提示

  List<Widget> _buildNotices(BuildContext context, AppLocalizations l10n) {
    final notices = <Widget>[];
    void add(Widget w) {
      notices
        ..add(w)
        ..add(const SizedBox(height: UtenSpacing.s12));
    }

    final blocked = salesIntakeBlockedGoodsCount(
      _result,
      _decisions,
      docType: widget.docType,
    );
    if (blocked > 0) {
      final handoff = widget.actions.canHandoffToQuote
          ? UtenButton(
              key: const ValueKey('sales-intake-handoff-quote'),
              type: UtenButtonType.secondary,
              height: 48,
              icon: Icons.request_quote_outlined,
              onPressed: _busy
                  ? null
                  : () => Navigator.of(
                      context,
                    ).pop(const SalesIntakeReviewHandoffToQuote()),
              child: Text(l10n.salesIntakeHandoffToQuote),
            )
          : null;
      // 窄屏把按钮放到提示下面, 不把提示文字挤成一条窄列。
      final compact = MediaQuery.sizeOf(context).width < 700;
      add(
        Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            UtenInlineNotice(
              key: const ValueKey('sales-intake-blocked-notice'),
              level: UtenInlineNoticeLevel.warning,
              title: l10n.salesIntakeBlockedTitle(blocked),
              message: l10n.salesIntakeBlockedMessage,
              trailing: compact ? null : handoff,
            ),
            if (compact && handoff != null) ...[
              const SizedBox(height: UtenSpacing.s8),
              handoff,
            ],
          ],
        ),
      );
    }
    if (_result.duplicates.isNotEmpty) {
      final items = _result.duplicates
          .map(
            (d) => l10n.salesIntakeDuplicateItem(
              d.docType == 'quote'
                  ? l10n.salesIntakeDocTypeQuote
                  : l10n.salesIntakeDocTypeOrder,
              d.billNo ?? '',
              d.billDate ?? '',
              d.reason ?? '',
            ),
          )
          .join('; ');
      add(
        UtenInlineNotice(
          key: const ValueKey('sales-intake-duplicate-notice'),
          level: UtenInlineNoticeLevel.warning,
          title: l10n.salesIntakeDuplicateTitle,
          message: l10n.salesIntakeDuplicateMessage(items),
        ),
      );
    }
    // 一般说明合成一条(币种折算 / 看不到价格 / 其它工作表 / 服务端提示), 不把正文挤到下面去。
    final infos = <String>[];
    final currency = _result.currency;
    if (currency.rateMissing && currency.fileCurrency != null) {
      add(
        UtenInlineNotice(
          level: UtenInlineNoticeLevel.warning,
          message: l10n.salesIntakeRateMissingNotice(currency.fileCurrency!),
        ),
      );
    } else if (currency.fileCurrency != null &&
        currency.financeRate != null &&
        currency.baseCurrencyName != null) {
      infos.add(
        l10n.salesIntakeCurrencyNotice(
          currency.fileCurrency!,
          currency.financeRate!,
          currency.baseCurrencyName!,
        ),
      );
    }
    if (_masked) infos.add(l10n.salesIntakePriceMaskedNotice);
    final otherSheets = _result.file.otherSheets;
    if (otherSheets.isNotEmpty) {
      infos.add(
        l10n.salesIntakeOtherSheets(
          otherSheets
              .map((s) => l10n.salesIntakeOtherSheetItem(s.name, s.lineCount))
              .join(', '),
          _result.file.sheet ?? '',
        ),
      );
    }
    // 「名下没有客户」已在客户这一步说明, 服务端同句提示不再重复; 订货单「这 N 个货品还没有标价」
    // 由上面的提示按当前选择实时计数(并带「改为新建报价单」), 服务端那句同义提示也不再重复。
    infos.addAll(
      _result.notices.where(
        (n) =>
            n != l10n.salesIntakeNoVisibleClients &&
            !(widget.docType == SalesDocType.order &&
                salesIntakeIsServerBlockingNotice(n)),
      ),
    );
    if (infos.isNotEmpty) {
      add(
        UtenInlineNotice(
          key: const ValueKey('sales-intake-info-notice'),
          message: infos.map((i) => infos.length > 1 ? '· $i' : i).join('\n'),
        ),
      );
    }
    return notices;
  }

  // ------------------------------------------------------------------ 客户

  Widget _buildClientStep(BuildContext context, AppLocalizations l10n) {
    final theme = Theme.of(context);
    final client = _result.client;
    final children = <Widget>[];
    final chosenName = _decisions.clientName;
    if (!_clientEditing && _decisions.clientId != null) {
      children.add(
        Row(
          key: const ValueKey('sales-intake-client-resolved'),
          children: [
            const Icon(Icons.check_circle_rounded, color: UtenColors.success),
            const SizedBox(width: UtenSpacing.s8),
            Expanded(
              child: Text(
                l10n.salesIntakeClientResolved(chosenName ?? ''),
                style: theme.textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
            UtenButton(
              type: UtenButtonType.ghost,
              height: 48,
              onPressed: _busy
                  ? null
                  : () => setState(() => _clientEditing = true),
              child: Text(l10n.salesIntakeClientChange),
            ),
          ],
        ),
      );
    } else {
      if (client.status == SalesIntakeClientStatus.noVisibleClients) {
        children.add(
          UtenInlineNotice(
            level: UtenInlineNoticeLevel.warning,
            message: l10n.salesIntakeNoVisibleClients,
          ),
        );
        children.add(const SizedBox(height: UtenSpacing.s8));
      }
      final buyer = _result.header.buyerName;
      if (buyer != null) {
        children.add(
          Text(
            l10n.salesIntakeClientBuyer(buyer),
            style: theme.textTheme.bodyLarge?.copyWith(
              fontWeight: FontWeight.w600,
            ),
          ),
        );
      }
      if (client.status == SalesIntakeClientStatus.unmatched) {
        children.add(
          Text(
            l10n.salesIntakeClientNotFound,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        );
      }
      if (client.candidates.isNotEmpty) {
        children
          ..add(const SizedBox(height: UtenSpacing.s8))
          ..add(Text(l10n.salesIntakeClientSuggestions))
          ..add(const SizedBox(height: UtenSpacing.s8));
        for (final candidate in client.candidates.take(5)) {
          children.add(
            _ClientCandidateTile(
              candidate: candidate,
              selected: _decisions.clientId == candidate.clientId,
              onTap: _busy
                  ? null
                  : () => setState(() {
                      _decisions
                        ..clientId = candidate.clientId
                        ..clientName = candidate.displayName;
                      _clientEditing = false;
                    }),
            ),
          );
        }
      } else if (_decisions.clientId == null) {
        children.add(
          Padding(
            padding: const EdgeInsets.only(top: UtenSpacing.s4),
            child: Text(
              l10n.salesIntakeClientNone,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        );
      }
      children.add(const SizedBox(height: UtenSpacing.s12));
      children.add(
        Wrap(
          spacing: UtenSpacing.s8,
          runSpacing: UtenSpacing.s8,
          children: [
            UtenButton(
              key: const ValueKey('sales-intake-pick-client'),
              type: UtenButtonType.secondary,
              icon: Icons.person_search_outlined,
              height: 48,
              onPressed: _busy ? null : _pickClient,
              child: Text(l10n.salesIntakeClientPickOther),
            ),
            if (client.status == SalesIntakeClientStatus.unmatched &&
                (client.newClientProposal?.hasName ?? false))
              UtenButton(
                key: const ValueKey('sales-intake-create-client'),
                type: UtenButtonType.tonal,
                icon: Icons.person_add_alt_1_outlined,
                height: 48,
                isLoading: _busy,
                onPressed: _busy ? null : _createClient,
                child: Text(l10n.salesIntakeClientCreate),
              ),
            if (_decisions.clientId != null &&
                client.status.resolved &&
                _clientEditing)
              UtenButton(
                type: UtenButtonType.ghost,
                height: 48,
                onPressed: () => setState(() => _clientEditing = false),
                child: Text(l10n.salesIntakeCollapse),
              ),
          ],
        ),
      );
    }
    if (client.mismatchWarning != null) {
      children
        ..add(const SizedBox(height: UtenSpacing.s12))
        ..add(
          UtenInlineNotice(
            level: UtenInlineNoticeLevel.warning,
            message: client.mismatchWarning!,
          ),
        );
    }
    final enrichment = client.enrichment;
    if (enrichment.isNotEmpty &&
        _decisions.clientId != null &&
        _decisions.clientId == client.selectedClientId) {
      children
        ..add(const SizedBox(height: UtenSpacing.s12))
        ..add(_buildEnrichment(context, l10n, enrichment));
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: children,
    );
  }

  Widget _buildEnrichment(
    BuildContext context,
    AppLocalizations l10n,
    List<SalesIntakeEnrichmentField> fields,
  ) {
    final theme = Theme.of(context);
    final labels = fields.map((f) => f.label).join(', ');
    return Container(
      key: const ValueKey('sales-intake-enrichment'),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(UtenRadius.lg),
      ),
      padding: const EdgeInsets.symmetric(
        horizontal: UtenSpacing.s4,
        vertical: UtenSpacing.s4,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Checkbox(
                value: _decisions.enrichmentEnabled,
                onChanged: (v) =>
                    setState(() => _decisions.enrichmentEnabled = v ?? false),
              ),
              Expanded(
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: () => setState(
                    () => _decisions.enrichmentEnabled =
                        !_decisions.enrichmentEnabled,
                  ),
                  child: Text(
                    l10n.salesIntakeEnrichSummary(labels),
                    style: theme.textTheme.bodyLarge,
                  ),
                ),
              ),
              UtenButton(
                type: UtenButtonType.ghost,
                height: 48,
                onPressed: () =>
                    setState(() => _enrichmentExpanded = !_enrichmentExpanded),
                child: Text(
                  _enrichmentExpanded
                      ? l10n.salesIntakeEnrichHide
                      : l10n.salesIntakeEnrichShow,
                ),
              ),
            ],
          ),
          if (_enrichmentExpanded)
            for (final field in fields)
              Padding(
                padding: const EdgeInsetsDirectional.only(
                  start: UtenSpacing.s32,
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Checkbox(
                      value:
                          _decisions.enrichmentEnabled &&
                          (_decisions.enrichmentFields[field.field] ?? false),
                      onChanged: _decisions.enrichmentEnabled
                          ? (v) => setState(
                              () => _decisions.enrichmentFields[field.field] =
                                  v ?? false,
                            )
                          : null,
                    ),
                    Expanded(
                      child: Padding(
                        padding: const EdgeInsets.only(top: UtenSpacing.s12),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              '${field.label}: ${field.proposed}',
                              style: theme.textTheme.bodyMedium,
                            ),
                            Text(
                              field.differs && field.current != null
                                  ? l10n.salesIntakeEnrichDiffers(
                                      field.current!,
                                    )
                                  : l10n.salesIntakeEnrichCurrentEmpty,
                              style: theme.textTheme.bodySmall?.copyWith(
                                color: field.differs
                                    ? AiTone.warning(theme)
                                    : theme.colorScheme.onSurfaceVariant,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
        ],
      ),
    );
  }

  // ------------------------------------------------------------------ 货品

  Widget _buildGoodsHeader(BuildContext context, AppLocalizations l10n) {
    final theme = Theme.of(context);
    return Row(
      children: [
        const _StepBadge(step: 2),
        const SizedBox(width: UtenSpacing.s8),
        Expanded(
          child: Text(
            l10n.salesIntakeStepGoods,
            style: theme.textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
        SegmentedButton<_LineFilter>(
          key: const ValueKey('sales-intake-filter'),
          showSelectedIcon: false,
          segments: [
            ButtonSegment(
              value: _LineFilter.review,
              label: Text(l10n.salesIntakeFilterReview(_reviewLines.length)),
            ),
            ButtonSegment(
              value: _LineFilter.all,
              label: Text(l10n.salesIntakeFilterAll(_result.lines.length)),
            ),
          ],
          selected: {_filter},
          onSelectionChanged: (s) => setState(() => _filter = s.first),
        ),
      ],
    );
  }

  _LineState _stateOf(SalesIntakeLine line, SalesIntakeLineDecision d) {
    if (!d.split &&
        salesIntakeGoodsBlocked(
          docType: widget.docType,
          goods: d.goods,
          priceMasked: _masked,
        )) {
      return _LineState.blocked;
    }
    if (d.userConfirmed && (d.goods != null || d.split)) {
      return _LineState.confirmed;
    }
    if (line.status == SalesIntakeLineStatus.unmatched && d.goods == null) {
      return _LineState.unmatched;
    }
    if (line.status == SalesIntakeLineStatus.matched && !line.bundle) {
      return _LineState.matched;
    }
    return _LineState.review;
  }

  Widget _matchedTile(
    BuildContext context,
    AppLocalizations l10n,
    SalesIntakeLine line,
  ) {
    final theme = Theme.of(context);
    final d = _decisions.decisionFor(line);
    final goods = d.goods;
    return Material(
      key: ValueKey('sales-intake-line-${line.key}'),
      color: theme.colorScheme.surfaceContainerLow,
      borderRadius: BorderRadius.circular(UtenRadius.lg),
      child: InkWell(
        borderRadius: BorderRadius.circular(UtenRadius.lg),
        onTap: () => setState(() => _expandedMatched.add(line.key)),
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 48),
          child: Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: UtenSpacing.s12,
              vertical: UtenSpacing.s8,
            ),
            child: Row(
              children: [
                Icon(
                  d.include
                      ? Icons.check_circle_rounded
                      : Icons.remove_circle_outline_rounded,
                  size: 20,
                  color: d.include
                      ? UtenColors.success
                      : theme.colorScheme.onSurfaceVariant,
                ),
                const SizedBox(width: UtenSpacing.s8),
                Expanded(
                  child: Text(
                    [
                      l10n.salesIntakeLineNo(line.lineNo ?? line.key),
                      line.partNo ?? line.fileLabel,
                      '→ ${goods?.displayLabel ?? ''}',
                    ].join('  '),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodyMedium,
                  ),
                ),
                const SizedBox(width: UtenSpacing.s8),
                Text(
                  l10n.salesIntakeQty(line.suggestedQty ?? line.qty ?? '-'),
                  style: theme.textTheme.bodyMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
                const SizedBox(width: UtenSpacing.s4),
                Icon(
                  Icons.edit_outlined,
                  size: 18,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _lineCard(
    BuildContext context,
    AppLocalizations l10n,
    SalesIntakeLine line,
  ) {
    final theme = Theme.of(context);
    final d = _decisions.decisionFor(line);
    final state = _stateOf(line, d);
    final accent = state.accent;
    final blocked = state == _LineState.blocked;
    final qty = line.suggestedQty ?? line.qty;
    final price = line.customerUnitPrice;
    final fileCurrency = _result.currency.fileCurrency;
    final reasonText = switch (state) {
      _LineState.matched || _LineState.confirmed => null,
      _LineState.blocked => l10n.salesIntakeBlockedHint,
      _LineState.unmatched =>
        line.reasonText ?? l10n.salesIntakeUnmatchedRemarkHint,
      _LineState.review =>
        line.reasonText ??
            (line.bundle
                ? l10n.salesIntakeBundleHint
                : l10n.salesIntakeMarkerDefault),
    };
    final compact = MediaQuery.sizeOf(context).width < 700;
    final qtyText = qty == null
        ? null
        : Text(
            l10n.salesIntakeQty(qty),
            style: theme.textTheme.titleSmall?.copyWith(
              fontWeight: FontWeight.w700,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          );
    final priceText = price == null
        ? null
        : Text(
            fileCurrency == null
                ? l10n.salesIntakeFilePrice(price)
                : l10n.salesIntakeFilePriceWithCurrency(price, fileCurrency),
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          );
    // 同一句话只说一次: 服务端常把原因同时放在 reasonText 与 warnings 里; 不能导入的行
    // 已有「不能导入」的原因和定价小标签(没有标价/高于标价), 定价提醒不再逐条重复。
    final shownHints = <String>{?reasonText};
    final extraHints = <String>[
      for (final warning in line.warnings)
        if (warning.message != null &&
            warning.code != SalesIntakeWarningCode.bundleLine &&
            !(blocked &&
                !_masked &&
                (warning.code == SalesIntakeWarningCode.noListPrice ||
                    warning.code == SalesIntakeWarningCode.aboveList)) &&
            shownHints.add(warning.message!))
          warning.message!,
    ];
    return Container(
      key: ValueKey('sales-intake-line-${line.key}'),
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        borderRadius: BorderRadius.circular(UtenRadius.xl),
        border: Border.all(color: accent.withValues(alpha: 0.45)),
        boxShadow: UtenElevation.low(
          isDark: theme.brightness == Brightness.dark,
        ),
      ),
      clipBehavior: Clip.antiAlias,
      child: IntrinsicHeight(
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Container(width: 5, color: accent),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(
                  UtenSpacing.s4,
                  UtenSpacing.s8,
                  UtenSpacing.s12,
                  UtenSpacing.s12,
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Row(
                      children: [
                        Tooltip(
                          message: l10n.salesIntakeInclude,
                          child: Checkbox(
                            key: ValueKey('sales-intake-include-${line.key}'),
                            value: d.split
                                ? d.parts.any((p) => p.include)
                                : d.include,
                            onChanged: blocked || (!d.split && d.goods == null)
                                ? null
                                : (v) => setState(() {
                                    final on = v ?? false;
                                    if (d.split) {
                                      for (final p in d.parts) {
                                        p.include =
                                            on &&
                                            p.goods != null &&
                                            !_partBlocked(p.goods);
                                      }
                                    } else {
                                      d.include = on;
                                    }
                                  }),
                          ),
                        ),
                        Text(
                          l10n.salesIntakeLineNo(line.lineNo ?? line.key),
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                        const SizedBox(width: UtenSpacing.s8),
                        if (compact)
                          Flexible(
                            child: _StatusPill(state: state, l10n: l10n),
                          )
                        else
                          _StatusPill(state: state, l10n: l10n),
                        if (!compact) ...[
                          const Spacer(),
                          ?qtyText,
                          if (priceText != null) ...[
                            const SizedBox(width: UtenSpacing.s12),
                            priceText,
                          ],
                        ],
                      ],
                    ),
                    // 手机上数量/单价换到第二行, 不和行号、状态挤在一行里溢出。
                    if (compact && (qtyText != null || priceText != null))
                      Padding(
                        padding: const EdgeInsetsDirectional.only(
                          start: UtenSpacing.s12,
                          bottom: UtenSpacing.s4,
                        ),
                        child: Wrap(
                          spacing: UtenSpacing.s12,
                          runSpacing: UtenSpacing.s4,
                          crossAxisAlignment: WrapCrossAlignment.center,
                          children: [?qtyText, ?priceText],
                        ),
                      ),
                    Padding(
                      padding: const EdgeInsetsDirectional.only(
                        start: UtenSpacing.s12,
                      ),
                      child: _FileText(line: line),
                    ),
                    if (reasonText != null)
                      Padding(
                        padding: const EdgeInsetsDirectional.only(
                          start: UtenSpacing.s12,
                          top: UtenSpacing.s6,
                        ),
                        child: _Hint(
                          icon: state == _LineState.unmatched
                              ? Icons.search_off_rounded
                              : Icons.lightbulb_outline_rounded,
                          text: reasonText,
                          color: state == _LineState.unmatched
                              ? AiTone.error(theme)
                              : AiTone.warning(theme),
                        ),
                      ),
                    for (final hint in extraHints)
                      Padding(
                        padding: const EdgeInsetsDirectional.only(
                          start: UtenSpacing.s12,
                          top: UtenSpacing.s4,
                        ),
                        child: _Hint(
                          icon: Icons.info_outline_rounded,
                          text: hint,
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    const SizedBox(height: UtenSpacing.s8),
                    Padding(
                      padding: const EdgeInsetsDirectional.only(
                        start: UtenSpacing.s12,
                      ),
                      child: d.split
                          ? _buildSplitParts(context, l10n, line, d)
                          : _buildGoodsChoice(context, l10n, line, d, state),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildGoodsChoice(
    BuildContext context,
    AppLocalizations l10n,
    SalesIntakeLine line,
    SalesIntakeLineDecision d,
    _LineState state,
  ) {
    final theme = Theme.of(context);
    final candidates = _candidatesFor(line);
    final goods = d.goods;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        UtenDropdownField(
          key: ValueKey('sales-intake-goods-${line.key}'),
          label: l10n.salesIntakeGoodsLabel,
          hintText: l10n.salesIntakeGoodsHint,
          value: goods?.goodsId,
          allowClear: false,
          searchable: candidates.length > 6,
          autofilled:
              goods != null &&
              line.status != SalesIntakeLineStatus.matched &&
              !d.userConfirmed,
          items: [
            for (final c in candidates)
              UtenDropdownItem(value: c.goodsId, label: c.displayLabel),
          ],
          onChanged: (id) {
            final picked = candidates.where((c) => c.goodsId == id).firstOrNull;
            setState(() => _selectGoods(line, picked));
          },
        ),
        if (goods != null) ...[
          const SizedBox(height: UtenSpacing.s6),
          Wrap(
            spacing: UtenSpacing.s6,
            runSpacing: UtenSpacing.s6,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              for (final reason in goods.reasons) _ReasonChip(text: reason),
              if (!_masked) _PricingChip(goods: goods, l10n: l10n),
            ],
          ),
          // 折扣是按某个币种口径算出来的(如外币文件按人民币标价计算): 把服务端的说明
          // 放在折扣旁边, 销售一眼看得出这个折扣的前提。
          if (!_masked &&
              goods.hasUsableDiscount &&
              goods.pricingNote != null) ...[
            const SizedBox(height: UtenSpacing.s4),
            _Hint(
              key: ValueKey('sales-intake-pricing-note-${line.key}'),
              icon: Icons.info_outline_rounded,
              text: goods.pricingNote!,
              color: AiTone.warning(theme),
            ),
          ],
        ],
        const SizedBox(height: UtenSpacing.s8),
        Wrap(
          spacing: UtenSpacing.s8,
          runSpacing: UtenSpacing.s8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            if (goods != null && !d.userConfirmed && state == _LineState.review)
              UtenButton(
                key: ValueKey('sales-intake-confirm-${line.key}'),
                type: UtenButtonType.success,
                icon: Icons.check_rounded,
                height: 48,
                onPressed: () => setState(() => _selectGoods(line, goods)),
                child: Text(l10n.salesIntakeConfirmChoice),
              ),
            UtenButton(
              key: ValueKey('sales-intake-pick-goods-${line.key}'),
              type: UtenButtonType.ghost,
              icon: Icons.inventory_2_outlined,
              height: 48,
              onPressed: () => _pickGoodsFor(line),
              child: Text(l10n.salesIntakePickFromMaster),
            ),
            if (line.bundle && line.bundleParts.length > 1)
              UtenButton(
                key: ValueKey('sales-intake-split-${line.key}'),
                type: UtenButtonType.secondary,
                icon: Icons.call_split_rounded,
                height: 48,
                onPressed: () => setState(() => d.split = true),
                child: Text(l10n.salesIntakeSplit(line.bundleParts.length)),
              ),
          ],
        ),
        if (goods != null && line.nameEnText != null)
          Padding(
            padding: const EdgeInsets.only(top: UtenSpacing.s4),
            child: InkWell(
              borderRadius: BorderRadius.circular(UtenRadius.control),
              onTap: () => setState(() => d.setNameEn = !d.setNameEn),
              child: Row(
                children: [
                  Checkbox(
                    key: ValueKey('sales-intake-name-en-${line.key}'),
                    value: d.setNameEn,
                    onChanged: (v) => setState(() => d.setNameEn = v ?? false),
                  ),
                  Expanded(
                    child: Text(
                      l10n.salesIntakeSetNameEn(line.nameEnText!),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
      ],
    );
  }

  Widget _buildSplitParts(
    BuildContext context,
    AppLocalizations l10n,
    SalesIntakeLine line,
    SalesIntakeLineDecision d,
  ) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final (index, part) in d.parts.indexed)
          Padding(
            key: ValueKey('sales-intake-part-${line.key}-$index'),
            padding: const EdgeInsets.only(bottom: UtenSpacing.s8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _buildPartRow(context, l10n, line, part, index, theme),
                if (_partBlocked(part.goods))
                  Padding(
                    padding: const EdgeInsetsDirectional.only(
                      start: UtenSpacing.s48,
                      top: UtenSpacing.s4,
                    ),
                    child: _Hint(
                      key: ValueKey(
                        'sales-intake-part-blocked-${line.key}-$index',
                      ),
                      icon: Icons.lightbulb_outline_rounded,
                      text: l10n.salesIntakeBlockedHint,
                      color: AiTone.warning(theme),
                    ),
                  ),
              ],
            ),
          ),
        Align(
          alignment: AlignmentDirectional.centerStart,
          child: UtenButton(
            key: ValueKey('sales-intake-merge-${line.key}'),
            type: UtenButtonType.ghost,
            icon: Icons.merge_rounded,
            height: 48,
            onPressed: () => setState(() => d.split = false),
            child: Text(l10n.salesIntakeMerge),
          ),
        ),
      ],
    );
  }

  Widget _buildPartRow(
    BuildContext context,
    AppLocalizations l10n,
    SalesIntakeLine line,
    SalesIntakePartDecision part,
    int index,
    ThemeData theme,
  ) {
    final blocked = _partBlocked(part.goods);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(top: UtenSpacing.s4),
          child: Checkbox(
            key: ValueKey('sales-intake-part-include-${line.key}-$index'),
            value: part.include && part.goods != null && !blocked,
            onChanged: part.goods == null || blocked
                ? null
                : (v) => setState(() => part.include = v ?? false),
          ),
        ),
        SizedBox(
          width: 120,
          child: Padding(
            padding: const EdgeInsets.only(top: UtenSpacing.s16),
            child: Text(
              part.partNo,
              style: theme.textTheme.bodyLarge?.copyWith(
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ),
        Expanded(
          child: UtenDropdownField(
            label: l10n.salesIntakeGoodsLabel,
            hintText: l10n.salesIntakeGoodsHint,
            value: part.goods?.goodsId,
            allowClear: false,
            items: [
              for (final c in {
                ...part.candidates,
                if (part.goods != null) part.goods!,
              })
                UtenDropdownItem(value: c.goodsId, label: c.displayLabel),
            ],
            onChanged: (id) {
              final picked = [
                ...part.candidates,
                ?part.goods,
              ].where((c) => c.goodsId == id).firstOrNull;
              setState(() => _selectPart(part, picked));
            },
          ),
        ),
        const SizedBox(width: UtenSpacing.s8),
        IconButton(
          tooltip: l10n.salesIntakePickFromMaster,
          constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
          onPressed: () => _pickGoodsFor(line, part: part),
          icon: const Icon(Icons.inventory_2_outlined),
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------- 部件

enum _LineState {
  matched,
  confirmed,
  review,
  unmatched,
  blocked;

  Color get accent => switch (this) {
    _LineState.matched || _LineState.confirmed => UtenColors.success,
    _LineState.review => UtenColors.warning,
    _LineState.unmatched => UtenColors.error,
    _LineState.blocked => UtenColors.slate400,
  };
}

class _PanelHeader extends StatelessWidget {
  const _PanelHeader({
    required this.title,
    required this.subtitle,
    required this.onClose,
    required this.closeTooltip,
  });

  final String title;
  final String subtitle;
  final VoidCallback? onClose;
  final String closeTooltip;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final dark = theme.brightness == Brightness.dark;
    return Container(
      padding: const EdgeInsets.fromLTRB(
        UtenSpacing.s20,
        UtenSpacing.s16,
        UtenSpacing.s12,
        UtenSpacing.s16,
      ),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: AlignmentDirectional.centerStart,
          end: AlignmentDirectional.centerEnd,
          colors: dark
              ? [UtenColors.teal950, theme.colorScheme.surface]
              : [UtenColors.teal50, theme.colorScheme.surface],
        ),
        border: Border(
          bottom: BorderSide(color: theme.colorScheme.outlineVariant),
        ),
      ),
      child: Row(
        children: [
          Container(
            width: 44,
            height: 44,
            decoration: const BoxDecoration(
              shape: BoxShape.circle,
              gradient: LinearGradient(
                colors: [UtenColors.teal400, UtenColors.teal700],
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              ),
            ),
            child: const Icon(
              Icons.auto_awesome_rounded,
              color: Colors.white,
              size: 24,
            ),
          ),
          const SizedBox(width: UtenSpacing.s12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: theme.textTheme.titleLarge?.copyWith(
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: UtenSpacing.s2),
                Text(
                  subtitle,
                  // 手机上文件名常常很长: 给两行, 「共 N 行明细」不被省略号吃掉。
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
          IconButton(
            tooltip: closeTooltip,
            constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
            onPressed: onClose,
            icon: const Icon(Icons.close_rounded),
          ),
        ],
      ),
    );
  }
}

class _StepBadge extends StatelessWidget {
  const _StepBadge({required this.step});

  final int step;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      width: 28,
      height: 28,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: theme.colorScheme.primary,
        shape: BoxShape.circle,
      ),
      child: Text(
        '$step',
        style: theme.textTheme.labelLarge?.copyWith(
          color: theme.colorScheme.onPrimary,
          fontWeight: FontWeight.w800,
        ),
      ),
    );
  }
}

class _StepCard extends StatelessWidget {
  const _StepCard({
    required this.step,
    required this.title,
    required this.child,
  });

  final int step;
  final String title;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        borderRadius: BorderRadius.circular(UtenRadius.xl),
        border: Border.all(color: theme.colorScheme.outlineVariant),
      ),
      padding: const EdgeInsets.all(UtenSpacing.s16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              _StepBadge(step: step),
              const SizedBox(width: UtenSpacing.s8),
              Text(
                title,
                style: theme.textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
          const SizedBox(height: UtenSpacing.s12),
          child,
        ],
      ),
    );
  }
}

class _ClientCandidateTile extends StatelessWidget {
  const _ClientCandidateTile({
    required this.candidate,
    required this.selected,
    required this.onTap,
  });

  final SalesIntakeClientCandidate candidate;
  final bool selected;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: UtenSpacing.s6),
      child: Material(
        key: ValueKey('sales-intake-client-${candidate.clientId}'),
        color: selected
            ? theme.colorScheme.primaryContainer.withValues(alpha: 0.55)
            : theme.colorScheme.surfaceContainerLow,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(UtenRadius.lg),
          side: BorderSide(
            color: selected
                ? theme.colorScheme.primary
                : theme.colorScheme.outlineVariant,
          ),
        ),
        child: InkWell(
          borderRadius: BorderRadius.circular(UtenRadius.lg),
          onTap: onTap,
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 56),
            child: Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: UtenSpacing.s12,
                vertical: UtenSpacing.s8,
              ),
              child: Row(
                children: [
                  Icon(
                    selected
                        ? Icons.radio_button_checked_rounded
                        : Icons.radio_button_unchecked_rounded,
                    color: selected
                        ? theme.colorScheme.primary
                        : theme.colorScheme.onSurfaceVariant,
                  ),
                  const SizedBox(width: UtenSpacing.s12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          candidate.displayName,
                          style: theme.textTheme.bodyLarge?.copyWith(
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        if (candidate.reasons.isNotEmpty) ...[
                          const SizedBox(height: UtenSpacing.s4),
                          Wrap(
                            spacing: UtenSpacing.s6,
                            runSpacing: UtenSpacing.s4,
                            children: [
                              for (final r in candidate.reasons)
                                _ReasonChip(text: r),
                            ],
                          ),
                        ],
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _StatusPill extends StatelessWidget {
  const _StatusPill({required this.state, required this.l10n});

  final _LineState state;
  final AppLocalizations l10n;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final label = switch (state) {
      _LineState.matched => l10n.salesIntakeStatusMatched,
      _LineState.confirmed => l10n.salesIntakeStatusConfirmed,
      _LineState.review => l10n.salesIntakeStatusReview,
      _LineState.unmatched => l10n.salesIntakeStatusUnmatched,
      _LineState.blocked => l10n.salesIntakeStatusBlocked,
    };
    final color = state.accent;
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: UtenSpacing.s8,
        vertical: UtenSpacing.s2,
      ),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(UtenRadius.pill),
      ),
      child: Text(
        label,
        style: theme.textTheme.labelMedium?.copyWith(
          color: switch (state) {
            _LineState.matched || _LineState.confirmed => AiTone.success(theme),
            _LineState.review => AiTone.warning(theme),
            _LineState.unmatched => AiTone.error(theme),
            _LineState.blocked => theme.colorScheme.onSurfaceVariant,
          },
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}

class _FileText extends StatelessWidget {
  const _FileText({required this.line});

  final SalesIntakeLine line;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colour = line.colorAlt ?? line.color;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text.rich(
          TextSpan(
            children: [
              if (line.partNo != null)
                TextSpan(
                  text: '${line.partNo}  ',
                  style: const TextStyle(fontWeight: FontWeight.w800),
                ),
              if (line.description != null) TextSpan(text: line.description),
            ],
          ),
          style: theme.textTheme.bodyLarge,
        ),
        if (line.descriptionAlt != null ||
            colour != null ||
            line.series != null)
          Text(
            [?line.descriptionAlt, ?line.series, ?colour].join(' · '),
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
      ],
    );
  }
}

class _Hint extends StatelessWidget {
  const _Hint({
    super.key,
    required this.icon,
    required this.text,
    required this.color,
  });

  final IconData icon;
  final String text;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, size: 18, color: color),
        const SizedBox(width: UtenSpacing.s6),
        Expanded(
          child: Text(
            text,
            style: theme.textTheme.bodyMedium?.copyWith(color: color),
          ),
        ),
      ],
    );
  }
}

/// 理由小标签的语义: 对得上(绿) / 要留意(黄) / 只是说明(灰)。
enum _ReasonTone { positive, negative, neutral }

/// 服务端理由是固定的中文短语(IntakeTexts): 「不一致 / 不同 / 异常 / 其他客户的」是要留意的,
/// 「AI 建议」只说明来源, 其余(型号一致、系列相近、该客户买过…)是对得上的依据。
_ReasonTone _reasonTone(String text) {
  if (text.contains('不一致') ||
      text.contains('不同') ||
      text.contains('异常') ||
      text.contains('其他客户')) {
    return _ReasonTone.negative;
  }
  if (text.startsWith('AI')) return _ReasonTone.neutral;
  return _ReasonTone.positive;
}

class _ReasonChip extends StatelessWidget {
  const _ReasonChip({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final (Color foreground, Color background) = switch (_reasonTone(text)) {
      _ReasonTone.negative => (
        AiTone.warning(theme),
        UtenColors.warning.withValues(alpha: 0.12),
      ),
      _ReasonTone.positive => (
        AiTone.success(theme),
        UtenColors.success.withValues(alpha: 0.10),
      ),
      _ReasonTone.neutral => (
        theme.colorScheme.onSurfaceVariant,
        theme.colorScheme.surfaceContainerHigh,
      ),
    };
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: UtenSpacing.s8,
        vertical: UtenSpacing.s2,
      ),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(UtenRadius.pill),
      ),
      child: Text(
        text,
        style: theme.textTheme.labelMedium?.copyWith(color: foreground),
      ),
    );
  }
}

class _PricingChip extends StatelessWidget {
  const _PricingChip({required this.goods, required this.l10n});

  final SalesIntakeCandidate goods;
  final AppLocalizations l10n;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final (text, warn) = switch (goods.pricingFlag) {
      _ when goods.hasUsableDiscount => (
        l10n.salesIntakeDiscountPreview(goods.discount!),
        false,
      ),
      SalesIntakePricingFlag.noListPrice => (
        l10n.salesIntakePricingNoListPrice,
        true,
      ),
      SalesIntakePricingFlag.aboveList => (
        l10n.salesIntakePricingAboveList,
        true,
      ),
      SalesIntakePricingFlag.ambiguousCurrency => (
        l10n.salesIntakePricingAmbiguous,
        true,
      ),
      SalesIntakePricingFlag.rateMissing => (
        l10n.salesIntakePricingRateMissing,
        true,
      ),
      SalesIntakePricingFlag.outOfRange => (
        l10n.salesIntakePricingOutOfRange,
        true,
      ),
      _ => (l10n.salesIntakeDiscountPending, true),
    };
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: UtenSpacing.s8,
        vertical: UtenSpacing.s2,
      ),
      decoration: BoxDecoration(
        color: warn
            ? UtenColors.warning.withValues(alpha: 0.12)
            : theme.colorScheme.primaryContainer.withValues(alpha: 0.6),
        borderRadius: BorderRadius.circular(UtenRadius.pill),
      ),
      child: Text(
        text,
        style: theme.textTheme.labelMedium?.copyWith(
          color: warn ? AiTone.warning(theme) : theme.colorScheme.primary,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}

class _MatchedToggle extends StatelessWidget {
  const _MatchedToggle({
    required this.label,
    required this.actionLabel,
    required this.expanded,
    required this.onTap,
  });

  final String label;
  final String actionLabel;
  final bool expanded;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Material(
      key: const ValueKey('sales-intake-matched-toggle'),
      color: UtenColors.success.withValues(alpha: 0.08),
      borderRadius: BorderRadius.circular(UtenRadius.lg),
      child: InkWell(
        borderRadius: BorderRadius.circular(UtenRadius.lg),
        onTap: onTap,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 52),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: UtenSpacing.s12),
            child: Row(
              children: [
                const Icon(
                  Icons.check_circle_rounded,
                  color: UtenColors.success,
                ),
                const SizedBox(width: UtenSpacing.s8),
                Expanded(
                  child: Text(
                    label,
                    style: theme.textTheme.bodyLarge?.copyWith(
                      fontWeight: FontWeight.w600,
                      color: AiTone.success(theme),
                    ),
                  ),
                ),
                Text(
                  actionLabel,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: theme.colorScheme.primary,
                  ),
                ),
                Icon(
                  expanded
                      ? Icons.expand_less_rounded
                      : Icons.expand_more_rounded,
                  color: theme.colorScheme.primary,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _Footer extends StatelessWidget {
  const _Footer({
    required this.summary,
    required this.importLabel,
    required this.cancelLabel,
    required this.onImport,
    required this.onCancel,
  });

  final String summary;
  final String importLabel;
  final String cancelLabel;
  final VoidCallback? onImport;
  final VoidCallback? onCancel;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final compact = MediaQuery.sizeOf(context).width < 700;
    final buttons = [
      UtenButton(
        type: UtenButtonType.ghost,
        size: UtenButtonSize.large,
        height: 56,
        onPressed: onCancel,
        child: Text(cancelLabel),
      ),
      const SizedBox(width: UtenSpacing.s12),
      UtenButton(
        key: const ValueKey('sales-intake-import-all'),
        size: UtenButtonSize.large,
        height: 56,
        icon: Icons.playlist_add_check_rounded,
        onPressed: onImport,
        child: Text(importLabel),
      ),
    ];
    return Container(
      padding: const EdgeInsets.fromLTRB(
        UtenSpacing.s20,
        UtenSpacing.s12,
        UtenSpacing.s20,
        UtenSpacing.s12,
      ),
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        border: Border(
          top: BorderSide(color: theme.colorScheme.outlineVariant),
        ),
        boxShadow: UtenElevation.mid(
          isDark: theme.brightness == Brightness.dark,
        ),
      ),
      child: SafeArea(
        top: false,
        child: compact
            ? Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(summary, style: theme.textTheme.bodyMedium),
                  const SizedBox(height: UtenSpacing.s8),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: buttons,
                  ),
                ],
              )
            : Row(
                children: [
                  Expanded(
                    child: Text(
                      summary,
                      key: const ValueKey('sales-intake-summary'),
                      style: theme.textTheme.bodyLarge,
                    ),
                  ),
                  ...buttons,
                ],
              ),
      ),
    );
  }
}
