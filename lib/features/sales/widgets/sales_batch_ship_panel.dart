// 批量发货面板（SOP §一9，订单列表「批量发货」用）。
//
// 右滑入大面板（840，与 showSalesDocLinkPicker 统一；手机降级底部弹层）：
// 每次有界浏览100行，选择和原始数量/重量独立保留；全选由同谓词服务端快照确认≤500完整候选
// → POST /sales/shipments/batch 同客户合并一张出货草稿。
// 返回生成的出货单张数（null=取消）。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../../../components/buttons/uten_button.dart';
import '../../../components/feedback/uten_busy_overlay.dart';
import '../../../components/inputs/uten_input_decoration.dart';
import '../../../components/layout/uten_adaptive_panel.dart';
import '../../../components/layout/uten_paged_picker_list.dart';
import '../../../components/layout/uten_picker_footer_layout.dart';
import '../../../components/inputs/uten_search_bar.dart';
import '../../../core/network/authenticated_request_scope.dart';
import '../../../shared/auth/permissions.dart';
import '../../../shared/models/paged_result.dart';
import '../../../shared/paging/scoped_paged_read_view_mixin.dart';
import '../../../shared/providers/export_context_epoch_provider.dart';
import '../../basic_data/widgets/uten_client_picker.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../core/ui/action_feedback.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/utils/china_datetime.dart';
import '../models/sales_doc.dart';
import '../providers/master_name_provider.dart';
import '../repositories/sales_repository.dart';
import '../config/sales_doc_config.dart';
import '../../../shared/providers/list_refresh_provider.dart';
import '../../../shared/badges/badge_registry.dart';

/// 弹出批量发货面板；返回生成的出货单张数（null 表示取消）。
Future<int?> showSalesBatchShipPanel(BuildContext context, WidgetRef ref) {
  const sheet = _BatchShipSheet();
  return showUtenAdaptivePanel<int>(
    context: context,
    compactHeightFactor: 0.9,
    drawerWidth: 840,
    builder: (_) => sheet,
  );
}

class _BatchShipSheet extends ConsumerStatefulWidget {
  const _BatchShipSheet();

  @override
  ConsumerState<_BatchShipSheet> createState() => _BatchShipSheetState();
}

