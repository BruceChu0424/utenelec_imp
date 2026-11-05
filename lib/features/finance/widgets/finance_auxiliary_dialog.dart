import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../../components/feedback/uten_dialog.dart';
import '../../../components/inputs/uten_input.dart';
import '../../../components/inputs/uten_field_hint_icon.dart';
import '../../../components/layout/uten_filter_toolbar.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../basic_data/widgets/master_data_table_view.dart';
import 'finance_source_table.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../components/buttons/uten_button.dart';
import '../../../components/inputs/uten_dropdown_field.dart';
import '../../../core/network/api_client.dart';
import '../../../core/network/api_exception.dart';
import '../../../shared/models/employee_reference.dart';
import '../../../shared/providers/export_context_epoch_provider.dart';
import '../../../shared/widgets/business_employee_picker.dart';
import '../../basic_data/widgets/uten_client_picker.dart';
import '../../basic_data/widgets/uten_supplier_picker.dart';

const _roles = {
  'CUSTOMER': '客户',
  'SUPPLIER': '供应商',
  'EMPLOYEE': '员工',
  'OTHER': '其他往来',
};

/// The selected UUID is the accounting auxiliary, never a name or business party code.
Future<Map<String, dynamic>?> showFinanceAuxiliaryPicker(
  BuildContext context, {
  String? accountCode,
  String? role,
  bool canEdit = false,
  bool selection = true,
}) => showDialog<Map<String, dynamic>>(
  context: context,
  barrierDismissible: false,
  builder: (_) => _AuxiliaryDirectory(
    accountCode: accountCode,
    role: role,
    canEdit: canEdit,
    selection: selection,
  ),
);

class _AuxiliaryDirectory extends ConsumerStatefulWidget {
  const _AuxiliaryDirectory({
    this.accountCode,
    this.role,
    required this.canEdit,
    required this.selection,
  });
  final String? accountCode, role;
  final bool canEdit, selection;
  @override
  ConsumerState<_AuxiliaryDirectory> createState() =>
      _AuxiliaryDirectoryState();
}

