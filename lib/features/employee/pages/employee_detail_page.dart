// 员工详情页（真实后端 + 组件库）。敏感字段由后端按当前角色脱敏后返回。
// 分组用 UtenCard，键值用 UtenInfoRow，状态用 EmployeeStatusBadge，空/错用 UtenEmpty。
// 文档：docs/03-页面/员工详情页.md
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../components/cards/uten_card.dart';
import '../../../components/data_display/uten_info_row.dart';
import '../../../components/data_display/uten_status_badge.dart';
import '../../../components/feedback/uten_empty.dart';
import '../../../core/network/api_exception.dart';
import '../models/employee_api_models.dart';
import '../repositories/employee_repository.dart';
import '../widgets/employee_status_badge.dart';

class EmployeeDetailPage extends ConsumerStatefulWidget {
  const EmployeeDetailPage({super.key, required this.employeeId});

  final String employeeId;

  @override
  ConsumerState<EmployeeDetailPage> createState() => _EmployeeDetailPageState();
}

class _EmployeeDetailPageState extends ConsumerState<EmployeeDetailPage> {
  EmployeeProfile? _profile;
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final p = await ref.read(employeeRepositoryProvider).getById(widget.employeeId);
      if (!mounted) return;
      setState(() {
        _profile = p;
        _loading = false;
      });
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.message;
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _error = '加载失败';
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('员工详情')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? UtenEmpty.error(message: _error, actionLabel: '重试', onAction: _load)
              : RefreshIndicator(
                  onRefresh: _load,
                  child: ListView(
                    padding: const EdgeInsets.all(16),
                    children: [
                      _header(theme),
                      const SizedBox(height: 12),
                      _section('基本信息', [
                        UtenInfoRow(label: '工号', value: _p.code, showDivider: false),
                        UtenInfoRow(label: '姓名', value: _p.fullName),
                        UtenInfoRow(label: '性别', value: _genderText(_p.gender)),
                        UtenInfoRow(label: '证件类型', value: _p.idType),
                        UtenInfoRow(label: '证件号码', value: _p.idNumber),
                        UtenInfoRow(label: '出生日期', value: _p.birthDate),
                        UtenInfoRow(label: '民族', value: _p.ethnicity),
                        UtenInfoRow(label: '政治面貌', value: _p.politicalStatus),
                        UtenInfoRow(label: '婚姻状况', value: _p.maritalStatus, showDivider: false),
                      ]),
                      _section('联系与地址', [
                        UtenInfoRow(label: '手机号', value: _p.phone, showDivider: false),
                        UtenInfoRow(label: '办公电话', value: _p.officePhone),
                        UtenInfoRow(label: '企业邮箱', value: _p.email),
                        UtenInfoRow(label: '户籍地址', value: _p.hujiAddress),
                        UtenInfoRow(label: '现居住地', value: _p.residenceAddress, showDivider: false),
                      ]),
                      _section('组织与用工', [
                        UtenInfoRow(label: '所属部门', value: _p.departmentName, showDivider: false),
                        UtenInfoRow(label: '岗位', value: _p.positionName),
                        UtenInfoRow(label: '直属上级', value: _p.supervisorName),
                        UtenInfoRow(label: '入职日期', value: _p.hireDate),
                        UtenInfoRow(label: '转正日期', value: _p.confirmedAt),
                        UtenInfoRow(label: '工作状态', value: null, valueWidget: EmployeeStatusBadge(status: _p.status, size: UtenStatusBadgeSize.medium)),
                        UtenInfoRow(label: '用工形式', value: _employmentTypeText(_p.employmentType)),
                        UtenInfoRow(label: '办公地点', value: _p.workLocation),
                        UtenInfoRow(label: '工位号', value: _p.seatNo, showDivider: false),
                      ]),
                      if (_p.contractType != null || _p.baseSalary != null || _p.bankAccount != null)
                        _section('合同 / 薪资（按权限可见）', [
                          UtenInfoRow(label: '合同类型', value: _contractTypeText(_p.contractType), showDivider: false),
                          UtenInfoRow(label: '合同起止', value: _p.contractStart == null ? null : '${_p.contractStart} ~ ${_p.contractEnd ?? ''}'),
                          UtenInfoRow(label: '试用期', value: _p.probationMonths == null ? null : '${_p.probationMonths} 个月（至 ${_p.probationEndDate ?? ''}）'),
                          UtenInfoRow(label: '续签次数', value: _p.renewCount == null ? null : '${_p.renewCount}'),
                          UtenInfoRow(label: '基本工资', value: _p.baseSalary),
                          UtenInfoRow(label: '绩效/补贴', value: _p.perfSalary),
                          UtenInfoRow(label: '社保基数', value: _p.socialInsuranceBase),
                          UtenInfoRow(label: '公积金基数', value: _p.housingFundBase),
                          UtenInfoRow(label: '开户银行', value: _p.bankBranch),
                          UtenInfoRow(label: '银行卡号', value: _p.bankAccount, showDivider: false),
                        ]),
                      if (_p.emergencyContacts.isNotEmpty)
                        _section('紧急联系人', [
                          for (final c in _p.emergencyContacts)
                            UtenInfoRow(
                              label: '${c.relationship ?? ''} ${c.name ?? ''}',
                              value: c.phone,
                              showDivider: c != _p.emergencyContacts.last,
                            ),
                        ]),
                      if (_p.history.isNotEmpty) ...[
                        const SizedBox(height: 8),
                        UtenCard(
                          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                            Text('任职轨迹', style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w600)),
                            const SizedBox(height: 8),
                            for (final h in _p.history)
                              ListTile(
                                dense: true,
                                contentPadding: EdgeInsets.zero,
                                leading: const Icon(Icons.history_rounded, size: 20),
                                title: Text(_historyTitle(h)),
                                subtitle: h.eventDate == null ? null : Text(h.eventDate!),
                              ),
                          ]),
                        ),
                      ],
                      const SizedBox(height: 24),
                    ],
                  ),
                ),
    );
  }

  EmployeeProfile get _p => _profile!;

  Widget _header(ThemeData theme) {
    final p = _p;
    return UtenCard(
      padding: const EdgeInsets.all(16),
      child: Row(children: [
        CircleAvatar(
          radius: 24,
          backgroundColor: theme.colorScheme.primaryContainer,
          foregroundColor: theme.colorScheme.onPrimaryContainer,
          child: Text((p.fullName ?? '?').characters.first),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(p.fullName ?? '', style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
            Text('${p.code} · ${p.departmentName ?? ''} · ${p.positionName ?? ''}',
                style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
          ]),
        ),
        EmployeeStatusBadge(status: p.status),
      ]),
    );
  }

  Widget _section(String title, List<Widget> rows) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(top: 8, bottom: 8),
      child: UtenCard(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(title, style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w600)),
          ...rows,
        ]),
      ),
    );
  }

  String? _genderText(String? g) => const {'male': '男', 'female': '女'}[g ?? ''];
  String? _employmentTypeText(String? t) =>
      const {'regular': '正式', 'dispatch': '劳务派遣', 'intern': '实习', 'outsource': '外包'}[t ?? ''];
  String? _contractTypeText(String? t) =>
      const {'fixed': '固定期限', 'open': '无固定期限', 'task': '任务', 'intern': '实习'}[t ?? ''];
  String _historyTitle(EmploymentHistoryView h) {
    const map = {'onboard': '入职', 'transfer': '调岗', 'resign': '离职'};
    final type = map[h.eventType] ?? h.eventType ?? '';
    final dept = h.toDeptName ?? h.fromDeptName ?? '';
    return '$type · $dept';
  }
}
