// 访客来访预约表单：姓名/身份证/单位/事由/开车+车牌/接待部门+接待人/到访时间。
//
// 响应式：访客流程不经主外壳，全断点自套 UtenContentContainer.narrow
//（表单页宜窄，宽屏居中不拉宽，水平 gutter 由容器提供）。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../components/buttons/uten_button.dart';
import '../../../components/cards/uten_card.dart';
import '../../../components/inputs/uten_employee_picker.dart';
import '../../../components/inputs/uten_input.dart';
import '../../../components/inputs/required_field_decoration.dart';
import '../../../components/layout/uten_app_bar.dart';
import '../../../components/layout/uten_bottom_action_bar.dart';
import '../../../components/layout/uten_content_container.dart';
import '../../../components/layout/uten_section_header.dart';
import '../../../core/input/china_input_formatters.dart';
import '../../../core/l10n/gen/app_localizations.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/responsive/scale.dart';
import '../../../core/utils/china_datetime.dart';
import '../../../core/utils/id_card_utils.dart';
import '../../../core/theme/uten_colors.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../core/ui/app_notification.dart';
import '../../department/widgets/uten_department_picker.dart';
import '../models/visitor_application.dart';
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
  String? _deptName;
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
    final l10n = AppLocalizations.of(context);
    final now = ChinaDateTime.now();
    final today = ChinaDateTime.today();

    // 允许预约的日期范围：今天 ~ 今天 + 30 天（过远日期不接预约）。
    final firstDate = today;
    final lastDate = today.add(const Duration(days: 30));

    // initialDate：若已有选过的 visitTime，且落在允许范围内，沿用它；
    // 否则用 today，但 lastDate 早于 today 时回退到 firstDate（防御）。
    DateTime initialDate = _visitTime ?? today;
    if (initialDate.isBefore(firstDate)) initialDate = firstDate;
    if (initialDate.isAfter(lastDate)) initialDate = lastDate;

    final d = await showDatePicker(
      context: context,
      initialDate: initialDate,
      firstDate: firstDate,
      lastDate: lastDate,
    );
    if (d == null) return;
    if (!mounted) return;

    // 选今天时，initialTime 推到「现在向上取整 5 分钟」，避免打开就是过去的钟点。
    // 选未来日期时，默认 09:00（工作时段起点）。
    final TimeOfDay initialTime;
    if (_isSameDay(d, now)) {
      final roundedMinute = ((now.minute + 4) ~/ 5) * 5;
      initialTime = TimeOfDay(
        hour: roundedMinute == 60 ? (now.hour + 1) % 24 : now.hour,
        minute: roundedMinute == 60 ? 0 : roundedMinute,
      );
    } else {
      initialTime = const TimeOfDay(hour: 9, minute: 0);
    }

    final t = await showTimePicker(
      context: context,
      initialTime: initialTime,
      helpText: l10n.visitorApplyVisitTime,
    );
    if (t == null) return;
    if (!mounted) return;

    final picked = ChinaDateTime.wallTime(
      year: d.year,
      month: d.month,
      day: d.day,
      hour: t.hour,
      minute: t.minute,
    );

    // 校验 1：组合时间必须在未来（防 pickTime 跨过零点等边界情况）。
    if (!picked.isAfter(now)) {
      setState(() {
        _visitTime = null;
        _error = l10n.visitorApplyValidateVisitTimeFuture;
      });
      return;
    }

    // 校验 2：与该访客已有 active 申请同时段冲突检查（pending/hostReviewing/
    // approved/checkedIn；rejected/cancelled 不算）。
    late final List<VisitorApplication> myApps;
    try {
      myApps = await ref.read(visitorRepositoryProvider).activeApplications();
    } catch (_) {
      if (mounted) {
        setState(() => _error = l10n.commonError);
      }
      return;
    }
    if (!mounted) return;
    if (_hasConflictWithActive(picked, myApps)) {
      setState(() {
        _visitTime = null;
        _error = l10n.visitorApplyDuplicateTime;
      });
      return;
    }

    setState(() {
      _visitTime = picked;
      _error = null;
    });
  }

  bool _isSameDay(DateTime a, DateTime b) =>
      a.year == b.year && a.month == b.month && a.day == b.day;

  bool _hasConflictWithActive(DateTime picked, List<VisitorApplication> apps) {
    const active = <VisitorApplicationStatus>{
      VisitorApplicationStatus.pending,
      VisitorApplicationStatus.hostReviewing,
      VisitorApplicationStatus.approved,
      VisitorApplicationStatus.checkedIn,
    };
    for (final a in apps) {
      if (!active.contains(a.status)) continue;
      final existing = a.plannedVisitAt.isUtc
          ? ChinaDateTime.fromInstant(a.plannedVisitAt)
          : ChinaDateTime.asWallTime(a.plannedVisitAt);
      if (ChinaDateTime.sameWallMinute(existing, picked)) {
        return true;
      }
    }
    return false;
  }

  Future<void> _submit() async {
    final l10n = AppLocalizations.of(context);
    if (_nameCtl.text.trim().isEmpty) {
      setState(() => _error = l10n.visitorApplyValidateName);
      return;
    }
    final idCard = _idCardCtl.text.trim();
    if (idCard.isNotEmpty && !IdCardUtils.isValid(idCard)) {
      setState(() => _error = l10n.visitorApplyValidateIdCard);
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
        'idCardNo': idCard.isEmpty ? null : idCard.toUpperCase(),
        'company': _companyCtl.text.trim().isEmpty
            ? null
            : _companyCtl.text.trim(),
        'visitPurpose': _purposeCtl.text.trim(),
        'hasVehicle': _hasVehicle,
        'plateNo': _hasVehicle ? _plateCtl.text.trim() : null,
        'hostEmployeeId': _hostId,
        'hostDepartmentId': _deptId,
        'plannedVisitAt': ChinaDateTime.wallTimeToUtc(
          _visitTime!,
        ).toIso8601String(),
      });
      if (!mounted) return;
      context.appSuccess(l10n.visitorApplySuccess);
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
    // 接待部门树（访客 token 目录接口，经 treeOverride 喂给共享部门选择器）。
    final deptTree = ref.watch(visitorDirectoryDepartmentTreeProvider);

    return Scaffold(
      appBar: UtenAppBar(title: l10n.visitorApplyTitle, showBackButton: true),
      body: Column(
        children: [
          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.symmetric(vertical: UtenSpacing.s16),
              // 表单窄收敛（全断点）：水平 gutter 由容器提供
              child: UtenContentContainer.narrow(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    UtenCard(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          UtenSectionHeader(
                            title: l10n.visitorApplyTitle,
                            icon: Icons.person_rounded,
                          ),
                          const SizedBox(height: UtenSpacing.s12),
                          UtenInput(
                            controller: _nameCtl,
                            label: l10n.visitorApplyName,
                            required: true,
                            hint: l10n.visitorApplyNameHint,
                            autofillHints: const [AutofillHints.name],
                          ),
                          const SizedBox(height: UtenSpacing.s12),
                          UtenInput(
                            controller: _idCardCtl,
                            label: l10n.visitorApplyIdCard,
                            hint: l10n.visitorApplyIdCardHint,
                            inputFormatters: ChinaInputFormatters.residentId,
                            textCapitalization: TextCapitalization.characters,
                          ),
                          const SizedBox(height: UtenSpacing.s12),
                          UtenInput(
                            controller: _companyCtl,
                            label: l10n.visitorApplyCompany,
                            hint: l10n.visitorApplyCompanyHint,
                          ),
                          const SizedBox(height: UtenSpacing.s12),
                          UtenInput(
                            controller: _purposeCtl,
                            label: l10n.visitorApplyPurpose,
                            required: true,
                            hint: l10n.visitorApplyPurposeHint,
                            maxLines: 3,
                          ),
                          const SizedBox(height: UtenSpacing.s8),
                          SwitchListTile(
                            contentPadding: EdgeInsets.zero,
                            title: Text(l10n.visitorApplyVehicle),
                            value: _hasVehicle,
                            onChanged: (v) => setState(() => _hasVehicle = v),
                          ),
                          if (_hasVehicle) ...[
                            UtenInput(
                              controller: _plateCtl,
                              label: l10n.visitorApplyPlate,
                              hint: l10n.visitorApplyPlateHint,
                            ),
                            const SizedBox(height: UtenSpacing.s12),
                          ],
                        ],
                      ),
                    ),
                    const SizedBox(height: UtenSpacing.s16),
                    UtenCard(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          UtenSectionHeader(
                            title: l10n.visitorDetailHost,
                            icon: Icons.people_outline_rounded,
                          ),
                          const SizedBox(height: UtenSpacing.s12),
                          UtenDepartmentPicker(
                            mode: UtenDepartmentPickerMode.single,
                            treeOverride: deptTree.valueOrNull ?? const [],
                            enabled: deptTree.hasValue,
                            label: l10n.visitorApplyDept,
                            hint: '请选择接待部门',
                            onChanged: (sel) => setState(() {
                              // 换部门后接待人候选变化，清空已选接待人。
                              _deptId = sel.isEmpty ? null : sel.first.id;
                              _deptName = sel.isEmpty ? null : sel.first.name;
                              _hostId = null;
                            }),
                          ),
                          const SizedBox(height: UtenSpacing.s12),
                          UtenEmployeePicker(
                            // 部门变化时重建，清空已选接待人（与 _deptId 联动）。
                            key: ValueKey(_deptId),
                            loader: (kw) async {
                              final list = await ref
                                  .read(visitorRepositoryProvider)
                                  .directoryEmployees(
                                    departmentId: _deptId,
                                    keyword: kw,
                                  );
                              return [
                                for (final e in list)
                                  UtenEmployeePickerItem(
                                    id: e.id,
                                    name: e.name,
                                    departmentName: e.departmentName,
                                  ),
                              ];
                            },
                            label: l10n.visitorApplyHost,
                            required: true,
                            hint: '请选择被访人',
                            sheetTitle: '选择被访人',
                            departmentName: _deptName,
                            onChanged: (item) =>
                                setState(() => _hostId = item?.id),
                          ),
                          const SizedBox(height: UtenSpacing.s12),
                          InkWell(
                            onTap: _pickTime,
                            child: InputDecorator(
                              decoration: applyRequiredEmpty(
                                InputDecoration(
                                  label: requiredLabel(
                                    l10n.visitorApplyVisitTime,
                                    theme,
                                    required: true,
                                    base: theme.inputDecorationTheme.labelStyle,
                                  ),
                                  prefixIcon: Icon(
                                    Icons.event_rounded,
                                    size: context.scaled(20),
                                  ),
                                ),
                                theme,
                                requiredEmpty: _visitTime == null,
                              ),
                              child: Text(
                                _visitTime == null
                                    ? l10n.visitorApplyVisitTime
                                    : '${ChinaDateTime.formatDateTime(_visitTime!)}（北京）',
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                    if (_error != null) ...[
                      const SizedBox(height: UtenSpacing.s12),
                      Container(
                        padding: const EdgeInsets.all(UtenSpacing.s12),
                        decoration: BoxDecoration(
                          color: UtenColors.error.withValues(alpha: 0.12),
                          borderRadius: UtenRadius.mdAll,
                        ),
                        child: Row(
                          children: [
                            const Icon(
                              Icons.error_outline,
                              color: UtenColors.error,
                              size: 18,
                            ),
                            const SizedBox(width: UtenSpacing.s8),
                            Expanded(
                              child: Text(
                                _error!,
                                style: theme.textTheme.bodySmall?.copyWith(
                                  color: UtenColors.error,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                    const SizedBox(height: UtenSpacing.s16),
                  ],
                ),
              ),
            ),
          ),
          UtenBottomActionBar(
            child: UtenButton(
              onPressed: _submitting ? null : _submit,
              isLoading: _submitting,
              isExpanded: true,
              size: UtenButtonSize.large,
              child: Text(
                _submitting
                    ? l10n.visitorApplySubmitting
                    : l10n.visitorApplySubmit,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