class _BatchShipSheetState extends ConsumerState<_BatchShipSheet>
    with ScopedPagedReadViewMixin<_BatchShipSheet> {
  static const _maxSelection = 500;
  PagedResult<ShippableLine>? _page;
  final _rows = MasterDataTableRowsController<ShippableLine>();
  String? _error;
  String? _actionError;
  final Set<String> _selected = {};
  final Map<String, ShippableLine> _selectedLines = {};
  // Only user-entered strings persist outside the bounded visible page window;
  // text controllers belong to mounted input widgets, not every browsed row.
  final Map<String, String> _qtyRaw = {};
  final Map<String, String> _weightRaw = {};
  final _search = TextEditingController();
  String _keyword = '';
  String? _clientId;
  String? _clientLabel;
  bool _queryDirty = false;
  bool _allSelected = false;
  bool _loading = false;
  bool _selecting = false;
  int _readGeneration = 0;
  int _selectionGeneration = 0;
  late final int _readerEpoch;
  bool _readerRetired = false;
  String _idempotencyKey = const Uuid().v4();
  List<Map<String, dynamic>>? _retainedLines;
  String? _retainedDate;
  bool _busy = false;

  bool get _currentReader =>
      mounted &&
      !_readerRetired &&
      _readerEpoch == ref.read(exportContextEpochProvider);
  bool get _hasCreate =>
      ref.read(isSuperAdminProvider) ||
      ref.read(currentPermissionsProvider).contains(Perm.salesShipmentCreate);
  bool get _canEditSelection =>
      _currentReader &&
      _hasCreate &&
      !_busy &&
      !_selecting &&
      _retainedLines == null;

  @override
  void initState() {
    super.initState();
    _readerEpoch = ref.read(exportContextEpochProvider);
    ref.listenManual(exportContextEpochProvider, (previous, next) {
      if (!mounted || previous == next) return;
      _retireReader();
    });
    _load();
  }

  void _retireReader() {
    if (!mounted) return;
    setState(() {
      _readerRetired = true;
      ++_readGeneration;
      ++_selectionGeneration;
      _page = null;
      _selected.clear();
      _selectedLines.clear();
      _qtyRaw.clear();
      _weightRaw.clear();
      _search.clear();
      _loading = false;
      _selecting = false;
      _busy = false;
    });
  }

  @override
  void dispose() {
    ++_readGeneration;
    ++_selectionGeneration;
    _search.dispose();
    super.dispose();
  }

  static String _num(double? v) {
    if (v == null) return '—';
    return v.toStringAsFixed(4).replaceFirst(RegExp(r'\.?0+$'), '');
  }

  @override
  void scopedPagedReadOwnerChanged() => _retireReader();

  Future<void> _load([int targetPage = 1, bool useCache = false]) async {
    if (!_currentReader || _retainedLines != null || _busy) return;
    final generation = ++_readGeneration;
    bool current() => _currentReader && generation == _readGeneration;
    final keyword = _keyword;
    final clientId = _clientId;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final names = ref.read(salesMasterNameServiceProvider);
      final repository = ref.read(salesRepositoryProvider(SalesDocType.order));
      final scope = await repository.api.captureRequestScope(
        isCurrent: current,
      );
      await scope.run(names.ensureLoaded);
      if (!current()) return;
      bool queryCurrent() =>
          _currentReader &&
          !_queryDirty &&
          _keyword == keyword &&
          _clientId == clientId;
      final page = await readScopedPage<ShippableLine>(
        targetPage,
        query: [repository, keyword, clientId],
        currentQuery: () => [
          ref.read(salesRepositoryProvider(SalesDocType.order)),
          _keyword,
          _clientId,
        ],
        isCurrent: queryCurrent,
        useCache: useCache,
        fetchPage: (target) async {
          final request = await repository.api.captureRequestScope(
            isCurrent: queryCurrent,
          );
          return request.run(
            () => repository.shippableLinesPage(
              page: target,
              keyword: keyword,
              clientId: clientId,
            ),
          );
        },
      );
      if (!current()) return;
      await scope.run(
        () => Future.wait([
          names.loadGoodsNames(
            page.items.map((line) => line.goodsId).whereType<String>().toSet(),
          ),
          names.loadClientNames(
            page.items.map((line) => line.clientId).whereType<String>().toSet(),
          ),
        ]),
      );
      await scope.verify();
      if (!current()) return;
      setState(() {
        _page = page;
        _loading = false;
        for (final line in page.items) {
          if (!_selected.contains(line.orderItemId)) continue;
          if (!line.writable) {
            _selected.remove(line.orderItemId);
            _selectedLines.remove(line.orderItemId);
            _allSelected = false;
          } else {
            _selectedLines[line.orderItemId] = line;
          }
        }
      });
    } catch (error) {
      if (!current()) return;
      if (error is ApiException &&
          ({401, 403}.contains(error.httpStatus) ||
              isSessionBoundaryError(error))) {
        _retireReader();
        return;
      }
      setState(() {
        _loading = false;
        _error = '可发订单行加载失败，请重试';
      });
      if (mounted) context.appApiError(error, fallback: '可发订单行加载失败，请稍后重试');
    }
  }

  void _queryInput(String value) {
    if (!_currentReader || _retainedLines != null) return;
    if (value.trim() == _keyword) return;
    setState(() {
      _queryDirty = true;
      _allSelected = false;
      ++_readGeneration;
      ++_selectionGeneration;
      _loading = false;
      _selecting = false;
    });
  }

  void _searchChanged(String value) {
    if (!_currentReader || _retainedLines != null || _busy) return;
    setState(() {
      _keyword = value.trim();
      _queryDirty = false;
      _allSelected = false;
      ++_selectionGeneration;
      _selecting = false;
    });
    _load();
  }

  Future<void> _pickClient() async {
    if (!_canEditSelection) return;
    final client = await showUtenClientPicker(context, ref);
    if (!_currentReader || client == null) return;
    setState(() {
      _clientId = client.id;
      _clientLabel = client.name;
      _allSelected = false;
      ++_selectionGeneration;
      _selecting = false;
    });
    _load();
  }

  void _toggleLine(ShippableLine line, bool check) {
    if (!_canEditSelection || !line.writable) return;
    if (check &&
        !_selected.contains(line.orderItemId) &&
        _selected.length >= _maxSelection) {
      _toast('单批最多500行，请减少已选产品后再选择');
      return;
    }
    setState(() {
      _allSelected = false;
      _actionError = null;
      if (check) {
        _selected.add(line.orderItemId);
        _selectedLines[line.orderItemId] = line;
      } else {
        _selected.remove(line.orderItemId);
        _selectedLines.remove(line.orderItemId);
      }
    });
  }

  Future<void> _toggleAll(bool check) async {
    if (!_canEditSelection || _queryDirty) return;
    if (!check) {
      setState(() {
        _selected.clear();
        _selectedLines.clear();
        _allSelected = false;
      });
      return;
    }
    final generation = ++_selectionGeneration;
    bool current() => _currentReader && generation == _selectionGeneration;
    final keyword = _keyword;
    final clientId = _clientId;
    setState(() => _selecting = true);
    try {
      final repository = ref.read(salesRepositoryProvider(SalesDocType.order));
      final scope = await repository.api.captureRequestScope(
        isCurrent: current,
      );
      final snapshot = await scope.run(
        () => repository.shippableLinesSelection(
          keyword: keyword,
          clientId: clientId,
        ),
      );
      await scope.verify();
      if (!current()) return;
      final ids = snapshot.items.map((line) => line.orderItemId).toSet();
      if (snapshot.total > _maxSelection ||
          snapshot.items.length != snapshot.total ||
          ids.length != snapshot.total ||
          snapshot.items.any((line) => !line.writable)) {
        throw const FormatException('全选快照不完整，请收窄范围后重试');
      }
      setState(() {
        _selected
          ..clear()
          ..addAll(ids);
        _selectedLines
          ..clear()
          ..addEntries(
            snapshot.items.map((line) => MapEntry(line.orderItemId, line)),
          );
        _allSelected = ids.isNotEmpty;
      });
    } catch (error) {
      if (!current()) return;
      if (error is ApiException &&
          ({401, 403}.contains(error.httpStatus) ||
              isSessionBoundaryError(error))) {
        _retireReader();
        return;
      }
      if (mounted) {
        setState(() {
          _actionError = error is ApiException
              ? error.message
              : '无法确认全部可操作行，请收窄范围后重试';
        });
        context.appApiError(error, fallback: '无法确认全部可操作行，请收窄范围后重试');
      }
    } finally {
      if (current()) setState(() => _selecting = false);
    }
  }

  Future<void> _confirm() async {
    if (!_currentReader ||
        !_hasCreate ||
        _busy ||
        _selecting ||
        _selected.isEmpty) {
      return;
    }
    if (_retainedLines == null) {
      final lines = <Map<String, dynamic>>[];
      for (final id in _selected) {
        final line = _selectedLines[id];
        if (line == null || !line.writable) {
          _toast('已选订单已不可操作，请刷新核对');
          return;
        }
        final raw = (_qtyRaw[id] ?? _num(line.reservedQty)).trim();
        final qty = double.tryParse(raw);
        final reserved = line.reservedQty ?? 0;
        if (qty == null ||
            !qty.isFinite ||
            qty <= 0 ||
            !RegExp(r'^\d+(\.\d{1,4})?$').hasMatch(raw)) {
          _toast('订单 ${line.billNo} 的本次数量要大于 0');
          return;
        }
        if (qty > reserved) {
          _toast('订单 ${line.billNo} 本次数量超过可发 ${_num(reserved)}');
          return;
        }
        final weightText = (_weightRaw[id] ?? '').trim();
        final weight = weightText.isEmpty ? null : double.tryParse(weightText);
        if (weightText.isNotEmpty &&
            (weight == null || !weight.isFinite || weight <= 0)) {
          _toast('订单 ${line.billNo} 的实际重量要大于 0');
          return;
        }
        lines.add({'orderItemId': id, 'qty': qty, 'weight': ?weight});
      }
      _retainedLines = lines;
      _retainedDate = ChinaDateTime.formatDate(ChinaDateTime.today());
    }
    FocusManager.instance.primaryFocus?.unfocus();
    setState(() => _busy = true);
    try {
      final repository = ref.read(
        salesRepositoryProvider(SalesDocType.shipment),
      );
      final scope = await repository.api.captureRequestScope(
        isCurrent: () => _currentReader,
      );
      final created = await scope.run(
        () => repository.batchShip(
          billDate: _retainedDate!,
          idempotencyKey: _idempotencyKey,
          lines: _retainedLines!,
        ),
      );
      await scope.verify();
      if (!_currentReader) return;
      if (created.isEmpty) throw const FormatException('没有收到开单结果，请重试确认');
      refreshBadges(ref);
      bumpListRefresh(ref, SalesDocConfig.shipment.refreshKey);
      bumpListRefresh(ref, SalesDocConfig.order.refreshKey);
      if (mounted) Navigator.pop(context, created.length);
    } on ApiException catch (error) {
      if (!_currentReader) return;
      final uncertain =
          error is NetworkException ||
          error is NetworkTimeoutException ||
          isSessionBoundaryError(error) ||
          error.httpStatus == null ||
          error.httpStatus! >= 500;
      if (!uncertain) {
        _retainedLines = null;
        _retainedDate = null;
        _idempotencyKey = const Uuid().v4();
      }
      _toast(uncertain ? '请重试确认本次开单结果，当前产品和数量已保留。' : error.message);
    } catch (_) {
      if (_currentReader) _toast('请重试确认本次开单结果，当前产品和数量已保留。');
    } finally {
      if (_currentReader) setState(() => _busy = false);
    }
  }

  void _toast(String message) {
    if (!_currentReader) return;
    setState(() => _actionError = message);
    context.appWarning(message);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final names = ref.watch(salesMasterNameServiceProvider);
    if (_readerRetired) {
      return Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Padding(
            padding: EdgeInsets.all(UtenSpacing.s16),
            child: Text('账号、权限或服务器已变化，请关闭并重新打开；已发出的开单结果需在原账号核查。'),
          ),
          UtenButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('关闭'),
          ),
        ],
      );
    }
    final page = _page;
    final canChangeQuery = !_busy && _retainedLines == null;
    return PopScope(
      canPop: !_busy && _retainedLines == null,
      child: Column(
        children: [
          if (_busy)
            const UtenBusyOverlay(
              title: '正在批量开出货单',
              description: '正在按订单逐张生成出货单，请勿重复提交或关闭面板。',
            ),
          Padding(
            padding: const EdgeInsets.all(UtenSpacing.s12),
            child: Row(
              children: [
                Icon(
                  Icons.local_shipping_outlined,
                  size: 20,
                  color: theme.colorScheme.primary,
                ),
                const SizedBox(width: UtenSpacing.s8),
                Text(
                  '批量发货',
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(width: UtenSpacing.s8),
                if (page != null)
                  Flexible(
                    child: Text(
                      '共 ${page.total} 行 · 已选 ${_selected.length} 行',
                      style: theme.textTheme.bodySmall,
                    ),
                  ),
                const Spacer(),
                IconButton(
                  onPressed: canChangeQuery
                      ? () => Navigator.pop(context)
                      : null,
                  icon: const Icon(Icons.close),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: UtenSpacing.s12),
            child: Column(
              children: [
                FocusScope(
                  canRequestFocus: canChangeQuery,
                  child: AbsorbPointer(
                    absorbing: !canChangeQuery,
                    child: UtenSearchBar(
                      key: const Key('sales-batch-search'),
                      controller: _search,
                      hint: '搜索订单号、客户或货品',
                      onInputChanged: _queryInput,
                      onChanged: _searchChanged,
                    ),
                  ),
                ),
                const SizedBox(height: UtenSpacing.s8),
                Row(
                  children: [
                    UtenButton(
                      type: UtenButtonType.tonal,
                      size: UtenButtonSize.small,
                      onPressed: canChangeQuery ? _pickClient : null,
                      child: Text(_clientLabel ?? '选择客户'),
                    ),
                    if (_clientId != null)
                      IconButton(
                        tooltip: '清除客户',
                        onPressed: canChangeQuery
                            ? () {
                                setState(() {
                                  _clientId = null;
                                  _clientLabel = null;
                                  _allSelected = false;
                                  ++_selectionGeneration;
                                  _selecting = false;
                                });
                                _load();
                              }
                            : null,
                        icon: const Icon(Icons.close),
                      ),
                    const SizedBox(width: UtenSpacing.s8),
                    const Expanded(child: Text('每页100行，已选产品和输入跨页保留；单批最多500行。')),
                  ],
                ),
              ],
            ),
          ),
          if (_selecting) const LinearProgressIndicator(),
          const Divider(height: 1),
          Expanded(
            child: UtenPagedPickerList<ShippableLine>(
              key: const Key('sales-batch-lines'),
              items: page?.items ?? const [],
              idOf: (line) => line.orderItemId,
              itemBuilder: (_, line) => _row(theme, names, line),
              currentPage: page?.page ?? 1,
              totalPages: page?.totalPages ?? 0,
              onPageChange: (target) {
                if (canChangeQuery && !_selecting && !_queryDirty) {
                  return _load(target, true);
                }
              },
              paginationScope: (_keyword, _clientId, _readerEpoch),
              rowsController: _rows,
              showPaginationControls: false,
              loading: _loading,
              error: _error,
              onRetry: () => _load(page?.page ?? 1),
              emptyMessage: '暂无可发货的订单行（有可发数量的订单行才会显示在这里）',
              padding: const EdgeInsets.all(UtenSpacing.s8),
              separatorBuilder: (_, _) => const Divider(height: 1),
            ),
          ),
          const Divider(height: 1),
          if (_actionError != null)
            Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: UtenSpacing.s12,
                vertical: UtenSpacing.s8,
              ),
              child: Text(
                _actionError!,
                style: TextStyle(color: theme.colorScheme.error),
              ),
            ),
          Padding(
            padding: const EdgeInsets.all(UtenSpacing.s12),
            child: UtenPickerFooterLayout(
              summary: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Checkbox(
                    key: const Key('sales-batch-select-all'),
                    tristate: true,
                    value: _allSelected
                        ? true
                        : _selected.isEmpty
                        ? false
                        : null,
                    onChanged:
                        _canEditSelection &&
                            !_queryDirty &&
                            (page?.total ?? 0) > 0
                        ? (_) => _toggleAll(!_allSelected)
                        : null,
                  ),
                  const Text('全选'),
                  if (_selected.isNotEmpty)
                    TextButton(
                      onPressed: _canEditSelection
                          ? () => _toggleAll(false)
                          : null,
                      child: const Text('清空已选'),
                    ),
                ],
              ),
              pagination: UtenPickerPageControls(controller: _rows),
              actions: UtenButton(
                key: const Key('sales-batch-confirm'),
                icon: Icons.check_circle_outline,
                onPressed:
                    _selected.isEmpty || _busy || _selecting || !_hasCreate
                    ? null
                    : _confirm,
                child: Text(
                  _busy
                      ? '开单中…'
                      : _retainedLines != null
                      ? '重试确认开单'
                      : '生成出货单(${_selected.length} 行)',
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _row(ThemeData theme, SalesMasterNameService names, ShippableLine l) {
    final checked = _selected.contains(l.orderItemId);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 4),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final compact = constraints.maxWidth < 620;
          final checkbox = Checkbox(
            key: ValueKey('sales-batch-select-${l.orderItemId}'),
            value: checked,
            onChanged: l.writable && _canEditSelection
                ? (value) => _toggleLine(l, value ?? false)
                : null,
          );
          if (compact) {
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    checkbox,
                    Expanded(
                      child: Text(
                        '${names.client(l.clientId)} · ${l.billNo ?? ''}',
                      ),
                    ),
                  ],
                ),
                Text(
                  '${names.goods(l.goodsId)} · 可发 ${_num(l.reservedQty)}${l.writable ? '' : ' · 只读'}',
                ),
                const SizedBox(height: UtenSpacing.s8),
                Wrap(
                  spacing: UtenSpacing.s8,
                  runSpacing: UtenSpacing.s8,
                  children: [
                    SizedBox(
                      width: 120,
                      child: _BatchShipNumberField(
                        key: ValueKey('sales-batch-qty-${l.orderItemId}'),
                        value: _qtyRaw[l.orderItemId] ?? _num(l.reservedQty),
                        onChanged: (value) => _qtyRaw[l.orderItemId] = value,
                        enabled: checked && l.writable && _canEditSelection,
                        style: theme.textTheme.bodySmall,
                        keyboardType: const TextInputType.numberWithOptions(
                          decimal: true,
                        ),
                        decoration: const UtenInputDecoration(
                          InputDecoration(labelText: '本次数量', isDense: true),
                        ),
                      ),
                    ),
                    SizedBox(
                      width: 120,
                      child: _BatchShipNumberField(
                        key: ValueKey('sales-batch-weight-${l.orderItemId}'),
                        value: _weightRaw[l.orderItemId] ?? '',
                        onChanged: (value) => _weightRaw[l.orderItemId] = value,
                        enabled: checked && l.writable && _canEditSelection,
                        style: theme.textTheme.bodySmall,
                        keyboardType: const TextInputType.numberWithOptions(
                          decimal: true,
                        ),
                        decoration: const UtenInputDecoration(
                          InputDecoration(
                            labelText: '实际重量',
                            hintText: '可选',
                            isDense: true,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            );
          }
          return Row(
            children: [
              Checkbox(
                key: ValueKey('sales-batch-select-${l.orderItemId}'),
                value: checked,
                onChanged: l.writable && _canEditSelection
                    ? (v) => _toggleLine(l, v ?? false)
                    : null,
              ),
              Expanded(
                flex: 3,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      names.client(l.clientId),
                      style: theme.textTheme.titleSmall,
                    ),
                    Text(
                      '${l.billNo ?? ''} · 交货 ${l.deliverDate ?? '—'}'
                      '${l.writable ? '' : ' · 只读'}',
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: l.writable
                            ? theme.colorScheme.onSurfaceVariant
                            : theme.colorScheme.error,
                      ),
                    ),
                  ],
                ),
              ),
              Expanded(
                flex: 3,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      names.goods(l.goodsId),
                      style: theme.textTheme.bodySmall,
                    ),
                    Text(
                      [
                        names.color(l.colorId),
                        names.unit(l.unitId),
                      ].where((e) => e.isNotEmpty).join(' · '),
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              Expanded(
                child: Text(
                  '可发 ${_num(l.reservedQty)}',
                  style: theme.textTheme.labelMedium?.copyWith(
                    fontWeight: FontWeight.w400,
                  ),
                ),
              ),
              const SizedBox(width: UtenSpacing.s12),
              SizedBox(
                width: 90,
                child: _BatchShipNumberField(
                  key: ValueKey('sales-batch-qty-${l.orderItemId}'),
                  value: _qtyRaw[l.orderItemId] ?? _num(l.reservedQty),
                  onChanged: (value) => _qtyRaw[l.orderItemId] = value,
                  enabled: checked && l.writable && _canEditSelection,
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                  ),
                  style: theme.textTheme.bodySmall,
                  decoration: const UtenInputDecoration(
                    InputDecoration(
                      isDense: true,
                      labelText: '本次数量',
                      border: OutlineInputBorder(),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: UtenSpacing.s8),
              SizedBox(
                width: 104,
                child: _BatchShipNumberField(
                  key: ValueKey('sales-batch-weight-${l.orderItemId}'),
                  value: _weightRaw[l.orderItemId] ?? '',
                  onChanged: (value) => _weightRaw[l.orderItemId] = value,
                  enabled: checked && l.writable && _canEditSelection,
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                  ),
                  style: theme.textTheme.bodySmall,
                  decoration: const UtenInputDecoration(
                    InputDecoration(
                      isDense: true,
                      labelText: '实际重量',
                      hintText: '可选',
                      border: OutlineInputBorder(),
                    ),
                    info: '若同一产品将分成多张出货单，请先留空，生成后分别填写实际重量；系统不会猜测拆分比例。',
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

class _BatchShipNumberField extends StatefulWidget {
  const _BatchShipNumberField({
    super.key,
    required this.value,
    required this.onChanged,
    required this.enabled,
    this.keyboardType,
    this.style,
    this.decoration,
  });
  final String value;
  final ValueChanged<String> onChanged;
  final bool enabled;
  final TextInputType? keyboardType;
  final TextStyle? style;
  final InputDecoration? decoration;
  @override
  State<_BatchShipNumberField> createState() => _BatchShipNumberFieldState();
}

class _BatchShipNumberFieldState extends State<_BatchShipNumberField> {
  late final _controller = TextEditingController(text: widget.value);
  @override
  void didUpdateWidget(covariant _BatchShipNumberField oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.value != widget.value && _controller.text != widget.value) {
      _controller.text = widget.value;
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => TextField(
    controller: _controller,
    enabled: widget.enabled,
    keyboardType: widget.keyboardType,
    style: widget.style,
    decoration: widget.decoration,
    onChanged: widget.onChanged,
  );
}