class _AuxiliaryDirectoryState extends ConsumerState<_AuxiliaryDirectory> {
  late final ApiClient _api;
  late final int _epoch;
  final _search = TextEditingController();
  List<Map<String, dynamic>> _items = [];
  bool _busy = false;
  int _page = 1, _pages = 0, _generation = 0;
  String? _error;
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
    _search.dispose();
    super.dispose();
  }

  Future<void> _load(int page) async {
    if (!_current || _busy) return;
    final generation = ++_generation;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final data = await _api.get(
        '/finance/auxiliary-items',
        query: {
          if (widget.accountCode != null) 'accountCode': widget.accountCode,
          if (widget.role != null) 'role': widget.role,
          'keyword': _search.text,
          'page': '$page',
          'size': '50',
        },
      );
      if (!_current || generation != _generation) return;
      setState(() {
        _items = [
          for (final item in data['items'] as List? ?? [])
            if (item is Map<String, dynamic>) item,
        ];
        _page = page;
        _pages = (data['totalPages'] as num?)?.toInt() ?? 0;
      });
    } catch (error) {
      if (_current && generation == _generation) {
        setState(() => _error = _message(error));
      }
    } finally {
      if (_current && generation == _generation) setState(() => _busy = false);
    }
  }

  Future<void> _edit([Map<String, dynamic>? item]) async {
    if (!_current || _busy) return;
    final changed = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (_) => _AuxiliaryEditor(
        item: item,
        accountCode: widget.accountCode,
        role: widget.role,
        ownerEpoch: _epoch,
      ),
    );
    if (_current && changed == true) await _load(_page);
  }

  @override
  Widget build(BuildContext context) {
    if (ref.watch(exportContextEpochProvider) != _epoch) {
      return UtenAlertDialog(
        showCloseButton: true,
        onClose: () => Navigator.pop(context),

        title: const Text('访问范围已变化'),
      );
    }
    final columns = <MasterColumnDef<Map<String, dynamic>>>[
      financeSourceColumn('sourceCode', '原项目编号', width: 140),
      financeSourceColumn('sourceName', '原项目名称', width: 220),
      financeSourceColumn('sourceSystem', '来源账套'),
      financeSourceColumn(
        'role',
        '类别',
        width: 100,
        value: (row) => _roles[row['role']],
      ),
      financeSourceColumn('partyCode', '对应业务编号'),
      financeSourceColumn('partyName', '对应业务对象', width: 220),
      financeSourceColumn(
        'status',
        '状态',
        width: 160,
        value: (row) => row['status'] != 'ACTIVE'
            ? '已停用'
            : row['partyId'] == null
            ? '未对应（草稿）'
            : '已对应',
      ),
      if (widget.canEdit)
        MasterColumnDef<Map<String, dynamic>>(
          key: 'actions',
          label: '操作',
          width: 100,
          value: (_) => '对应',
          columnSearchEnabled: false,
          exportable: false,
          cellBuilder: (context, row) => TextButton(
            onPressed: _busy ? null : () => _edit(row),
            child: const Text('对应'),
          ),
        ),
    ];
    return UtenDialogFrame(
      maxWidth: 1100,
      fillHeight: true,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          UtenDialogHeader(
            title: const Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text('辅助核算项目'),
                SizedBox(width: 6),
                UtenFieldHintIcon(info: '按来源账套和原编号对应业务对象。未对应项目可保存草稿，不能过账。'),
              ],
            ),
            showCloseButton: true,
            onClose: _busy ? null : () => Navigator.pop(context),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: UtenSpacing.s16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                UtenFilterToolbar<String>(
                  enabled: !_busy,
                  searchController: _search,
                  searchHint: '原项目编号或名称',
                  onSearchSubmitted: (_) => _load(1),
                ),
              ],
            ),
          ),
          Expanded(
            child: financeSourceTable(
              tableKey: 'finance.auxiliary.directory.v1',
              columns: columns,
              rows: _items,
              idOf: (row) => '${row['id']}',
              busy: _busy,
              error: _error,
              retry: () => _load(_page),
              page: _page,
              pages: _pages,
              onPage: _load,
              scope: (_epoch, widget.accountCode, widget.role, _search.text),
              actions: [
                UtenButton(
                  onPressed: _busy ? null : () => _load(1),
                  child: const Text('查询'),
                ),
                if (widget.canEdit)
                  UtenButton(
                    onPressed: _busy ? null : () => _edit(),
                    child: const Text('添加'),
                  ),
              ],
              canOpen: (row) => !_busy && row['status'] == 'ACTIVE',
              onOpen: (row) {
                if (widget.selection) {
                  Navigator.pop(context, row);
                } else if (widget.canEdit) {
                  _edit(row);
                }
              },
            ),
          ),
        ],
      ),
    );
  }
}

class _AuxiliaryEditor extends ConsumerStatefulWidget {
  const _AuxiliaryEditor({
    this.item,
    this.accountCode,
    this.role,
    required this.ownerEpoch,
  });
  final Map<String, dynamic>? item;
  final String? accountCode, role;
  final int ownerEpoch;
  @override
  ConsumerState<_AuxiliaryEditor> createState() => _AuxiliaryEditorState();
}

class _AuxiliaryEditorState extends ConsumerState<_AuxiliaryEditor> {
  late final ApiClient _api;
  late final TextEditingController _system, _code, _name, _reference;
  late String _role;
  String? _partyId, _partyLabel, _error;
  bool _busy = false, _unknown = false, _otherUnknown = false, _dirty = false;
  Map<String, dynamic>? _pending;
  Map<String, dynamic>? _pendingOther;
  bool get _current =>
      mounted &&
      widget.ownerEpoch == ref.read(exportContextEpochProvider) &&
      identical(_api, ref.read(apiClientProvider));
  @override
  void initState() {
    super.initState();
    _api = ref.read(apiClientProvider);
    final item = widget.item;
    _system = TextEditingController(
      text: item?['sourceSystem']?.toString() ?? '',
    );
    _code = TextEditingController(text: item?['sourceCode']?.toString() ?? '');
    _name = TextEditingController(text: item?['sourceName']?.toString() ?? '');
    _reference = TextEditingController(
      text: item?['sourceReference']?.toString() ?? '',
    );
    _role = item?['role']?.toString() ?? widget.role ?? 'CUSTOMER';
    _partyId = item?['partyId']?.toString();
    _partyLabel = item?['partyName']?.toString();
  }

