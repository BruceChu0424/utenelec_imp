// 访客来访预约表单：姓名/身份证/单位/事由/开车+车牌/接待部门+接待人/到访时间。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../components/buttons/uten_button.dart';
import '../../../components/cards/uten_card.dart';
import '../../../components/inputs/uten_input.dart';
import '../../../components/layout/uten_app_bar.dart';
import '../../../components/layout/uten_bottom_action_bar.dart';
import '../../../components/layout/uten_section_header.dart';
import '../../../core/responsive/scale.dart';
import '../../../components/inputs/uten_select.dart';
import '../../../core/l10n/gen/app_localizations.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/theme/uten_colors.dart';
import '../providers/visitor_providers.dart';
import '../repositories/visitor_repository.dart';

class VisitorApplyPage extends ConsumerStatefulWidget {
  const VisitorApplyPage({super.key});

  @override
  ConsumerState<VisitorApplyPage> createState() => _VisitorApplyPageState();
}

class _VisitorApplyPageState extends ConsumerState<VisitorApplyPage> {
  final _nameCtl = TextEditingController();
  final _idCardCtl = TextEditingController();
  final _companyCtl = TextEditingController();
  final _purposeCtl = TextEditingController();
  final _plateCtl = TextEditingController();

  bool _hasVehicle = false;
  String? _deptId;
  String? _hostId;
  DateTime? _visitTime;
  bool _submitting = false;
  String? _error;

  @override
  void dispose() {
    _nameCtl.dispose();
    _idCardCtl.dispose();
    _companyCtl.dispose();
    _purposeCtl.dispose();
    _plateCtl.dispose();
    super.dispose();
  }

