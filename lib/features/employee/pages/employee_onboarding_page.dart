// 入职办理页（真实后端）：单表单分组提交 → 后端原子建 employee+敏感+薪资+合同+轨迹+账号。
// 账号 = 工号；初始密码 = 身份证后六位（首登强制改）。
// 文档：docs/03-页面/入职流程页.md
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/network/api_exception.dart';
import '../../../core/utils/id_card_utils.dart';
import '../../department/models/department_node.dart';
import '../../department/repositories/department_repository.dart';
import '../models/employee_api_models.dart';
import '../repositories/employee_repository.dart';

class EmployeeOnboardingPage extends ConsumerStatefulWidget {
  const EmployeeOnboardingPage({super.key});

  @override
  ConsumerState<EmployeeOnboardingPage> createState() => _EmployeeOnboardingPageState();
}

class _EmployeeOnboardingPageState extends ConsumerState<EmployeeOnboardingPage> {
  final _formKey = GlobalKey<FormState>();
  final _code = TextEditingController();
  final _name = TextEditingController();
  final _idNumber = TextEditingController();
  final _phone = TextEditingController();
  final _email = TextEditingController();
  final _hireDate = TextEditingController();
  final _baseSalary = TextEditingController();
  final _bankAccount = TextEditingController();
  final _bankBranch = TextEditingController();

  String _idType = '身份证';
  String _employmentType = 'regular';
  String _status = 'active';
  String? _departmentId;
  List<DepartmentNode> _depts = const [];
  bool _loading = true;
  bool _submitting = false;

