import 'dart:convert';

import 'package:flutter/material.dart';
import '../../../shared/drafts/form_draft_mixin.dart';
import '../../../shared/drafts/form_draft_catalog.dart';
import '../../../shared/drafts/form_draft_field_codec.dart';
import '../models/warehouse_form_draft_codec.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:uuid/uuid.dart';

import '../../../components/buttons/uten_back_button.dart';
import '../../../components/buttons/uten_button.dart';
import '../../../components/feedback/uten_busy_overlay.dart';
import '../../../components/feedback/uten_empty.dart';
import '../../../components/inputs/uten_input_decoration.dart';
import '../../../components/layout/uten_app_bar.dart';
import '../../../components/layout/uten_collapsing_header_scroll_view.dart';
import '../../../components/layout/uten_content_container.dart';
import '../../../components/layout/uten_floating_action_group.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/router/nav_helpers.dart';
import '../../../core/router/route_names.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../core/ui/app_notification.dart';
import '../../../shared/auth/permissions.dart';
import '../../../shared/measurement/weight_params.dart';
import '../../../shared/measurement/weight_prefs.dart';
import '../../../shared/providers/list_refresh_provider.dart';
import '../../../shared/providers/master_name_provider.dart';
import '../../../shared/models/production_material_discovery.dart';
import '../../../shared/widgets/warehouse_picker_panel.dart';
import '../models/outbound_weight_entry.dart';
import '../models/production_draw_discovery_row.dart';
import '../models/stock_doc.dart';
import '../providers/warehouse_count_refresh.dart';
import '../repositories/production_draw_task_repository.dart';
import '../repositories/stock_doc_repository.dart';
import '../repositories/production_material_discovery_repository.dart';
import '../widgets/production_draw_detail_table.dart';

/// 多单共用单张领料详情的逐行表格，进入页面只读取，确认后才整批出库。
///
/// 本次重量 (ADR-135 §3.6): 现有领料单每行 (本次 = 待出库) 与材料申请行都可录实称重量,
/// 随批量请求 weights / discoveries[].weights 发出; 只落出库流水, 不阻断出库。
class ProductionDrawBatchIssuePage extends ConsumerStatefulWidget {
  const ProductionDrawBatchIssuePage({
    super.key,
    this.documentIds = const [],
    this.discoveryRequestIds = const [],
  });
  final List<String> documentIds;
  final List<String> discoveryRequestIds;

  @override
  ConsumerState<ProductionDrawBatchIssuePage> createState() =>
      _ProductionDrawBatchIssuePageState();
}

