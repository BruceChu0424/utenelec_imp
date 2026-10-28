import 'package:flutter/material.dart';
import '../../../components/feedback/uten_dialog.dart';
import '../../../components/inputs/uten_input_decoration.dart';
import '../../../core/theme/uten_tokens.dart';
import '../models/employee_duplicate_archive.dart';
import '../repositories/employee_repository.dart';
import 'employee_dialog_error_text.dart';

/// Two explicit identities and a review receipt; names are never a merge key.
class EmployeeDuplicateArchiveDialog extends StatefulWidget {
  const EmployeeDuplicateArchiveDialog({
    super.key,
    required this.employeeId,
    required this.employeeCode,
    required this.repository,
    required this.isCurrent,
  });
  final String employeeId, employeeCode;
  final EmployeeRepository repository;
  final bool Function() isCurrent;
  @override
  State<EmployeeDuplicateArchiveDialog> createState() =>
      _EmployeeDuplicateArchiveDialogState();
}

class _EmployeeDuplicateArchiveDialogState
    extends State<EmployeeDuplicateArchiveDialog> {
  final _code = TextEditingController(), _reason = TextEditingController();
  EmployeeDuplicateArchivePreview? _preview;
  bool _busy = false, _verified = false, _uncertain = false;
  bool _documentConflictVerified = false;
  String? _error;
  @override
  void dispose() {
    _code.dispose();
    _reason.dispose();
    super.dispose();
  }

  EmployeeDuplicateArchiveRepository get _repository =>
      widget.repository as EmployeeDuplicateArchiveRepository;
  bool _current() {
    if (!mounted) return false;
    if (widget.isCurrent()) return true;
    // An authorization refresh may replace the reader while checking a lost
    // response. Close this old owner; the page re-reads under the new boundary.
    setState(() => _busy = false);
    Navigator.of(context).pop();
    return false;
  }

  Future<void> _inspect() async {
    if (_busy || !_current()) return;
    setState(() {
      _busy = true;
      _error = null;
      _preview = null;
      _verified = false;
      _documentConflictVerified = false;
    });
    try {
      final preview = await _repository.previewDuplicateArchive(
        widget.employeeId,
        _code.text,
      );
      if (_current()) setState(() => _preview = preview);
    } catch (error) {
      if (mounted) {
        setState(() => _error = employeeDialogErrorText(error, '未能核对档案，请重试'));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _save() async {
    final preview = _preview;
    if (_busy ||
        _uncertain ||
        preview == null ||
        !_verified ||
        (preview.documentConflict && !_documentConflictVerified) ||
        !_current()) {
      return;
    }
    if (_reason.text.trim().length < 5) {
      setState(() => _error = '请填写至少5字的核验依据，例如已核对证件原件及入职记录');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final retained = await _repository.archiveDuplicate(
        widget.employeeId,
        preview,
        _reason.text,
        documentConflictVerified: _documentConflictVerified,
      );
      if (!mounted) return;
      if (_current()) {
        setState(() => _busy = false);
        Navigator.of(context).pop(retained);
      }
    } catch (error) {
      if (mounted) {
        setState(() {
          _error = employeeDialogErrorText(error, '归档结果待核对，请先读取结果');
          _uncertain = true;
        });
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _readResult() async {
    if (_busy || !_current()) return;
    setState(() => _busy = true);
    try {
      final profile = await widget.repository.getById(widget.employeeId);
      if (!mounted) return;
      if (!_current()) return;
      if (profile.id == _preview?.retainedId) {
        setState(() => _busy = false);
        Navigator.of(context).pop(profile.id);
        return;
      }
      setState(() {
        _uncertain = false;
        _preview = null;
        _verified = false;
        _error = '当前档案尚未归档，请重新核对后操作';
      });
    } catch (error) {
      if (mounted) {
        setState(
          () => _error = employeeDialogErrorText(error, '仍未能读取归档结果，请稍后核对'),
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final preview = _preview;
    return PopScope(
      canPop: !_busy,
      child: UtenAlertDialog(
        key: const ValueKey('employee-duplicate-archive-dialog'),
        title: const Text('处理重复档案'),
        content: SizedBox(
          width: 520,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('待归档工号：${widget.employeeCode}'),
                const SizedBox(height: UtenSpacing.s8),
                const Text(
                  '核实属于同一人后，将重复档案从花名册移出。工资、财务、任职记录和附件保留在原档案，并可从保留档案查看。已有登录账号或未交接工作时会阻止归档。',
                ),
                const SizedBox(height: UtenSpacing.s16),
                TextField(
                  key: const ValueKey('duplicate-retained-code'),
                  controller: _code,
                  enabled: !_busy && !_uncertain,
                  decoration: const UtenInputDecoration(
                    InputDecoration(
                      labelText: '保留档案工号',
                      border: OutlineInputBorder(),
                    ),
                  ),
                  onChanged: (_) => setState(() {
                    _preview = null;
                    _verified = false;
                    _documentConflictVerified = false;
                  }),
                ),
                const SizedBox(height: UtenSpacing.s8),
                OutlinedButton(
                  onPressed: _busy || _uncertain || _code.text.trim().isEmpty
                      ? null
                      : _inspect,
                  child: const Text('核对两份档案'),
                ),
                if (preview != null) ...[
                  const SizedBox(height: UtenSpacing.s12),
                  Text('归档：${preview.sourceName}（${preview.sourceCode}）'),
                  Text(
                    '保留：${preview.retainedName}（${preview.retainedCode}）',
                    style: Theme.of(context).textTheme.titleSmall,
                  ),
                  if (preview.blockers.isNotEmpty) ...[
                    const SizedBox(height: UtenSpacing.s8),
                    for (final blocker in preview.blockers)
                      Padding(
                        padding: const EdgeInsets.only(bottom: UtenSpacing.s8),
                        child: Text(
                          blocker,
                          style: TextStyle(
                            color: Theme.of(context).colorScheme.error,
                          ),
                        ),
                      ),
                  ] else ...[
                    const SizedBox(height: UtenSpacing.s12),
                    TextField(
                      key: const ValueKey('duplicate-verification-reason'),
                      controller: _reason,
                      enabled: !_busy && !_uncertain,
                      maxLength: 1000,
                      minLines: 2,
                      maxLines: 4,
                      decoration: const UtenInputDecoration(
                        InputDecoration(
                          labelText: '核验依据',
                          border: OutlineInputBorder(),
                        ),
                      ),
                    ),
                    CheckboxListTile(
                      contentPadding: EdgeInsets.zero,
                      value: _verified,
                      key: const ValueKey('duplicate-identity-verified'),
                      onChanged: _busy || _uncertain
                          ? null
                          : (value) =>
                                setState(() => _verified = value ?? false),
                      title: const Text('已核对证件和任职资料，确认两份档案属于同一人，且保留工号正确'),
                    ),
                    if (preview.documentConflict) ...[
                      Text(
                        '两份档案证件号码不同。号码格式通过校验不代表归属正确，请对照证件原件核对；仅同名不能归档。',
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.error,
                        ),
                      ),
                      CheckboxListTile(
                        contentPadding: EdgeInsets.zero,
                        key: const ValueKey(
                          'duplicate-document-conflict-verified',
                        ),
                        value: _documentConflictVerified,
                        onChanged: _busy || _uncertain
                            ? null
                            : (value) => setState(
                                () =>
                                    _documentConflictVerified = value ?? false,
                              ),
                        title: const Text('已核对原件，确认是旧号误录或本人历史不同证件，两份档案确属同一人'),
                      ),
                    ],
                  ],
                ],
                if (_busy)
                  const Padding(
                    padding: EdgeInsets.all(UtenSpacing.s8),
                    child: LinearProgressIndicator(),
                  ),
                if (_error != null)
                  Text(
                    _error!,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: _busy ? null : () => Navigator.of(context).pop(),
            child: const Text('取消'),
          ),
          if (_uncertain)
            FilledButton(
              onPressed: _busy ? null : _readResult,
              child: const Text('核对归档结果'),
            )
          else
            FilledButton(
              key: const ValueKey('duplicate-archive-confirm'),
              onPressed:
                  _busy ||
                      !_verified ||
                      (preview?.documentConflict == true &&
                          !_documentConflictVerified) ||
                      preview == null ||
                      preview.blockers.isNotEmpty
                  ? null
                  : _save,
              child: const Text('归档重复档案'),
            ),
        ],
      ),
    );
  }
}