  @override
  void dispose() {
    for (final c in [_system, _code, _name, _reference]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _pickParty() async {
    if (!_current || _busy || _unknown || _otherUnknown) return;
    if (_role == 'CUSTOMER') {
      final item = await showUtenClientPicker(
        context,
        ref,
        selectableOnly: false,
        excludeLegacyFinanceStub: false,
      );
      if (_current && item != null) {
        setState(() {
          _partyId = item.id;
          _partyLabel = clientPickerLabel(item);
          _dirty = true;
        });
      }
    } else if (_role == 'SUPPLIER') {
      final item = await showUtenSupplierPicker(
        context,
        ref,
        selectableOnly: false,
        allowQuickCreate: false,
      );
      if (_current && item != null) {
        setState(() {
          _partyId = item.id;
          _partyLabel = '${item.code} ${item.name}';
          _dirty = true;
        });
      }
    }
  }

  Future<void> _save() async {
    if (!_current || _busy || _otherUnknown) return;
    if (!_unknown) {
      if (_system.text.trim().isEmpty ||
          _code.text.trim().isEmpty ||
          _name.text.trim().isEmpty) {
        setState(() => _error = '请按原表填写来源账套、原项目编号和原项目名称');
        return;
      }
      _pending = {
        'id': widget.item?['id'],
        'expectedVersion': widget.item?['version'],
        'sourceSystem': _system.text,
        'sourceCode': _code.text,
        'sourceName': _name.text,
        'role': _role,
        'partyId': _partyId,
        'sourceReference': _reference.text.trim().isEmpty
            ? null
            : _reference.text,
        'accountCode': widget.accountCode,
      };
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    final wasUnknown = _unknown;
    try {
      await _api.post('/finance/auxiliary-items', body: _pending);
      if (mounted && _current) Navigator.pop(context, true);
    } catch (error) {
      if (_current) {
        setState(() {
          _unknown = wasUnknown || !_rejected(error);
          _error = _unknown
              ? '${_message(error)}。提交结果待核对，请保留原内容并重试原提交。'
              : _message(error);
        });
      }
    } finally {
      if (_current) setState(() => _busy = false);
    }
  }

  Future<void> _createOther() async {
    if (!_current || _busy || _unknown) return;
    if (!_otherUnknown &&
        (_system.text.trim().isEmpty ||
            _code.text.trim().isEmpty ||
            _name.text.trim().isEmpty)) {
      setState(() => _error = '请先填写完整原项目身份');
      return;
    }
    if (!_otherUnknown) {
      _pendingOther = {
        'sourceSystem': _system.text,
        'sourceCode': _code.text,
        'sourceName': _name.text,
      };
    }
    final wasUnknown = _otherUnknown;
    // Same exact source identity is replayable; uncertain outcomes freeze that identity.
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final value = await _api.post(
        '/finance/auxiliary-items/parties',
        body: _pendingOther,
      );
      if (_current) {
        setState(() {
          _partyId = value['id']?.toString();
          _partyLabel = value['sourceName']?.toString();
          _dirty = true;
          _otherUnknown = false;
        });
      }
    } catch (error) {
      if (_current) {
        setState(() {
          _otherUnknown = wasUnknown || !_rejected(error);
          _error = '${_message(error)}。原身份已保留，可重试核对同一对象。';
        });
      }
    } finally {
      if (_current) setState(() => _busy = false);
    }
  }

  Future<void> _close() async {
    if (_busy || _unknown || _otherUnknown) return;
    if (_dirty) {
      final discard = await showDialog<bool>(
        context: context,
        builder: (ctx) => UtenAlertDialog(
          title: const Text('放弃未保存的对应？'),
          content: const Text('已填写内容尚未保存。'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('继续填写'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('放弃'),
            ),
          ],
        ),
      );
      if (discard != true) return;
    }
    if (mounted) Navigator.pop(context, false);
  }

  @override
  Widget build(BuildContext context) {
    if (ref.watch(exportContextEpochProvider) != widget.ownerEpoch) {
      return UtenAlertDialog(
        showCloseButton: true,
        onClose: () => Navigator.pop(context),

        title: const Text('访问范围已变化'),
      );
    }
    final editable = !_busy && !_unknown && !_otherUnknown;
    Widget field(
      TextEditingController controller,
      String label, {
      bool identity = false,
    }) => Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: UtenInput(
        controller: controller,
        label: label,
        enabled: editable && (!identity || widget.item == null),
        inputFormatters: [
          LengthLimitingTextInputFormatter(
            label == '来源依据'
                ? 2000
                : label == '来源账套'
                ? 80
                : 240,
          ),
        ],
        onChanged: (_) => _dirty = true,
      ),
    );
    return PopScope(
      canPop: false,
      child: UtenDialogFrame(
        maxWidth: 660,
        fillHeight: true,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            UtenDialogHeader(
              title: const Text('辅助核算项目对应'),
              showCloseButton: true,
              onClose: editable ? _close : null,
            ),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: UtenSpacing.s16,
                ),
                child: SingleChildScrollView(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      field(_system, '来源账套', identity: true),
                      field(_code, '原项目编号', identity: true),
                      field(_name, '原项目名称'),
                      UtenDropdownField(
                        label: '类别',
                        value: _role,
                        enabled:
                            editable &&
                            widget.item == null &&
                            widget.role == null,
                        allowClear: false,
                        items: [
                          for (final entry in _roles.entries)
                            UtenDropdownItem(
                              value: entry.key,
                              label: entry.value,
                            ),
                        ],
                        onChanged: (role) {
                          if (role != null) {
                            setState(() {
                              _role = role;
                              _partyId = null;
                              _partyLabel = null;
                              _dirty = true;
                            });
                          }
                        },
                      ),
                      const SizedBox(height: 12),
                      if (_role == 'EMPLOYEE')
                        BusinessEmployeePicker(
                          purpose:
                              EmployeeReferencePurpose.financeAuxiliaryParty,
                          selectedId: _partyId,
                          label: '对应员工',
                          enabled: editable,
                          onChanged: (item) => setState(() {
                            _partyId = item?.id;
                            _partyLabel = item?.displayName;
                            _dirty = true;
                          }),
                        )
                      else
                        OutlinedButton(
                          onPressed: editable
                              ? (_role == 'OTHER' ? _createOther : _pickParty)
                              : null,
                          child: Text(
                            _partyId == null
                                ? (_role == 'OTHER'
                                      ? '建立或核对其他往来对象'
                                      : '选择对应${_roles[_role]}')
                                : _partyLabel ?? _partyId!,
                          ),
                        ),
                      if (_partyId != null)
                        TextButton(
                          onPressed: editable
                              ? () => setState(() {
                                  _partyId = null;
                                  _partyLabel = null;
                                  _dirty = true;
                                })
                              : null,
                          child: const Text('清除对应，保留草稿'),
                        ),
                      const SizedBox(height: 12),
                      field(_reference, '来源依据'),
                      if (_otherUnknown)
                        UtenButton(
                          onPressed: _busy ? null : _createOther,
                          child: const Text('核对并重试原对象'),
                        ),
                      if (_error != null)
                        SelectableText(
                          _error!,
                          style: TextStyle(
                            color: Theme.of(context).colorScheme.error,
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ),
            UtenDialogActions(
              alignment: MainAxisAlignment.end,
              overflowAlignment: OverflowBarAlignment.end,
              children: [
                TextButton(
                  onPressed: editable ? _close : null,
                  child: const Text('取消'),
                ),
                UtenButton(
                  onPressed: _busy || _otherUnknown ? null : _save,
                  isLoading: _busy,
                  child: Text(
                    _unknown
                        ? '核对并重试原提交'
                        : _partyId == null
                        ? '保存草稿'
                        : '保存对应',
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

String _message(Object error) =>
    error is ApiException ? error.message : '操作未完成，请核对网络后重试';
bool _rejected(Object error) =>
    error is ApiException &&
    error.hasResponseCode &&
    (error.httpStatus ?? 0) >= 400 &&
    (error.httpStatus ?? 0) < 500 &&
    error.httpStatus != 408;