class _ProductionDrawBatchIssuePageState
    extends ConsumerState<ProductionDrawBatchIssuePage>
    with FormDraftMixin<ProductionDrawBatchIssuePage> {
  final _remark = TextEditingController();
  List<StockDocDetail>? _documents;
  List<ProductionMaterialDiscoveryDetail> _discoveries = [];
  final _discoveryRows = <ProductionDrawDiscoveryRow>[];

  /// 现有领料单逐行本次重量 (键 = item.id; 只建待出库 > 0 的行)。
  final _issueWeights = <String, OutboundWeightEntry>{};

  /// 本次 build 盯住的页内单重参数缓存 (有带货品的行时才建)。
  WeightParamsCache? _weightCache;
  String? _error;
  bool _loading = true;
  bool _saving = false;
  String? _requestFingerprint;
  String? _requestKey;
  bool _uncertain = false, _showValidation = false;
  String? _submitError;
  List<Map<String, dynamic>> _submittedDiscoveries = [];
  List<Map<String, dynamic>> _submittedWeights = [];
  List<String> _submittedDocIds = [];
  String? _submittedReason;
  int _nextDiscoveryRow = 0;

  bool _submissionPending = false;
  @override
  bool get formDraftBusy => _saving || _uncertain;
  @override
  FormDraftSpec get formDraftSpec => FormDraftCatalog.warehouseDraw.spec(
    title: '批量领料出库填写',
    route: Uri(
      path: RouteName.warehouseProductionDrawBatchIssue,
      queryParameters: {
        'documentIds': widget.documentIds.join(','),
        'discoveryRequestIds': widget.discoveryRequestIds.join(','),
      },
    ).toString(),
  );
  @override
  Iterable<Listenable> get formDraftListenables => [
    _remark,
    for (final row in _discoveryRows) ...[row.quantity, row.weight.weight],
    for (final entry in _issueWeights.values) entry.weight,
  ];

  Iterable<OutboundWeightEntry> get _weightEntries => [
    ..._issueWeights.values,
    for (final row in _discoveryRows) row.weight,
  ];

  /// 草稿里的一行重量: 千克 + 是否按称重改数量。
  static Map<String, dynamic> _weightDraft(OutboundWeightEntry entry) => {
    'kg': entry.kg,
    'qtyFromWeight': entry.qtyFromWeight,
  };

  static void _restoreWeight(OutboundWeightEntry entry, Object? raw) {
    if (raw is! Map) return;
    final kg = (raw['kg'] as num?)?.toDouble();
    entry.weight.setKg(
      kg,
      qtyFromWeight: kg != null && raw['qtyFromWeight'] == true,
    );
  }

  /// 按最新明细重建现有领料单的本次重量 (只建待出库 > 0 的行)。
  void _rebuildIssueWeights(List<StockDocDetail> documents) {
    for (final entry in _issueWeights.values) {
      entry.dispose();
    }
    _issueWeights.clear();
    final unit = ref.read(warehouseWeightUnitsPrefsProvider).entry;
    for (final document in documents) {
      for (final item in document.items) {
        final id = item.id;
        if (id == null || item.remainingQty <= 0) continue;
        _issueWeights[id] = drawRemainingWeightEntry(item, unit: unit);
      }
    }
  }

  /// 一个材料申请的提交体: 领料明细 + 称了的行的重量 (IssueWeight, 按
  /// 货品+颜色+实际发料仓对到服务端建好的领料明细; 一行都没称时不带 weights)。
  static Map<String, dynamic> _discoveryJson(
    ProductionMaterialDiscoveryDetail request,
    List<ProductionDrawDiscoveryRow> rows,
  ) {
    final weights = [for (final row in rows) ?row.weightJson()];
    return {
      'requestId': request.requestId,
      'expectedVersion': request.version,
      'items': [for (final row in rows) row.toJson()],
      if (weights.isNotEmpty) 'weights': weights,
    };
  }

  /// 下一帧 (缓存已在 build 里盯住) 按行批量取单重参数。
  void _ensureWeightParams() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        ensureOutboundWeightParams(_weightCache, _weightEntries);
      }
    });
  }

  @override
  Map<String, dynamic> captureFormDraft() => {
    'remark': _remark.text,
    'requestFingerprint': _requestFingerprint,
    'requestKey': _requestKey,
    'uncertain': _uncertain || _submissionPending,
    'submittedDiscoveries': _submittedDiscoveries,
    'submittedWeights': _submittedWeights,
    'submittedDocIds': _submittedDocIds,
    'submittedReason': _submittedReason,
    'nextRow': _nextDiscoveryRow,
    'documents': _documents?.map(stockDocumentDraftFacts).toList(),
    'discoveries': _discoveries.map(discoveryDraftFacts).toList(),
    'rows': [
      for (final row in _discoveryRows)
        {
          'requestId': row.request.requestId,
          'index': row.index,
          'values': row.values,
          'qty': row.quantity.text,
          'qtyAutofilled': row.quantity.autofilled,
          'weight': _weightDraft(row.weight),
        },
    ],
    'weights': {
      for (final entry in _issueWeights.entries)
        if (entry.value.kg != null) entry.key: _weightDraft(entry.value),
    },
  };
  @override
  Future<void> restoreFormDraft(Map<String, dynamic> data) async {
    _remark.text = draftText(data, 'remark');
    _requestFingerprint = data['requestFingerprint'] as String?;
    _requestKey = data['requestKey'] as String?;
    _uncertain = data['uncertain'] == true;
    _submittedDiscoveries = draftMaps(data['submittedDiscoveries']);
    _submittedWeights = draftMaps(data['submittedWeights']);
    _submittedDocIds = draftStrings(data['submittedDocIds']);
    _submittedReason = data['submittedReason'] as String?;
    _nextDiscoveryRow = (data['nextRow'] as num?)?.toInt() ?? 0;
    final original = draftMaps(
      data['discoveries'],
    ).map(ProductionMaterialDiscoveryDetail.fromJson).toList();
    if (_uncertain) {
      // Retain exact reviewed facts for same-key replay; the server decides whether it already committed.
      _documents = draftMaps(
        data['documents'],
      ).map(StockDocDetail.fromJson).toList();
      _rebuildIssueWeights(_documents!);
      _discoveries = original;
      _error = null;
    } else if (original.any(
      (old) => !_discoveries.any(
        (fresh) =>
            fresh.requestId == old.requestId &&
            fresh.version == old.version &&
            fresh.canConfigure,
      ),
    )) {
      throw const FormatException('原领料材料申请已变化，请核对最新任务；填写草稿保留');
    }
    for (final row in _discoveryRows) {
      row.dispose();
    }
    _discoveryRows.clear();
    for (final item in draftMaps(data['rows'])) {
      final request = _discoveries
          .where((request) => request.requestId == item['requestId'])
          .firstOrNull;
      if (request == null) throw const FormatException('原材料申请已不可用，不能重建为另一申请');
      final row = ProductionDrawDiscoveryRow(
        request: request,
        index: (item['index'] as num).toInt(),
        initial: draftMap(item['values']),
      );
      _restoreWeight(row.weight, item['weight']);
      if (item['qtyAutofilled'] == true) {
        row.quantity.setAutomaticText(draftText(item, 'qty'));
      } else {
        row.quantity.text = draftText(item, 'qty');
      }
      _discoveryRows.add(row);
    }
    final weights = data['weights'];
    if (weights is Map) {
      for (final entry in _issueWeights.entries) {
        _restoreWeight(entry.value, weights[entry.key]);
      }
    }
    if (mounted) setState(() {});
    _ensureWeightParams();
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  @override
  void dispose() {
    _remark.dispose();
    for (final row in _discoveryRows) {
      row.dispose();
    }
    for (final entry in _issueWeights.values) {
      entry.dispose();
    }
    super.dispose();
  }

  Future<void> _load() async {
    if (_saving || _uncertain) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final ids =
          widget.documentIds.where((id) => id.isNotEmpty).toSet().toList()
            ..sort();
      final discoveryIds =
          widget.discoveryRequestIds
              .map((id) => id.trim())
              .where((id) => id.isNotEmpty)
              .toSet()
              .toList()
            ..sort();
      if (ids.length + discoveryIds.length == 0 ||
          ids.length + discoveryIds.length >
              ProductionDrawTaskRepository.batchIssueLimit) {
        throw const FormatException('请返回任务中心选择 1 至 50 张领料单或已知材料申请');
      }
      final names = ref.read(masterNameServiceProvider);
      await names.ensureLoaded();
      final repository = ref.read(
        stockDocRepositoryProvider(StockDocType.draw),
      );
      final documents = <StockDocDetail>[];
      // 限制并发，避免一次选择 50 张时把详情接口打满。
      for (var offset = 0; offset < ids.length; offset += 5) {
        documents.addAll(
          await Future.wait(ids.skip(offset).take(5).map(repository.detail)),
        );
      }
      if (documents.any(
        (document) => document.docType != StockDocType.draw.code,
      )) {
        throw const FormatException('所选单据包含非生产领料单，请返回重新选择');
      }
      final discoveries = <ProductionMaterialDiscoveryDetail>[];
      final discoveryRepository = ref.read(
        productionMaterialDiscoveryRepositoryProvider,
      );
      for (var offset = 0; offset < discoveryIds.length; offset += 5) {
        discoveries.addAll(
          await Future.wait(
            discoveryIds.skip(offset).take(5).map(discoveryRepository.detail),
          ),
        );
      }
      for (final request in discoveries) {
        if (!request.canConfigure) {
          throw FormatException('${request.segmentCode} 的材料申请已变化，请返回刷新后重新选择');
        }
        if (request.suggestedItems.isEmpty) {
          throw FormatException('${request.segmentCode} 尚未确定材料，请先打开该申请填写材料');
        }
      }
      await names.loadGoodsDetails({
        for (final document in documents)
          for (final item in document.items)
            if (item.goodsId != null) item.goodsId!,
        for (final request in discoveries)
          for (final item in request.suggestedItems)
            if (item['goodsId'] != null) item['goodsId'] as String,
      });
      if (mounted) {
        setState(() {
          _documents = documents;
          _rebuildIssueWeights(documents);
          _discoveries = discoveries;
          for (final row in _discoveryRows) {
            row.dispose();
          }
          _discoveryRows.clear();
          for (final request in discoveries) {
            for (
              var index = 0;
              index < request.suggestedItems.length;
              index++
            ) {
              _discoveryRows.add(
                ProductionDrawDiscoveryRow(
                  request: request,
                  index: _nextDiscoveryRow++,
                  initial: request.suggestedItems[index],
                ),
              );
            }
          }
        });
      }
    } on ApiException catch (error) {
      if (mounted) setState(() => _error = error.message);
    } on FormatException catch (error) {
      if (mounted) setState(() => _error = error.message);
    } catch (_) {
      if (mounted) setState(() => _error = '领料详情加载失败，请重试');
    } finally {
      if (mounted) {
        setState(() => _loading = false);
        _ensureWeightParams();
        await initializeFormDraft();
      }
    }
  }

  String? _blocked(Set<String> permissions) {
    if (_documents == null || (_documents!.isEmpty && _discoveryRows.isEmpty)) {
      return '请先加载领料明细';
    }
    final admin = ref.read(isSuperAdminProvider);
    if (!admin && !permissions.contains(Perm.stockDocIssue)) {
      return '当前账号没有出库权限';
    }
    if (_documents!.any((document) => document.status == -1)) {
      return '所选单据已红冲，请返回刷新后重新选择';
    }
    if ((_documents!.any((document) => document.status == 0) ||
            _discoveryRows.isNotEmpty) &&
        !admin &&
        !permissions.contains(Perm.stockDocApprove)) {
      return '草稿单出库即审核，当前账号还需要审核权限';
    }
    if (_discoveryRows.isEmpty &&
        !_documents!.any(
          (document) => document.items.any((item) => item.remainingQty > 0),
        )) {
      return '所选领料单均已出完，请返回任务中心刷新';
    }
    return null;
  }

  Future<void> _pickDiscoveryWarehouse(ProductionDrawDiscoveryRow row) async {
    if (_saving ||
        _uncertain ||
        _blocked(ref.read(currentPermissionsProvider)) != null) {
      return;
    }
    try {
      final names = ref.read(masterNameServiceProvider);
      await names.ensureWarehousesLoaded();
      if (!mounted || _saving || _uncertain || !_discoveryRows.contains(row)) {
        return;
      }
      final selected = await showUtenWarehousePickerPanel(
        context,
        hierarchy: names.warehouseHierarchy,
        initialWarehouseId: row.values['warehouseId'] as String?,
        title: '选择实际发料仓',
      );
      if (!mounted ||
          selected == null ||
          _saving ||
          _uncertain ||
          !_discoveryRows.contains(row) ||
          _blocked(ref.read(currentPermissionsProvider)) != null) {
        return;
      }
      setState(
        () => row.values.addAll({
          'warehouseId': selected.id,
          'warehouseName': selected.label,
        }),
      );
    } catch (error) {
      if (mounted) context.appApiError(error);
    }
  }

  bool _sameMaterial(
    ProductionDrawDiscoveryRow a,
    ProductionDrawDiscoveryRow b,
  ) =>
      a.request.requestId == b.request.requestId &&
      a.values['goodsId'] == b.values['goodsId'] &&
      a.values['colorId'] == b.values['colorId'] &&
      a.values['unitId'] == b.values['unitId'];

  bool _canRemoveDiscoveryRow(ProductionDrawDiscoveryRow row) =>
      _discoveryRows.where((other) => _sameMaterial(row, other)).length > 1;

  void _splitDiscoveryRow(ProductionDrawDiscoveryRow row) {
    if (_saving ||
        _uncertain ||
        _blocked(ref.read(currentPermissionsProvider)) != null) {
      return;
    }
    if (_discoveryRows
            .where((other) => other.request.requestId == row.request.requestId)
            .length >=
        100) {
      context.appWarning('每个申请最多填写 100 行分仓材料');
      return;
    }
    final initial = Map<String, dynamic>.from(row.values)
      ..remove('qty')
      ..remove('warehouseId')
      ..remove('warehouseName');
    setState(
      () => _discoveryRows.insert(
        _discoveryRows.indexOf(row) + 1,
        ProductionDrawDiscoveryRow(
          request: row.request,
          index: _nextDiscoveryRow++,
          initial: initial,
        ),
      ),
    );
  }

  void _removeDiscoveryRow(ProductionDrawDiscoveryRow row) {
    if (_saving ||
        _uncertain ||
        !_canRemoveDiscoveryRow(row) ||
        _blocked(ref.read(currentPermissionsProvider)) != null) {
      return;
    }
    setState(() {
      _discoveryRows.remove(row);
      row.dispose();
    });
  }

  Future<void> _submit() async {
    if (_saving || _blocked(ref.read(currentPermissionsProvider)) != null) {
      return;
    }
    if (!_uncertain) {
      for (final document in _documents!) {
        for (final item in document.items) {
          if (_issueWeights[item.id]?.weight.hasError == true) {
            setState(() {
              _showValidation = true;
              _submitError =
                  '${document.billNo ?? ''} · ${ref.read(masterNameServiceProvider).goods(item.goodsId)}：本次重量看不懂，请改成如 12.5 或 850g';
            });
            return;
          }
        }
      }
      final identities = <String>{};
      for (final row in _discoveryRows) {
        if (row.validationError != null) {
          setState(() {
            _showValidation = true;
            _submitError =
                '${row.request.segmentCode} · ${row.label('goodsName')}：${row.validationError}';
          });
          return;
        }
        if (!identities.add(
          jsonEncode([
            row.request.requestId,
            row.values['goodsId'],
            row.values['colorId'],
            row.values['unitId'],
            row.values['warehouseId'],
          ]),
        )) {
          setState(() {
            _showValidation = true;
            _submitError =
                '${row.request.segmentCode} · ${row.label('goodsName')}：同材料同仓重复，请合并数量或选择其他实际仓';
          });
          return;
        }
      }
      _submittedDocIds = _documents!.map((document) => document.id).toList()
        ..sort();
      _submittedReason = _remark.text.trim().isEmpty
          ? null
          : _remark.text.trim();
      _submittedDiscoveries = [
        for (final request in _discoveries)
          _discoveryJson(
            request,
            _discoveryRows
                .where((row) => row.request.requestId == request.requestId)
                .toList(),
          ),
      ];
      // 现有领料单逐行本次重量 (只含称了的行)。
      _submittedWeights = [
        for (final document in _documents!)
          for (final item in document.items)
            if (_issueWeights[item.id] case final entry? when entry.kg != null)
              {
                'itemId': item.id,
                'weightKg': entry.kg,
                'qtyFromWeight': entry.qtyFromWeight,
              },
      ];
      // 重量进指纹: 改了重量就是另一笔请求 (服务端哈希同样含重量), 换新幂等键。
      final fingerprint = jsonEncode([
        _submittedDocIds,
        _submittedDiscoveries,
        _submittedWeights,
        _submittedReason,
      ]);
      if (_requestFingerprint != fingerprint) {
        _requestFingerprint = fingerprint;
        _requestKey = const Uuid().v4();
      }
    }
    setState(() {
      _saving = true;
      _submitError = null;
    });
    try {
      _submissionPending = true;
      await saveFormDraftNow();
      final repository = ref.read(productionDrawTaskRepositoryProvider);
      final result = _submittedDiscoveries.isEmpty
          ? await repository.issueFullBatch(
              idempotencyKey: _requestKey!,
              docIds: _submittedDocIds,
              weights: _submittedWeights,
              reason: _submittedReason,
            )
          : await repository.issueDiscoveryBatch(
              idempotencyKey: _requestKey!,
              docIds: _submittedDocIds,
              discoveries: _submittedDiscoveries,
              weights: _submittedWeights,
              reason: _submittedReason,
            );
      await completeFormDraft();
      if (!mounted) return;
      if (result.replayed) {
        context.appInfo('本批此前已完成(${result.replayedCount} 张领料单)，未重复出库');
      } else {
        context.appSuccess(
          result.skippedCount > 0
              ? '已出库 ${result.issuedCount} 张领料单(${result.skippedCount} 张已出完自动跳过)'
              : '已出库 ${result.issuedCount} 张领料单',
        );
      }
      invalidateWarehouseTaskCounts(ref);
      bumpListRefresh(ref, StockDocType.draw.refreshKey);
      if (context.canPop()) {
        context.pop(true);
      } else {
        popOrBackTo(context, defaultPath: RouteName.warehouseDrawTasks);
      }
    } on ApiException catch (error) {
      if (mounted) {
        final rejected =
            error.httpStatus != null &&
            error.httpStatus! >= 400 &&
            error.httpStatus! < 500;
        setState(() => _uncertain = !rejected);
        context.appError(
          error.fieldErrors?.firstOrNull?.message ?? error.message,
        );
      }
    } catch (_) {
      if (mounted) {
        setState(() => _uncertain = true);
        context.appError('批量出库结果待确认，请原样重试；已填写的信息已保留');
      }
    } finally {
      _submissionPending = false;
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final permissions = ref.watch(currentPermissionsProvider);
    final superAdmin = ref.watch(isSuperAdminProvider);
    final blocked = _blocked(permissions);
    final documents = _documents;
    final weightUnits = ref.watch(warehouseWeightUnitsPrefsProvider);
    // 有带货品的称重行时才盯住页内单重参数缓存 (离开页面随之释放)。
    _weightCache = _weightEntries.any((entry) => entry.paramsLine != null)
        ? ref.watch(weightParamsCacheProvider)
        : null;
    return withFormDraft(
      PopScope(
        canPop: !_saving && !_uncertain,
        child: Scaffold(
          appBar: UtenAppBar(
            title: '批量出库详情',
            leading: UtenBackButton(
              onPressed: _saving || _uncertain
                  ? null
                  : () => popOrBackTo(
                      context,
                      defaultPath: RouteName.warehouseDrawTasks,
                    ),
            ),
          ),
          body: SafeArea(
            child: UtenContentContainer.wide(
              child: _loading
                  ? const Center(child: CircularProgressIndicator())
                  : _error != null || documents == null
                  ? UtenEmpty.error(
                      message: _error ?? '没有可出库明细',
                      actionLabel: '重新加载',
                      onAction: _load,
                    )
                  : Stack(
                      children: [
                        AbsorbPointer(
                          absorbing: _saving || _uncertain,
                          child: UtenCollapsingHeaderScrollView(
                            collapsingHeader: Padding(
                              padding: const EdgeInsets.all(UtenSpacing.s12),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.stretch,
                                children: [
                                  Text(
                                    '共 ${documents.length} 张领料单${_discoveries.isEmpty ? '' : ' · ${_discoveries.length} 个材料申请'} · ${documents.fold<int>(0, (sum, document) => sum + document.items.length) + _discoveryRows.length} 行明细',
                                    style: Theme.of(
                                      context,
                                    ).textTheme.titleMedium,
                                  ),
                                  const SizedBox(height: UtenSpacing.s8),
                                  Text(
                                    _discoveries.isEmpty
                                        ? '请核对每行仓库、车间和待出库数量。确认后按各单当前剩余量全部出库；需要部分出库时，请返回逐单办理。'
                                        : '请在表格红框内补齐材料申请的领料数量和实际发料仓。确认后一起生成领料单并出库；现有领料单仍按各单剩余量全部出库。',
                                    style: Theme.of(
                                      context,
                                    ).textTheme.bodySmall,
                                  ),
                                  const SizedBox(height: UtenSpacing.s12),
                                  if (_submitError != null)
                                    Text(
                                      _submitError!,
                                      key: const Key(
                                        'draw-batch-validation-error',
                                      ),
                                      style: TextStyle(
                                        color: Theme.of(
                                          context,
                                        ).colorScheme.error,
                                      ),
                                    ),
                                  if (_uncertain)
                                    const Text('出库结果待确认，当前信息已锁定，请原样重试以核对结果。'),
                                  TextField(
                                    key: const Key(
                                      'warehouse-draw-batch-remark',
                                    ),
                                    controller: _remark,
                                    readOnly: _saving || _uncertain,
                                    maxLength: 200,
                                    decoration: const UtenInputDecoration(
                                      InputDecoration(
                                        labelText: '统一备注(选填)',
                                        counterText: '',
                                      ),
                                      info: '备注会追加到本批每张领料单，可填写交接情况，最多 200 字。',
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            body: Padding(
                              padding: const EdgeInsets.all(UtenSpacing.s12),
                              child: ProductionDrawDetailTable(
                                documents: documents,
                                names: ref.watch(masterNameServiceProvider),
                                permissions: permissions,
                                superAdmin: superAdmin,
                                primary: true,
                                discoveryRows: _discoveryRows,
                                issueWeights: _issueWeights,
                                weightParams: _weightCache,
                                weightEntryUnit: weightUnits.entry,
                                onPickDiscoveryWarehouse:
                                    _pickDiscoveryWarehouse,
                                onSplitDiscoveryRow: _splitDiscoveryRow,
                                onRemoveDiscoveryRow: _removeDiscoveryRow,
                                canRemoveDiscoveryRow: _canRemoveDiscoveryRow,
                                showDiscoveryValidation: _showValidation,
                                issueSaving:
                                    _saving || _uncertain || blocked != null,
                              ),
                            ),
                          ),
                        ),
                        // 批量出库事务期间的全屏加载遮罩。
                        if (_saving)
                          const UtenBusyOverlay(
                            title: '正在批量出库',
                            description: '正在确认领料并完成整批出库，请勿重复提交或离开本页。',
                          ),
                      ],
                    ),
            ),
          ),
          floatingActionButtonLocation: FloatingActionButtonLocation.endFloat,
          floatingActionButtonAnimator:
              FloatingActionButtonAnimator.noAnimation,
          floatingActionButton: _loading || documents == null
              ? null
              : UtenFloatingActionGroup(
                  children: [
                    UtenButton(
                      type: UtenButtonType.secondary,
                      size: UtenButtonSize.large,
                      onPressed: _saving || _uncertain
                          ? null
                          : () => popOrBackTo(
                              context,
                              defaultPath: RouteName.warehouseDrawTasks,
                            ),
                      child: const Text('取消'),
                    ),
                    if (superAdmin || permissions.contains(Perm.stockDocIssue))
                      UtenButton(
                        key: const Key('warehouse-draw-batch-confirm'),
                        type: UtenButtonType.danger,
                        size: UtenButtonSize.large,
                        icon: Icons.outbound_outlined,
                        isLoading: _saving,
                        onPressed: blocked != null || _saving ? null : _submit,
                        onDisabledTap: () =>
                            context.appWarning(blocked ?? '正在出库，请稍候'),
                        child: Text(
                          _uncertain
                              ? '原样重试批量出库'
                              : '确认批量出库(${documents.length + _discoveries.length})',
                        ),
                      ),
                  ],
                ),
        ),
      ),
    );
  }
}