  Future<void> _pickTime() async {
    final now = DateTime.now();
    final d = await showDatePicker(
      context: context,
      initialDate: now,
      firstDate: DateTime(now.year - 1),
      lastDate: DateTime(now.year + 1),
    );
    if (d == null) return;
    final t = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(now),
    );
    if (t == null) return;
    setState(() => _visitTime = DateTime(d.year, d.month, d.day, t.hour, t.minute));
  }

  Future<void> _submit() async {
    final l10n = AppLocalizations.of(context);
    if (_nameCtl.text.trim().isEmpty) {
      setState(() => _error = l10n.visitorApplyValidateName);
      return;
    }
    if (_purposeCtl.text.trim().isEmpty) {
      setState(() => _error = l10n.visitorApplyValidatePurpose);
      return;
    }
    if (_hostId == null) {
      setState(() => _error = l10n.visitorApplyValidateHost);
      return;
    }
    if (_visitTime == null) {
      setState(() => _error = l10n.visitorApplyValidateVisitTime);
      return;
    }
    setState(() {
      _submitting = true;
      _error = null;
    });
    try {
      final repo = ref.read(visitorRepositoryProvider);
      final app = await repo.submit({
        'visitorName': _nameCtl.text.trim(),
        'idCardNo': _idCardCtl.text.trim().isEmpty ? null : _idCardCtl.text.trim(),
        'company': _companyCtl.text.trim().isEmpty ? null : _companyCtl.text.trim(),
        'visitPurpose': _purposeCtl.text.trim(),
        'hasVehicle': _hasVehicle,
        'plateNo': _hasVehicle ? _plateCtl.text.trim() : null,
        'hostEmployeeId': _hostId,
        'hostDepartmentId': _deptId,
        'plannedVisitAt': _visitTime!.toUtc().toIso8601String(),
      });
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(l10n.visitorApplySuccess)));
      context.go('/visitor/apply/${app.id}');
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } catch (_) {
      if (mounted) setState(() => _error = l10n.commonError);
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final depts = ref.watch(visitorDirectoryDepartmentsProvider);
    final employees = ref.watch(visitorDirectoryEmployeesProvider(
        (departmentId: _deptId, keyword: null)));

    return Scaffold(
      appBar: UtenAppBar(title: l10n.visitorApplyTitle, showBackButton: true),
      body: Column(
        children: [
          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  UtenCard(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        UtenSectionHeader(title: l10n.visitorApplyTitle, icon: Icons.person_rounded),
                        const SizedBox(height: 12),
                        UtenInput(controller: _nameCtl, label: l10n.visitorApplyName, hint: l10n.visitorApplyNameHint),
                        const SizedBox(height: 12),
                        UtenInput(controller: _idCardCtl, label: l10n.visitorApplyIdCard, hint: l10n.visitorApplyIdCardHint),
                        const SizedBox(height: 12),
                        UtenInput(controller: _companyCtl, label: l10n.visitorApplyCompany, hint: l10n.visitorApplyCompanyHint),
                        const SizedBox(height: 12),
                        UtenInput(
                          controller: _purposeCtl,
                          label: l10n.visitorApplyPurpose,
                          hint: l10n.visitorApplyPurposeHint,
                          maxLines: 3,
                        ),
                        const SizedBox(height: 8),
                        SwitchListTile(
                          contentPadding: EdgeInsets.zero,
                          title: Text(l10n.visitorApplyVehicle),
                          value: _hasVehicle,
                          onChanged: (v) => setState(() => _hasVehicle = v),
                        ),
                        if (_hasVehicle) ...[
                          UtenInput(controller: _plateCtl, label: l10n.visitorApplyPlate, hint: l10n.visitorApplyPlateHint),
                          const SizedBox(height: 12),
                        ],
                      ],
                    ),
                  ),
                  const SizedBox(height: 16),
                  UtenCard(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        UtenSectionHeader(title: l10n.visitorDetailHost, icon: Icons.people_outline_rounded),
                        const SizedBox(height: 12),
                        _DeptDropdown(
                          value: _deptId,
                          items: depts.valueOrNull ?? const [],
                          label: l10n.visitorApplyDept,
                          onChanged: (v) => setState(() {
                            _deptId = v;
                            _hostId = null;
                          }),
                        ),
                        const SizedBox(height: 12),
                        _EmployeeDropdown(
                          value: _hostId,
                          items: employees.valueOrNull ?? const [],
                          label: l10n.visitorApplyHost,
                          onChanged: (v) => setState(() => _hostId = v),
                        ),
                        const SizedBox(height: 12),
                        InkWell(
                          onTap: _pickTime,
                          child: InputDecorator(
                            decoration: InputDecoration(
                              labelText: l10n.visitorApplyVisitTime,
                              prefixIcon: Icon(Icons.event_rounded, size: context.scaled(20)),
                            ),
                            child: Text(_visitTime == null
                                ? l10n.visitorApplyVisitTime
                                : '${_visitTime!.year}-${_visitTime!.month.toString().padLeft(2, '0')}-${_visitTime!.day.toString().padLeft(2, '0')} ${_visitTime!.hour.toString().padLeft(2, '0')}:${_visitTime!.minute.toString().padLeft(2, '0')}'),
                          ),
                        ),
                      ],
                    ),
                  ),
                  if (_error != null) ...[
                    const SizedBox(height: 12),
                    Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: UtenColors.error.withValues(alpha: 0.15),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Text(_error!, style: theme.textTheme.bodySmall?.copyWith(color: UtenColors.error)),
                    ),
                  ],
                  const SizedBox(height: 16),
                ],
              ),
            ),
          ),
          UtenBottomActionBar(
            child: UtenButton(
              onPressed: _submitting ? null : _submit,
              isLoading: _submitting,
              isExpanded: true,
              size: UtenButtonSize.large,
              child: Text(_submitting ? l10n.visitorApplySubmitting : l10n.visitorApplySubmit),
            ),
          ),
        ],
      ),
    );
  }
}

class _DeptDropdown extends StatelessWidget {
  const _DeptDropdown({required this.value, required this.items, required this.label, required this.onChanged});
  final String? value;
  final List<DeptDirItem> items;
  final String label;
  final ValueChanged<String?> onChanged;

  @override
  Widget build(BuildContext context) {
    return UtenSelect<String>(
      label: label,
      value: value,
      prefixIcon: Icons.account_tree_outlined,
      items: [
        for (final d in items) DropdownMenuItem(value: d.id, child: Text(d.name, overflow: TextOverflow.ellipsis)),
      ],
      onChanged: onChanged,
    );
  }
}

class _EmployeeDropdown extends StatelessWidget {
  const _EmployeeDropdown({required this.value, required this.items, required this.label, required this.onChanged});
  final String? value;
  final List<EmployeeDirItem> items;
  final String label;
  final ValueChanged<String?> onChanged;

  @override
  Widget build(BuildContext context) {
    return UtenSelect<String>(
      label: label,
      value: value,
      prefixIcon: Icons.person_search_rounded,
      items: [
        for (final e in items)
          DropdownMenuItem(
            value: e.id,
            child: Text(
              e.departmentName == null ? e.name : '${e.name}(${e.departmentName})',
              overflow: TextOverflow.ellipsis,
            ),
          ),
      ],
      onChanged: onChanged,
    );
  }
}
