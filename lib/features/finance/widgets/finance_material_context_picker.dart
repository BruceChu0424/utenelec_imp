import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../components/feedback/uten_dialog.dart';
import '../../../components/feedback/uten_busy_overlay.dart';
import '../shared/finance_workbench_panel.dart';
import '../../../components/layout/uten_filter_toolbar.dart';
import '../../../core/network/api_client.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../shared/providers/export_context_epoch_provider.dart';
import 'finance_source_table.dart';

/// Selects an explicitly reviewed source identity; names never resolve an ID.
Future<Map<String, dynamic>?> showFinanceMaterialContextPicker(
  BuildContext context,
) => showFinanceWorkbenchPanel<Map<String, dynamic>>(
  context: context,
  builder: (_) => const _MaterialContextPicker(),
);

class _MaterialContextPicker extends ConsumerStatefulWidget {
  const _MaterialContextPicker();
  @override
  ConsumerState<_MaterialContextPicker> createState() =>
      _MaterialContextPickerState();
}

class _MaterialContextPickerState
    extends ConsumerState<_MaterialContextPicker> {
  late final ApiClient _api;
  late final int _epoch;
  final _search = TextEditingController();
  List<Map<String, dynamic>> _items = [];
  String _keyword = '';
  String? _error;
  bool _busy = false;
  int _page = 1, _pages = 0, _generation = 0;
  bool get _current =>
      mounted &&
      _epoch == ref.read(exportContextEpochProvider) &&
      identical(_api, ref.read(apiClientProvider));
  @override
  void initState() {
    super.initState();
    _api = ref.read(apiClientProvider);
    _epoch = ref.read(exportContextEpochProvider);
    _load(1);
  }

  @override
  void dispose() {
    _generation++;
    _search.dispose();
    super.dispose();
  }

  Future<void> _load(int page, {bool search = false}) async {
    if (!_current) return;
    if (search) _keyword = _search.text.trim();
    final generation = ++_generation, keyword = _keyword;
    setState(() {
      _busy = true;
      _error = null;
      _items = [];
      _page = page;
    });
    try {
      final result = await _api.get(
        '/finance/material-statements',
        query: {
          'page': page,
          'size': 50,
          if (keyword.isNotEmpty) 'keyword': keyword,
        },
      );
      if (!_current || generation != _generation || keyword != _keyword) return;
      setState(() {
        _items = [
          for (final row in result['items'] as List? ?? const <dynamic>[])
            if (row is Map) Map<String, dynamic>.from(row),
        ];
        _pages = (result['totalPages'] as num?)?.toInt() ?? 0;
      });
    } catch (error) {
      if (_current && generation == _generation) {
        setState(
          () => _error = error is ApiException ? error.message : '读取对账资料失败，请重试',
        );
      }
    } finally {
      if (_current && generation == _generation) setState(() => _busy = false);
    }
  }

  bool _selectable(Map<String, dynamic> row) =>
      !_busy &&
      row['state'] == 'APPROVED' &&
      [
        'id',
        'actualCurrencyId',
        'partyId',
        'partyRole',
      ].every((key) => row[key]?.toString().isNotEmpty == true);
  @override
  Widget build(BuildContext context) {
    ref.watch(exportContextEpochProvider);
    if (!_current) {
      return UtenAlertDialog(
        title: const Text('访问范围已变化'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('关闭'),
          ),
        ],
      );
    }
    return UtenDialogFrame(
      maxWidth: 1100,
      fillHeight: true,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          UtenDialogHeader(
            title: const UtenDialogTitleWithHint(
              title: Text('选择对账资料'),
              info: '选择已审核资料作为原表来源，生成同一范围的全部产品分组。资料审核不代替每笔原单、重量和加工款的核对。',
            ),
            showCloseButton: true,
            onClose: () => Navigator.pop(context),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: UtenSpacing.s16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                UtenFilterToolbar<String>(
                  searchController: _search,
                  searchHint: '往来或产品编号、名称',
                  onSearchSubmitted: (_) => _load(1, search: true),
                ),
              ],
            ),
          ),
          Expanded(
            child: financeSourceTable(
              tableKey: 'finance.material-context.picker.v1',
              columns: [
                financeSourceColumn('auxiliaryCode', '往来编号', width: 130),
                financeSourceColumn('auxiliaryName', '往来名称', width: 190),
                financeSourceColumn(
                  'productNameCaption',
                  '产品名称',
                  width: 220,
                  value: (row) =>
                      (row['productNameCaption'] ?? row['goodsName'])
                          ?.toString(),
                ),
                financeSourceColumn('accountCode', '科目编码', width: 120),
                financeSourceColumn(
                  'accountingCurrencyCode',
                  '账簿币别属性',
                  width: 130,
                ),
                financeSourceColumn('actualCurrencyCode', '原表实际币别', width: 130),
                financeSourceColumn(
                  'amountBasis',
                  '金额口径',
                  width: 140,
                  value: (row) => row['amountBasis'] == 'ORIGINAL'
                      ? '实际原币'
                      : row['amountBasis'] == 'LOCAL'
                      ? '本币账面'
                      : null,
                ),
                financeSourceColumn(
                  'state',
                  '状态',
                  width: 100,
                  value: (row) => row['state'] == 'APPROVED' ? '资料已审核' : '待审核',
                ),
              ],
              rows: _items,
              idOf: (row) => row['id'].toString(),
              busy: _busy,
              error: _error,
              retry: () => _load(_page),
              page: _page,
              pages: _pages,
              onPage: (page) => _load(page),
              scope: (_epoch, _keyword),
              showColumnChooser: false,
              canOpen: _selectable,
              onOpen: (row) {
                if (_current && _selectable(row)) {
                  Navigator.pop(
                    context,
                    Map<String, dynamic>.unmodifiable(row),
                  );
                }
              },
            ),
          ),
          if (_busy)
            const UtenBusyOverlay(title: '正在读取对账资料', showDoNotLeaveHint: false),
        ],
      ),
    );
  }
}
