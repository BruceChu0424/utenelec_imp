import '../shared/finance_workbench_panel.dart';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';
import '../../../components/buttons/uten_button.dart';
import '../../../components/feedback/uten_busy_overlay.dart';
import '../../../components/feedback/uten_dialog.dart';
import '../../../components/inputs/uten_field_hint_icon.dart';
import '../../../components/inputs/uten_input.dart';
import '../../../components/layout/uten_editable_grid.dart';
import '../../../core/network/api_client.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/network/business_precision.dart';
import '../../../core/network/business_submission_headers.dart';
import '../../../shared/providers/authenticated_scope_provider.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../shared/drafts/form_draft_catalog.dart';
import '../../../shared/drafts/form_draft_mixin.dart';
import '../../../shared/providers/export_context_epoch_provider.dart';
import 'finance_source_table.dart';

const _path = '/finance/open-item-classifications/corrections';
const _labels = {
  'GOODS': '货款',
  'MOULD': '模具款',
  'MATERIAL': '物料金额',
  'PREPAYMENT': '预收款',
};
const _kinds = {
  'SOURCE': '来源',
  'AP_PAYMENT': '实际付款',
  'AR_RECEIPT': '实际收款',
  'AP_OFFSET': '供应商抵销',
  'AR_OFFSET': '客户抵销',
  'AP_ADVANCE_TARGET': '预付应用目标',
};
const _money = {
  'amountOriginal': '原币',
  'amountLocal': '本币',
  'cashLocal': '实际现金本币',
  'bookLocal': '账面核销本币',
  'writeOffOriginal': '冲销原币',
  'writeOffLocal': '冲销本币',
  'sourceLocal': '来源账面本币',
  'targetLocal': '目标账面本币',
};

Future<void> showFinanceClassificationCorrectionDialog(
  BuildContext context, {
  required List<String> ledgerIds,
  String? resumeDraftId,
}) => showFinanceWorkbenchPanel<void>(
  context: context,
  builder: (_) =>
      _Correction(ledgerIds: ledgerIds, resumeDraftId: resumeDraftId),
);

class _Correction extends ConsumerStatefulWidget {
  const _Correction({required this.ledgerIds, this.resumeDraftId});
  final List<String> ledgerIds;
  final String? resumeDraftId;
  @override
  ConsumerState<_Correction> createState() => _CorrectionState();
}

class _Share extends EditableGridRow {
  _Share(this.categories, this.fields, {this.enabled = false});
  final Map<String, String> categories;
  final Map<String, TextEditingController> fields;
  bool enabled;
  String get label => categories.values.map((v) => _labels[v] ?? v).join(' / ');
  Map<String, String> capture() => {
    ...categories,
    for (final e in fields.entries) e.key: e.value.text,
  };
  @override
  void dispose() {
    for (final f in fields.values) {
      f.dispose();
    }
    super.dispose();
  }
}

class _Node {
  _Node(this.original, this.axes, this.grid);
  final Map<String, dynamic> original;
  final List<String> axes;
  final UtenEditableGridController<_Share> grid;
  String get key => '${original['kind']}:${original['objectId']}';
  Map<String, dynamic> get fact =>
      Map<String, dynamic>.from(original['fact'] as Map? ?? {});
  Map<String, dynamic> command() => {
    'kind': original['kind'],
    'objectId': original['objectId'],
    'expectedBatchId': original['expectedBatchId'],
    'expectedRevision': original['expectedRevision'],
    'parts': [
      for (final row in grid.rows)
        if (row.enabled) row.capture(),
    ],
  };
  void dispose() => grid.dispose();
}