  static const _idTypes = ['身份证', '护照', '港澳台通行证', '其他'];
  static const _employmentTypes = {'regular': '正式', 'dispatch': '劳务派遣', 'intern': '实习', 'outsource': '外包'};
  static const _statuses = {'active': '在职', 'probation': '试用', 'onLeave': '休假'};

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _loadDepts());
  }

  @override
  void dispose() {
    for (final c in [_code, _name, _idNumber, _phone, _email, _hireDate, _baseSalary, _bankAccount, _bankBranch]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _loadDepts() async {
    try {
      final tree = await ref.read(departmentRepositoryProvider).tree();
      if (!mounted) return;
      setState(() {
        _depts = _flatten(tree);
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _loading = false);
    }
  }

  List<DepartmentNode> _flatten(List<DepartmentNode> tree) {
    final out = <DepartmentNode>[];
    void walk(List<DepartmentNode> nodes) {
      for (final n in nodes) {
        out.add(n);
        walk(n.children);
      }
    }
    walk(tree);
    return out;
  }

  Future<void> _pickDate() async {
    final d = await showDatePicker(
      context: context,
      initialDate: DateTime.now(),
      firstDate: DateTime(1990),
      lastDate: DateTime.now().add(const Duration(days: 365)),
    );
    if (d != null) {
      _hireDate.text = '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
    }
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() => _submitting = true);
    try {
      final profile = <String, dynamic>{
        'code': _code.text.trim(),
        'fullName': _name.text.trim(),
        'idType': _idType,
        'idNumber': _idNumber.text.trim(),
        'phone': _phone.text.trim(),
        if (_email.text.trim().isNotEmpty) 'email': _email.text.trim(),
      };
      final employment = <String, dynamic>{
        'departmentId': _departmentId,
        'hireDate': _hireDate.text.trim().isEmpty ? DateTime.now().toIso8601String().substring(0, 10) : _hireDate.text.trim(),
        'employmentType': _employmentType,
        'status': _status,
      };
      Map<String, dynamic>? compensation;
      if (_baseSalary.text.trim().isNotEmpty || _bankAccount.text.trim().isNotEmpty) {
        compensation = {
          if (_baseSalary.text.trim().isNotEmpty) 'baseSalary': _baseSalary.text.trim(),
          if (_bankAccount.text.trim().isNotEmpty) 'bankAccount': _bankAccount.text.trim(),
          if (_bankBranch.text.trim().isNotEmpty) 'bankBranch': _bankBranch.text.trim(),
        };
      }
      await ref.read(employeeRepositoryProvider).create(
            EmployeeOnboardingInput(profile: profile, employment: employment, compensation: compensation),
          );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('入职成功：账号=工号，初始密码=身份证后六位（首登需改）')),
      );
      context.pop();
    } on ApiException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('提交失败，请重试')));
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('新员工入职')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : Form(
              key: _formKey,
              child: ListView(
                padding: const EdgeInsets.all(16),
                children: [
                  _group(theme, '档案', [
                    _text(_code, '工号*', '如 E1001', validator: (v) => _req(v, '工号')),
                    _text(_name, '姓名*', '张三', validator: (v) => _req(v, '姓名')),
                    DropdownButtonFormField<String>(
                      value: _idType,
                      decoration: const InputDecoration(labelText: '证件类型*'),
                      items: _idTypes.map((e) => DropdownMenuItem(value: e, child: Text(e))).toList(),
                      onChanged: (v) => setState(() => _idType = v ?? _idType),
                    ),
                    _text(_idNumber, '证件号码*', '请输入身份证号',
                        validator: (v) => _idType == '身份证' && !IdCardUtils.isValid(v) ? '身份证号格式不正确' : _req(v, '证件号码')),
                    _text(_phone, '手机号*', '11 位手机号', validator: (v) {
                      if (v == null || v.trim().isEmpty) return '手机号不能为空';
                      if (!RegExp(r'^1[3-9]\d{9}$').hasMatch(v.trim())) return '手机号格式不正确';
                      return null;
                    }),
                    _text(_email, '企业邮箱', '可选'),
                  ]),
                  _group(theme, '组织', [
                    DropdownButtonFormField<String>(
                      value: _departmentId,
                      decoration: const InputDecoration(labelText: '所属部门*'),
                      items: _depts
                          .map((d) => DropdownMenuItem(value: d.id, child: Text('${d.level} · ${d.name}', overflow: TextOverflow.ellipsis)))
                          .toList(),
                      onChanged: (v) => setState(() => _departmentId = v),
                      validator: (v) => v == null || v.isEmpty ? '请选择部门' : null,
                    ),
                    GestureDetector(
                      onTap: _pickDate,
                      child: AbsorbPointer(
                        child: _text(_hireDate, '入职日期*', 'yyyy-MM-dd',
                            validator: (v) => (v == null || v.isEmpty) ? '请选择入职日期' : null),
                      ),
                    ),
                    DropdownButtonFormField<String>(
                      value: _employmentType,
                      decoration: const InputDecoration(labelText: '用工形式*'),
                      items: _employmentTypes.entries.map((e) => DropdownMenuItem(value: e.key, child: Text(e.value))).toList(),
                      onChanged: (v) => setState(() => _employmentType = v ?? _employmentType),
                    ),
                    DropdownButtonFormField<String>(
                      value: _status,
                      decoration: const InputDecoration(labelText: '工作状态*'),
                      items: _statuses.entries.map((e) => DropdownMenuItem(value: e.key, child: Text(e.value))).toList(),
                      onChanged: (v) => setState(() => _status = v ?? _status),
                    ),
                  ]),
                  _group(theme, '薪资 / 银行（可选，仅 HR/管理员可见）', [
                    _text(_baseSalary, '基本工资', '可选'),
                    _text(_bankBranch, '开户银行及支行', '可选'),
                    _text(_bankAccount, '薪资发放银行卡号', '可选'),
                  ]),
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    child: Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(color: theme.colorScheme.surfaceContainerHigh, borderRadius: BorderRadius.circular(8)),
                      child: Text(
                        '提交后将自动创建登录账号：账号=工号，初始密码=身份证后六位，首次登录必须修改密码。',
                        style: theme.textTheme.bodySmall,
                      ),
                    ),
                  ),
                  FilledButton(
                    onPressed: _submitting ? null : _submit,
                    child: _submitting
                        ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                        : const Text('提交入职'),
                  ),
                  const SizedBox(height: 24),
                ],
              ),
            ),
    );
  }

  Widget _group(ThemeData theme, String title, List<Widget> children) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Card(
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Text(title, style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w600)),
            const SizedBox(height: 8),
            ...children,
          ]),
        ),
      ),
    );
  }

  Widget _text(TextEditingController c, String label, String hint, {String? Function(String?)? validator}) {
    return Padding(
      padding: const EdgeInsets.only(top: 6, bottom: 6),
      child: TextFormField(
        controller: c,
        decoration: InputDecoration(labelText: label, hintText: hint, isDense: true, border: const OutlineInputBorder()),
        validator: validator,
      ),
    );
  }

  String? _req(String? v, String label) => (v == null || v.trim().isEmpty) ? '$label不能为空' : null;
}