class _CorrectionState extends ConsumerState<_Correction>
    with FormDraftMixin<_Correction> {
  late final ApiClient _api;
  late final int _epoch;
  final _reason = TextEditingController();
  final _nodes = <_Node>[];
  Map<String, dynamic> _graph = {};
  Map<String, dynamic>? _pending;
  Map<String, dynamic> _retiredInputs = {};
  Map<String, dynamic> _resolvedRequests = {};
  Map<String, dynamic> _pendingHeaders = {};
  Map<String, dynamic>? _resolutionPending;
  String? _pendingHash, _pendingActor;
  BusinessPrecisionTransport? _sentTransport;
  bool _confirmingResolution = false, _needsFreshGraph = false;
  String? _error;
  int _selected = 0, _generation = 0;
  bool _busy = false, _unknown = false;
  bool get _current =>
      mounted &&
      formDraftIdentityIsCurrent &&
      _epoch == ref.read(exportContextEpochProvider) &&
      identical(_api, ref.read(apiClientProvider));
  bool get _editable => _current && !_busy && !_unknown;
  @override
  FormDraftSpec get formDraftSpec => FormDraftCatalog
      .financeClassificationCorrection
      .spec(routeParameters: {'ledgerIds': widget.ledgerIds.join(',')});
  @override
  bool get formDraftUsesRouterGuard => false;
  @override
  bool get formDraftUseCurrentRoute => false;
  @override
  bool get formDraftBusy => _busy;
  @override
  String? get formDraftResumeId => widget.resumeDraftId;
  @override
  bool get formDraftCanReplaySubmission => _pending != null;
  @override
  Iterable<Listenable> get formDraftListenables => [
    _reason,
    for (final n in _nodes) n.grid,
    for (final n in _nodes)
      for (final r in n.grid.rows) ...r.fields.values,
  ];
  @override
  Map<String, dynamic> captureFormDraft() => {
    'ledgerIds': widget.ledgerIds,
    'graph': _graph,
    'reason': _reason.text,
    'nodes': [
      for (final n in _nodes)
        {
          'key': n.key,
          'rows': [
            for (final r in n.grid.rows)
              {'enabled': r.enabled, 'values': r.capture()},
          ],
        },
    ],
    'retiredInputs': _retiredInputs,
    'resolvedRequests': _resolvedRequests,
    'pendingHeaders': businessSubmissionHeaders(_pendingHeaders),
    'pendingHash': _pendingHash,
    'pendingActor': _pendingActor,
    'resolutionPending': _resolutionPending,
    'needsFreshGraph': _needsFreshGraph,
    'pending': _pending,
    'unknown': _unknown,
    if (_unknown) formDraftUnknownSubmissionKey: true,
  };
  @override
  Future<void> restoreFormDraft(Map<String, dynamic> data) async {
    if ((data['ledgerIds'] as List? ?? []).join(',') !=
        widget.ledgerIds.join(',')) {
      throw StateError('原往来UUID范围与草稿不一致');
    }
    _graph = Map<String, dynamic>.from(data['graph'] as Map? ?? {});
    _replace(_graph);
    _reason.text = '${data['reason'] ?? ''}';
    _retiredInputs = Map<String, dynamic>.from(
      data['retiredInputs'] as Map? ?? {},
    );
    _resolvedRequests = Map<String, dynamic>.from(
      data['resolvedRequests'] as Map? ?? {},
    );
    _pendingHeaders = businessSubmissionHeaders(data['pendingHeaders']);
    _pendingHash = data['pendingHash']?.toString();
    _pendingActor = data['pendingActor']?.toString();
    _needsFreshGraph = data['needsFreshGraph'] == true;
    _resolutionPending = data['resolutionPending'] is Map
        ? Map<String, dynamic>.from(data['resolutionPending'] as Map)
        : null;
    final saved = {for (final n in _maps(data['nodes'])) '${n['key']}': n};
    for (final n in _nodes) {
      final rows = _maps(saved[n.key]?['rows']);
      if (rows.length != n.grid.rows.length) {
        throw StateError('完整关联分类草稿缺少金额行');
      }
      for (var i = 0; i < rows.length; i++) {
        final r = n.grid.rows[i];
        r.enabled = rows[i]['enabled'] == true;
        final values = rows[i]['values'] as Map? ?? {};
        for (final e in r.fields.entries) {
          e.value.text = '${values[e.key] ?? ''}';
        }
      }
    }
    _pending = data['pending'] is Map
        ? Map<String, dynamic>.from(data['pending'] as Map)
        : null;
    _unknown =
        data['unknown'] == true || data[formDraftUnknownSubmissionKey] == true;
    if (_pending != null &&
        (!Uuid.isValidUUID(fromString: '${_pending!['requestId'] ?? ''}') ||
            (_pending!['ledgerIds'] as List? ?? []).join(',') !=
                widget.ledgerIds.join(','))) {
      throw StateError('未知请求的原编号或完整往来范围缺失');
    }
    if (_unknown && _pending == null) {
      throw StateError('原未知提交内容缺失，不能重建或换号重试');
    }
  }

  @override
  void initState() {
    super.initState();
    _api = ref.read(apiClientProvider);
    _epoch = ref.read(exportContextEpochProvider);
    startFormDraftIdentityGuard();
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      await initializeFormDraft();
      if (!_current) return;
      if (_graph.isEmpty) {
        await _load();
      } else {
        setState(() {});
      }
    });
  }

  @override
  void dispose() {
    _reason.dispose();
    for (final n in _nodes) {
      n.dispose();
    }
    super.dispose();
  }

  void _replace(Map<String, dynamic> graph) {
    for (final n in _nodes) {
      n.dispose();
    }
    _nodes.clear();
    _selected = 0;
    final categories = graph['direction'] == 'AR'
        ? ['GOODS', 'MATERIAL']
        : ['GOODS', 'MOULD'];
    for (final original in _maps(graph['nodes'])) {
      final kind = '${original['kind']}';
      final axes = switch (kind) {
        'SOURCE' => ['amountOriginal', 'amountLocal'],
        'AP_PAYMENT' => ['amountOriginal', 'cashLocal', 'bookLocal'],
        'AR_RECEIPT' => [
          'amountOriginal',
          'writeOffOriginal',
          'cashLocal',
          'writeOffLocal',
          'bookLocal',
        ],
        _ => [
          'amountOriginal',
          if (kind != 'AP_ADVANCE_TARGET') 'sourceLocal',
          'targetLocal',
        ],
      };
      final fact = original['fact'] as Map? ?? {};
      final offset = kind == 'AP_OFFSET' || kind == 'AR_OFFSET';
      final sourceCategories =
          kind == 'AR_OFFSET' &&
              fact['sourceOpenItemKind'] == 'CUSTOMER_PREPAYMENT' &&
              fact['sourceLegacyImportId'] == null
          ? ['PREPAYMENT']
          : categories;
      final candidateCategories = offset
          ? [
              for (final source in sourceCategories)
                for (final target in categories)
                  {'sourceCategory': source, 'targetCategory': target},
            ]
          : [
              for (final category in categories) {'category': category},
            ];
      final parts = _maps(original['parts']);
      final grid = UtenEditableGridController<_Share>();
      grid.replaceAll([
        for (final candidate in candidateCategories)
          _Share(candidate, {
            for (final axis in axes)
              axis: TextEditingController(
                text: _part(parts, candidate)?[axis]?.toString() ?? '',
              ),
          }, enabled: _part(parts, candidate) != null),
      ]);
      _nodes.add(_Node(original, axes, grid));
    }
  }

  Future<void> _load({bool preserveInputs = false}) async {
    if (!_current || _busy || _unknown) return;
    final generation = ++_generation;
    final previous = <String, dynamic>{
      if (preserveInputs) ..._retiredInputs,
      if (preserveInputs)
        for (final n in _nodes)
          n.key: [
            for (final r in n.grid.rows)
              {'enabled': r.enabled, 'values': r.capture()},
          ],
    };
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final result = await _api.get(
        '$_path/graph',
        query: {'ledgerIds': widget.ledgerIds.join(',')},
      );
      if (!_current || generation != _generation) return;
      final nextKeys = {
        for (final n in _maps(result['nodes'])) '${n['kind']}:${n['objectId']}',
      };
      final retired = {
        for (final e in previous.entries)
          if (!nextKeys.contains(e.key)) e.key: e.value,
      };
      if (retired.length > 512) {
        setState(() => _error = '待核原输入超过512组，原图与草稿保留，请先核对归档输入');
        return;
      }
      setState(() {
        _graph = result;
        _replace(result);
        _needsFreshGraph = false;
        _retiredInputs = retired;
        if (preserveInputs) {
          for (final n in _nodes) {
            final saved = _maps(previous[n.key]);
            for (final row in n.grid.rows) {
              for (final candidate in saved) {
                final values = candidate['values'] as Map? ?? {};
                if (row.categories.entries.every(
                  (e) => values[e.key] == e.value,
                )) {
                  row.enabled = candidate['enabled'] == true;
                  for (final f in row.fields.entries) {
                    f.value.text = '${values[f.key] ?? ''}';
                  }
                  break;
                }
              }
            }
          }
          _pending = null;
          _error =
              '已重新读取完整实际图并保留原金额输入，请逐行核对当前版本${retired.isEmpty ? '' : '；另有${retired.length}组原输入保留在私有草稿'}';
        }
      });
      markFormDraftChanged();
    } catch (e) {
      if (_current && generation == _generation) {
        setState(() => _error = _message(e));
      }
    } finally {
      if (_current && generation == _generation) setState(() => _busy = false);
    }
  }

  void _fill(_Node n, _Share selected) {
    if (!_editable) return;
    setState(() {
      for (final r in n.grid.rows) {
        r.enabled = identical(r, selected);
        if (r.enabled) {
          for (final e in r.fields.entries) {
            e.value.text = '${n.fact['${e.key}Exact'] ?? n.fact[e.key] ?? ''}';
          }
        }
      }
    });
    markFormDraftChanged();
  }

  Future<void> _submit() async {
    if (!_current || _busy || _nodes.isEmpty) return;
    if (_resolutionPending != null || _confirmingResolution) {
      setState(() => _error = '已开始核对并封口原请求，请继续核对该原终局命令');
      return;
    }
    if (_needsFreshGraph) {
      setState(() => _error = '旧请求已永久封口，请先显式重新读取完整图，再核对新请求');
      return;
    }
    if (!_unknown) {
      if (_reason.text.trim().isEmpty ||
          _nodes.any((n) => !n.grid.rows.any((r) => r.enabled))) {
        setState(() => _error = '请填写更正依据，并明确每个来源及全部关联行的逐轴分配');
        return;
      }
      _pendingHash = null;
      _pendingActor = null;
      _pendingHeaders = {};
      _resolutionPending = null;
      _pending = {
        'requestId': const Uuid().v4(),
        'ledgerIds': widget.ledgerIds,
        'expectedGraphFingerprint': _graph['graphFingerprint'],
        'reason': _reason.text,
        'nodes': [for (final n in _nodes) n.command()],
      };
      setState(() {
        _busy = true;
        _error = null;
      });
      try {
        final scope = await captureFormDraftRequestScope();
        final proof = await scope.run(
          () => _api.post('$_path/preview', body: _pending),
        );
        if (!_current) return;
        final hash = proof['commandHash']?.toString(),
            actor = proof['actorId']?.toString();
        if (proof['status'] != 'VALIDATED' ||
            hash == null ||
            !RegExp(r'^[0-9a-f]{64}$').hasMatch(hash) ||
            actor == null ||
            actor.isEmpty) {
          throw ApiException(
            'CLASSIFICATION_PREVIEW_INCOMPLETE',
            '原完整命令预览校验不完整，请保留原输入',
          );
        }
        final owner = ref.read(authenticatedScopeProvider)?.userId;
        if (owner != null && owner != actor) {
          throw ApiException(
            'CLASSIFICATION_IDENTITY_CHANGED',
            '服务器预览操作人与原私有草稿身份不一致',
          );
        }
        _pendingHash = hash;
        _pendingActor = actor;
      } catch (e) {
        if (_current) setState(() => _error = _message(e));
        return;
      } finally {
        if (_current) setState(() => _busy = false);
      }
      if (!_current || !mounted) return;
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (ctx) => UtenAlertDialog(
          title: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text('确认整图更正'),
              UtenFieldHintIcon(
                info:
                    '已核对${_nodes.length}个完整节点。只追加分类元数据版本，保留原真实付款、收款、抵销、预付及所有金额轴。',
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('继续核对'),
            ),
            UtenButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('确认更正'),
            ),
          ],
        ),
      );
      if (confirmed != true || !_current) return;
    }
    final wasUnknown = _unknown;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final scope = await captureFormDraftRequestScope();
      await runFormDraftSubmission(() {
        _sentTransport = BusinessPrecisionTransport.current;
        if (!wasUnknown) {
          _pendingHeaders = _headersFor(_sentTransport);
        }
        return scope.run(
          () => _api.post(
            _path,
            body: _pending,
            headers: businessSubmissionHeaders(_pendingHeaders),
          ),
        );
      });
      if (!_current) return;
      _unknown = false;
      await completeFormDraft();
      if (mounted) Navigator.pop(context);
    } catch (e) {
      if (_sentTransport != null) {
        _pendingHeaders = _headersFor(_sentTransport);
      }
      if (_current) {
        setState(() {
          _unknown = wasUnknown || !_rejected(e);
          _error = _message(e);
        });
        try {
          await saveFormDraftNow();
        } catch (saveError) {
          if (_current) {
            setState(
              () =>
                  _error = '${_message(e)}；${describeFormSaveError(saveError)}',
            );
          }
        }
      }
    } finally {
      if (_current) setState(() => _busy = false);
    }
  }

  Map<String, dynamic> _headersFor(BusinessPrecisionTransport? transport) =>
      businessSubmissionHeaders({
        if (transport?.encodedHeader != null)
          businessPrecisionHeader: transport!.encodedHeader,
      });
  Future<void> _resolveOriginal() async {
    if (!_current ||
        _busy ||
        !_unknown ||
        _pending == null ||
        _confirmingResolution) {
      return;
    }
    if (_pendingHash == null || _pendingActor == null) {
      setState(() => _error = '原服务器命令校验缺失，请保留原请求继续核对，不能另行封口');
      return;
    }
    if (_resolutionPending == null) {
      _confirmingResolution = true;
      bool? confirmed;
      try {
        confirmed = await showDialog<bool>(
          context: context,
          builder: (ctx) => UtenAlertDialog(
            title: const Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Flexible(child: Text('核对并终止旧未写请求')),
                UtenFieldHintIcon(
                  info:
                      '若原更正已经成功，只返回原回执；若尚未执行，将永久封口原请求编号，晚到的原请求也不能执行。原完整输入保留后再重新核对。',
                ),
              ],
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('继续保留原请求'),
              ),
              UtenButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text('核对并封口'),
              ),
            ],
          ),
        );
      } finally {
        _confirmingResolution = false;
      }
      if (confirmed != true || !_current) return;
      _resolutionPending = Map<String, dynamic>.from(
        jsonDecode(
              jsonEncode({
                'original': _pending,
                'reason': '本人明确核对并永久终止原未写更正，保留原命令重新核对',
                'expectedCommandHash': _pendingHash,
              }),
            )
            as Map,
      );
    }
    final original = Map<String, dynamic>.from(
      jsonDecode(jsonEncode(_pending)) as Map,
    );
    final originalHash = _pendingHash, originalActor = _pendingActor;
    final originalHeaders = businessSubmissionHeaders(_pendingHeaders);
    final originalResolution = Map<String, dynamic>.from(
      jsonDecode(jsonEncode(_resolutionPending)) as Map,
    );
    if (jsonEncode(originalResolution['original']) != jsonEncode(original) ||
        originalResolution['expectedCommandHash'] != originalHash) {
      setState(() => _error = '原封口命令与未知请求不一致，不能换用另一内容');
      return;
    }
    final requestId = '${original['requestId']}';
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final scope = await captureFormDraftRequestScope();
      // A separate exact metadata command seals the old UUID. It never enters the frozen original-write transport.
      final proof = await scope.run(
        () => _api.post(
          '$_path/requests/$requestId/resolve',
          body: _resolutionPending,
        ),
      );
      if (!_current) return;
      final owner = ref.read(authenticatedScopeProvider)?.userId;
      if (proof['requestId'] != requestId ||
          proof['actorId'] != _pendingActor ||
          owner != null && owner != proof['actorId'] ||
          proof['commandHash'] != _pendingHash ||
          !const {'APPLIED', 'ABANDONED'}.contains(proof['status'])) {
        throw ApiException(
          'CLASSIFICATION_RECEIPT_MISMATCH',
          '原更正终局回执与请求、本人或完整命令不一致，原请求继续保留',
        );
      }
      _resolvedRequests[requestId] = jsonDecode(
        jsonEncode({
          'path': _path,
          'body': original,
          'headers': businessSubmissionHeaders(_pendingHeaders),
          'requestId': requestId,
          'receipt': proof,
          'resolutionCommand': _resolutionPending,
        }),
      );
      if (proof['status'] == 'APPLIED') {
        _unknown = false;
        await completeFormDraft();
        if (mounted) Navigator.pop(context);
        return;
      }
      _unknown = false;
      _needsFreshGraph = true;
      _pending = null;
      _pendingHash = null;
      _pendingActor = null;
      _pendingHeaders = {};
      _resolutionPending = null;
      await checkpointFormDraftAfterConfirmedMutation();
      if (_current) {
        setState(() => _error = '原请求已永久封口且未应用，原输入和终局回执已保留；请重新读取完整图后逐行核对');
      }
    } catch (e) {
      if (_current) {
        _pending = original;
        _pendingHash = originalHash;
        _pendingActor = originalActor;
        _pendingHeaders = originalHeaders;
        _resolutionPending = originalResolution;
        _unknown = true;
        setState(() => _error = _message(e));
        try {
          await saveFormDraftNow();
        } catch (saveError) {
          if (_current) {
            setState(
              () =>
                  _error = '${_message(e)}；${describeFormSaveError(saveError)}',
            );
          }
        }
      }
    } finally {
      if (_current) setState(() => _busy = false);
    }
  }

  Future<void> _close() async {
    if (_busy) return;
    if (await confirmFormDraftExit() && mounted) Navigator.pop(context);
  }

  String _nodeHint(_Node n) {
    String categories(Object? id) {
      final all = [
        ..._maps(_graph['nodes']),
        ..._maps(_graph['readOnlySources']),
      ];
      for (final source in all) {
        if (source['kind'] == 'SOURCE' && source['objectId'] == id) {
          return _maps(source['parts'])
              .map(
                (p) =>
                    '${_labels[p['category']] ?? p['category']} 原币${p['amountOriginal']} / 本币${p['amountLocal']}',
              )
              .join('；');
        }
      }
      return '按真实预收资产来源，不伪造应收分类';
    }

    if (n.original['kind'] == 'AP_OFFSET' ||
        n.original['kind'] == 'AR_OFFSET') {
      return '原来源归属：${categories(n.fact['sourceLedgerId'])}。原目标归属：${categories(n.fact['targetLedgerId'])}。对端需改变时，从来源目录一并选择，完整更正。';
    }
    return '原真实金额及发生/反向日期保留，未归类行须完整明确所有金额轴。';
  }

  @override
  Widget build(BuildContext context) {
    ref.watch(exportContextEpochProvider);
    ref.watch(apiClientProvider);
    if (!_current) {
      return withFormDraft(
        UtenAlertDialog(
          title: const Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('往来分类整图更正'),
              UtenFieldHintIcon(info: '身份、服务器或数据范围已变化，原账号私有草稿保留。'),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('关闭'),
            ),
          ],
        ),
      );
    }
    final selected = _nodes.isEmpty
        ? null
        : _nodes[_selected.clamp(0, _nodes.length - 1)];
    return withFormDraft(
      Stack(
        children: [
          UtenDialogFrame(
            maxWidth: 1250,
            fillHeight: true,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                UtenDialogHeader(
                  title: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Flexible(child: Text('往来分类整图更正')),
                      UtenFieldHintIcon(
                        info:
                            _error ??
                            (_unknown
                                ? '原提交结果未知。原内容、编号和操作已冻结，重试只核对同一请求。'
                                : '完整关联图最多512节点，实际付款、回款、冲销及两端账面金额分别守恒；不分摊、不舍入、不改原款项。'),
                      ),
                    ],
                  ),
                  showCloseButton: true,
                  onClose: _busy ? null : _close,
                ),
                Expanded(
                  child: SingleChildScrollView(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        SizedBox(
                          height: 200,
                          child: financeSourceTable(
                            tableKey: 'finance.classification.correction.nodes',
                            columns: [
                              financeSourceColumn(
                                'kind',
                                '节点',
                                value: (r) => _kinds['${r['kind']}'],
                              ),
                              financeSourceColumn(
                                'billNo',
                                '业务单号',
                                width: 240,
                                value: (r) {
                                  final f = r['fact'] as Map?;
                                  return '${f?['billNo'] ?? f?['sourceBillNo'] ?? f?['applicationId'] ?? f?['offsetId'] ?? ''}';
                                },
                              ),
                              financeSourceColumn('expectedRevision', '原分类版本'),
                              financeSourceColumn(
                                'actualStatus',
                                '实际状态',
                                value: (r) {
                                  final status = (r['fact'] as Map?)?['status'];
                                  return status == -1 || status == 'REVERSED'
                                      ? '已反向'
                                      : status == 1 || status == 'APPLIED'
                                      ? '有效'
                                      : '待核对';
                                },
                              ),
                              financeSourceColumn(
                                'eventDate',
                                '发生日期',
                                type: 'date',
                                value: (r) {
                                  final f = r['fact'] as Map? ?? {};
                                  return '${f['billDate'] ?? f['effectiveDate'] ?? f['effectiveFrom'] ?? ''}';
                                },
                              ),
                              financeSourceColumn(
                                'reversedAt',
                                '反向日期',
                                type: 'date',
                                value: (r) =>
                                    ((r['fact'] as Map?)?['reversedAt'])
                                        ?.toString(),
                              ),
                              financeSourceColumn(
                                'sourceBills',
                                '两端业务单号',
                                width: 280,
                                value: (r) {
                                  final f = r['fact'] as Map? ?? {};
                                  return '${f['sourceBillNo'] ?? f['appliedBillNo'] ?? ''}${f['targetBillNo'] == null ? '' : ' / ${f['targetBillNo']}'}';
                                },
                              ),
                            ],
                            rows: [for (final n in _nodes) n.original],
                            idOf: (r) => '${r['kind']}:${r['objectId']}',
                            busy: _busy,
                            onOpen: (row) {
                              if (_busy) return;
                              setState(
                                () => _selected = _nodes.indexWhere(
                                  (n) =>
                                      n.key ==
                                      '${row['kind']}:${row['objectId']}',
                                ),
                              );
                            },
                          ),
                        ),
                        if (selected != null) ...[
                          Padding(
                            padding: const EdgeInsets.all(UtenSpacing.s8),
                            child: Row(
                              children: [
                                Expanded(
                                  child: Text(
                                    '${_kinds[selected.original['kind']]} ${selected.fact['billNo'] ?? selected.fact['offsetId'] ?? selected.fact['applicationId'] ?? ''}',
                                  ),
                                ),
                                UtenFieldHintIcon(
                                  info:
                                      selected.original['kind'] ==
                                          'AP_ADVANCE_TARGET'
                                      ? '原审批目标：${_labels[selected.fact['originalCategory']]}；原资产归属：${_labels[selected.fact['assetSourceCategory']]}。目标当前份额另存，原资产只计一次。'
                                      : _nodeHint(selected),
                                ),
                              ],
                            ),
                          ),
                          SizedBox(
                            height: 150,
                            child: financeSourceTable(
                              tableKey:
                                  'finance.classification.correction.facts.${selected.original['kind']}',
                              columns: [
                                for (final axis in selected.axes)
                                  financeSourceColumn(
                                    axis,
                                    axis == 'amountOriginal'
                                        ? '原币原额'
                                        : axis == 'amountLocal'
                                        ? '本币原额'
                                        : '原${_money[axis]}',
                                    type: 'money',
                                    width: 200,
                                  ),
                              ],
                              rows: [selected.fact],
                              idOf: (_) => selected.key,
                              showColumnChooser: false,
                            ),
                          ),
                          SizedBox(
                            height: 360,
                            child: UtenEditableGrid<_Share>(
                              key: ValueKey(selected.key),
                              tableKey:
                                  'finance.classification.correction.parts.${selected.original['kind']}',
                              controller: selected.grid,
                              columns: [
                                EditableGridColumn<_Share>(
                                  key: 'enabled',
                                  label: '选用',
                                  width: 70,
                                  textOf: (r) => r.enabled ? '已选' : '未选',
                                  cellBuilder: (_, r) => Checkbox(
                                    value: r.enabled,
                                    onChanged: _editable
                                        ? (v) {
                                            setState(
                                              () => r.enabled = v ?? false,
                                            );
                                            markFormDraftChanged();
                                          }
                                        : null,
                                  ),
                                ),
                                EditableGridColumn<_Share>(
                                  key: 'category',
                                  label: '归属',
                                  width: 220,
                                  textOf: (r) => r.label,
                                  cellBuilder: (_, r) => Text(r.label),
                                ),
                                for (final axis in selected.axes)
                                  EditableGridColumn<_Share>(
                                    key: axis,
                                    label: _money[axis]!,
                                    width: 210,
                                    numeric: true,
                                    textOf: (r) => r.fields[axis]!.text,
                                    exactValueOf: (r) => r.fields[axis]!.text,
                                    listenableOf: (r) => r.fields[axis]!,
                                    cellBuilder: (_, r) => UtenInput(
                                      key: ValueKey(
                                        '${selected.key}-${r.label}-$axis',
                                      ),
                                      controller: r.fields[axis]!,
                                      enabled: _editable && r.enabled,
                                      keyboardType:
                                          const TextInputType.numberWithOptions(
                                            decimal: true,
                                            signed: true,
                                          ),
                                      onChanged: (_) => markFormDraftChanged(),
                                    ),
                                  ),
                                EditableGridColumn<_Share>(
                                  key: 'fill',
                                  label: '操作',
                                  width: 210,
                                  textOf: (r) => '全部分配为${r.label}',
                                  cellBuilder: (_, r) => TextButton(
                                    onPressed: _editable
                                        ? () => _fill(selected, r)
                                        : null,
                                    child: Text('全部分配为${r.label}'),
                                  ),
                                ),
                              ],
                              showAddRow: false,
                              showRowDelete: false,
                              showRemoveRowsAction: false,
                              showColumnSettings: false,
                              selectionEnabled: _editable,
                            ),
                          ),
                        ] else
                          const SizedBox(height: 180),
                        Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: UtenSpacing.s16,
                          ),
                          child: UtenInput(
                            label: '更正依据',
                            controller: _reason,
                            enabled: _editable,
                            onChanged: (_) => markFormDraftChanged(),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                UtenDialogActions(
                  children: [
                    if (_unknown)
                      TextButton(
                        onPressed:
                            _busy ||
                                _pendingHash == null ||
                                _pendingActor == null
                            ? null
                            : _resolveOriginal,
                        child: const Text('核对并终止旧未写请求'),
                      ),
                    TextButton(
                      onPressed: _editable
                          ? () => _load(preserveInputs: true)
                          : null,
                      child: const Text('重新读取关联图'),
                    ),
                    TextButton(
                      onPressed: _busy ? null : _close,
                      child: const Text('关闭'),
                    ),
                    UtenButton(
                      onPressed:
                          _busy ||
                              _nodes.isEmpty ||
                              _needsFreshGraph ||
                              _resolutionPending != null
                          ? null
                          : _submit,
                      child: Text(_unknown ? '核对并重试原更正' : '核对整图并更正'),
                    ),
                  ],
                ),
              ],
            ),
          ),
          if (_busy)
            const UtenBusyOverlay(
              title: '正在核对完整关联分类',
              showDoNotLeaveHint: false,
            ),
        ],
      ),
    );
  }
}

Map<String, dynamic>? _part(
  List<Map<String, dynamic>> parts,
  Map<String, String> categories,
) {
  for (final p in parts) {
    if (categories.entries.every((e) => p[e.key] == e.value)) return p;
  }
  return null;
}

List<Map<String, dynamic>> _maps(Object? value) => [
  if (value is List)
    for (final r in value)
      if (r is Map) Map<String, dynamic>.from(r),
];
String _message(Object e) =>
    e is ApiException ? e.message : '操作未完成，请保留原请求并核对网络';
bool _rejected(Object e) =>
    e is ApiException &&
    e.hasResponseCode &&
    (e.httpStatus ?? 0) >= 400 &&
    (e.httpStatus ?? 0) < 500 &&
    e.httpStatus != 408;
