import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import 'package:uuid/uuid.dart';

import '../../../components/buttons/uten_button.dart';
import '../../../components/feedback/uten_dialog.dart';
import '../../../components/feedback/uten_empty.dart';
import '../../../components/inputs/uten_employee_picker.dart';
import '../../../components/inputs/uten_input.dart';
import '../../../components/layout/uten_app_bar.dart';
import '../../../components/layout/uten_bottom_action_bar.dart';
import '../../../components/layout/uten_content_container.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../core/ui/app_notification.dart';
import '../../../core/utils/china_datetime.dart';
import '../../../shared/handover/data_handover_models.dart';
import '../../../shared/handover/data_handover_preview_card.dart';
import '../../../shared/handover/data_handover_repository.dart';
import '../models/employee_api_models.dart';
import '../repositories/employee_repository.dart';

enum StableResignType {
  voluntary('VOLUNTARY', '主动离职'),
  dismissed('DISMISSED', '辞退'),
  contractEnd('CONTRACT_END', '合同到期'),
  retire('RETIRE', '退休');

  const StableResignType(this.code, this.label);
  final String code;
  final String label;
}

class EmployeeOffboardingWorkflowPage extends ConsumerStatefulWidget {
  const EmployeeOffboardingWorkflowPage({super.key, required this.employeeId});

  final String employeeId;

  @override
  ConsumerState<EmployeeOffboardingWorkflowPage> createState() =>
      _EmployeeOffboardingWorkflowPageState();
}

class _EmployeeOffboardingWorkflowPageState
    extends ConsumerState<EmployeeOffboardingWorkflowPage> {
  static const _handoverReasonDefault = '员工离职数据交接与责任移交';
  static const _recoveryItems = <({String code, String label})>[
    (code: 'ACCESS_CARD_RETURNED', label: '已线下确认门禁卡回收'),
    (code: 'COMPANY_ASSETS_ACCOUNTED', label: '已线下确认公司资产已清点并完成回收安排'),
    (code: 'ACCOUNT_DISABLE_ACKNOWLEDGED', label: '已知悉：交接与离职事务成功后系统自动停用账号'),
    (code: 'SOCIAL_BENEFITS_ARRANGED', label: '已线下确认社保公积金停缴安排'),
  ];

  final _departureFormKey = GlobalKey<FormState>();
  final _handoverFormKey = GlobalKey<FormState>();
  final _reasonController = TextEditingController();
  final _handoverReasonController = TextEditingController(
    text: _handoverReasonDefault,
  );
  final _requestId = const Uuid().v4();
  final _checks = List<bool>.filled(_recoveryItems.length, false);

  int _step = 0;
  bool _loading = true;
  bool _submitting = false;
  bool _previewLoading = false;
  bool _showDepartureErrors = false;
  int _previewRequestSerial = 0;
  String? _loadError;
  String? _previewError;
  EmployeeProfile? _employee;
  DateTime? _effectiveDate;
  StableResignType _resignType = StableResignType.voluntary;
  UtenEmployeePickerItem? _successor;
  DataHandoverPreview? _preview;

  bool get _dirty =>
      _effectiveDate != null ||
      _resignType != StableResignType.voluntary ||
      _reasonController.text.trim().isNotEmpty ||
      _successor != null ||
      _handoverReasonController.text.trim() != _handoverReasonDefault ||
      _checks.any((checked) => checked);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  @override
  void dispose() {
    _reasonController.dispose();
    _handoverReasonController.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _loadError = null;
    });
    try {
      final results = await Future.wait<Object>([
        ref.read(employeeRepositoryProvider).getById(widget.employeeId),
        ref
            .read(dataHandoverRepositoryProvider)
            .employeePreview(widget.employeeId),
      ]);
      if (!mounted) return;
      setState(() {
        _employee = results[0] as EmployeeProfile;
        _preview = results[1] as DataHandoverPreview;
      });
    } on ApiException catch (error) {
      if (mounted) setState(() => _loadError = error.message);
    } catch (_) {
      if (mounted) setState(() => _loadError = '离职资料加载失败，请重试');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _loadPreview() async {
    final successorId = _successor?.id;
    final request = ++_previewRequestSerial;
    setState(() {
      _previewLoading = true;
      _previewError = null;
    });
    try {
      final preview = await ref
          .read(dataHandoverRepositoryProvider)
          .employeePreview(widget.employeeId, successorEmployeeId: successorId);
      if (mounted &&
          request == _previewRequestSerial &&
          _successor?.id == successorId) {
        setState(() => _preview = preview);
      }
    } on ApiException catch (error) {
      if (mounted && request == _previewRequestSerial) {
        setState(() => _previewError = error.message);
      }
    } catch (_) {
      if (mounted && request == _previewRequestSerial) {
        setState(() => _previewError = '数据盘点失败，请重试');
      }
    } finally {
      if (mounted && request == _previewRequestSerial) {
        setState(() => _previewLoading = false);
      }
    }
  }

  Future<List<UtenEmployeePickerItem>> _successorCandidates(
    String? keyword,
  ) async {
    final repository = ref.read(dataHandoverRepositoryProvider);
    final rows = <DataHandoverCandidate>[];
    var page = 1;
    var total = 1;
    do {
      final result = await repository.candidates(
        role: DataHandoverCandidateRole.target,
        page: page,
        query: keyword,
      );
      rows.addAll(result.items);
      total = result.total;
      page++;
    } while (rows.length < total && page <= 25);
    return rows
        .where((employee) => employee.employeeId != widget.employeeId)
        .map(
          (employee) => UtenEmployeePickerItem(
            id: employee.employeeId,
            name: employee.name,
            departmentName: [
              if (employee.departmentName?.isNotEmpty == true)
                employee.departmentName!,
              '工号 ${employee.code}',
              _employeeStatusLabel(employee.status),
            ].join(' · '),
          ),
        )
        .toList(growable: false);
  }

  Future<void> _changeSuccessor(UtenEmployeePickerItem? successor) async {
    setState(() => _successor = successor);
    await _loadPreview();
  }

  Future<void> _next() async {
    switch (_step) {
      case 0:
        setState(() => _showDepartureErrors = true);
        if (!(_departureFormKey.currentState?.validate() ?? false) ||
            _effectiveDate == null) {
          return;
        }
        setState(() => _step = 1);
      case 1:
        if (_preview == null || _preview!.targetEmployeeId != _successor?.id) {
          await _loadPreview();
        }
        if (!mounted || _previewError != null) return;
        if (!(_handoverFormKey.currentState?.validate() ?? false)) return;
        if (_preview!.requiresTarget && _successor == null) {
          context.appError('仍有责任数据，请选择一名在册接手人');
          return;
        }
        if (_preview!.requiresTarget &&
            _handoverReasonController.text.trim().isEmpty) {
          context.appError('请填写数据交接原因');
          return;
        }
        setState(() => _step = 2);
      case 2:
        final preview = _preview;
        if (preview == null || _previewLoading) return;
        if (preview.hasBlockers) {
          context.appError('请先处理红色阻塞项，再刷新盘点');
          return;
        }
        if (preview.requiresTarget && _successor == null) {
          context.appError('请选择接手人');
          return;
        }
        setState(() => _step = 3);
      case 3:
        if (!_checks.every((checked) => checked)) {
          context.appError('请完成全部线下回收确认');
          return;
        }
        await _submit();
    }
  }

  Future<void> _submit() async {
    final preview = _preview!;
    final confirmed = await UtenDialog.show(
      context,
      title: '确认完成离职办理？',
      content: Text(
        '员工：${_employee?.fullName ?? '—'}\n'
        '离职日期：${DateFormat('yyyy-MM-dd').format(_effectiveDate!)}\n'
        '默认接手人：${_successor?.name ?? '无需交接'}\n'
        '影响项次（分类合计）：${preview.total}\n\n'
        '只有交接和离职事务全部成功后，账号才会停用。',
      ),
      confirmLabel: '确认办理离职',
      danger: true,
    );
    if (!mounted || confirmed != true) return;

    setState(() => _submitting = true);
    try {
      await ref.read(employeeRepositoryProvider).offboard(widget.employeeId, {
        'requestId': _requestId,
        'resignType': _resignType.code,
        'effectiveDate': DateFormat('yyyy-MM-dd').format(_effectiveDate!),
        'reason': _reasonController.text.trim(),
        'confirmedChecklistCodes': [
          for (var index = 0; index < _checks.length; index++)
            if (_checks[index]) _recoveryItems[index].code,
        ],
        if (_successor != null) ...{
          'successorEmployeeId': _successor!.id,
          'handoverReason': _handoverReasonController.text.trim(),
        },
      });
      if (!mounted) return;
      context.appSuccess('离职办理及数据交接已完成');
      context.go('/employee/${widget.employeeId}');
    } on ApiException catch (error) {
      if (!mounted) return;
      if (error.code == 'CONFLICT') {
        context.appError('${error.message}；已返回数据盘点，请核对最新状态');
        setState(() => _step = 2);
        await _loadPreview();
      } else {
        context.appApiError(error, fallback: '离职办理失败，未停用账号');
      }
    } catch (_) {
      if (mounted) context.appError('离职办理失败，未停用账号，请重试');
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  Future<void> _backOrClose() async {
    if (_step > 0) {
      setState(() => _step--);
      return;
    }
    if (_dirty) {
      final discard = await UtenDialog.show(
        context,
        title: '放弃离职办理草稿？',
        content: const Text('当前填写的离职和交接内容尚未保存。'),
        confirmLabel: '放弃并离开',
        danger: true,
      );
      if (!mounted || discard != true) return;
    }
    context.pop();
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    if (_loadError != null || _employee == null) {
      return Scaffold(
        appBar: UtenAppBar(
          title: '离职办理',
          leading: IconButton(
            tooltip: '返回',
            onPressed: _backOrClose,
            icon: const Icon(Icons.arrow_back_rounded),
          ),
        ),
        body: UtenEmpty.error(
          message: _loadError,
          actionLabel: '重试',
          onAction: _load,
        ),
      );
    }
    return PopScope<void>(
      canPop: !_dirty && !_submitting,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) unawaited(_backOrClose());
      },
      child: Scaffold(
        appBar: UtenAppBar(
          title: '离职办理',
          subtitle: '${_employee!.fullName ?? '未命名员工'} · ${_employee!.code}',
          leading: IconButton(
            tooltip: '返回',
            onPressed: _submitting ? null : _backOrClose,
            icon: const Icon(Icons.arrow_back_rounded),
          ),
        ),
        body: UtenContentContainer.narrow(
          child: Column(
            children: [
              _identityCard(),
              Expanded(
                child: Stepper(
                  currentStep: _step,
                  controlsBuilder: (_, _) => const SizedBox.shrink(),
                  onStepTapped: (step) {
                    if (step < _step) setState(() => _step = step);
                  },
                  steps: _steps(),
                ),
              ),
            ],
          ),
        ),
        bottomNavigationBar: UtenBottomActionBar(
          child: Wrap(
            alignment: WrapAlignment.end,
            spacing: UtenSpacing.s8,
            runSpacing: UtenSpacing.s8,
            children: [
              if (_step > 0)
                UtenButton(
                  type: UtenButtonType.secondary,
                  onPressed: _submitting ? null : _backOrClose,
                  child: const Text('上一步'),
                ),
              UtenButton(
                key: const ValueKey('employee-offboarding-next'),
                type: _step == 3
                    ? UtenButtonType.danger
                    : UtenButtonType.primary,
                isLoading: _submitting || _previewLoading,
                onPressed: _submitting || _previewLoading ? null : _next,
                child: Text(_step == 3 ? '确认办理离职' : '下一步'),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _identityCard() {
    final theme = Theme.of(context);
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.fromLTRB(
        UtenSpacing.s16,
        UtenSpacing.s12,
        UtenSpacing.s16,
        0,
      ),
      padding: const EdgeInsets.all(UtenSpacing.s12),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHigh,
        borderRadius: UtenRadius.mdAll,
      ),
      child: Wrap(
        spacing: UtenSpacing.s16,
        runSpacing: UtenSpacing.s4,
        children: [
          Text(
            _employee!.fullName ?? '未命名员工',
            style: theme.textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.w700,
            ),
          ),
          Text('工号 ${_employee!.code}'),
          Text(_employee!.departmentName ?? '未分配部门'),
          if (_employee!.positionName?.isNotEmpty == true)
            Text(_employee!.positionName!),
        ],
      ),
    );
  }

  List<Step> _steps() => [
    Step(
      title: const Text('1. 离职信息'),
      isActive: _step >= 0,
      state: _step > 0 ? StepState.complete : StepState.indexed,
      content: _departureStep(),
    ),
    Step(
      title: const Text('2. 选择默认接手人'),
      isActive: _step >= 1,
      state: _step > 1 ? StepState.complete : StepState.indexed,
      content: _successorStep(),
    ),
    Step(
      title: const Text('3. 数据盘点'),
      isActive: _step >= 2,
      state: _step > 2 ? StepState.complete : StepState.indexed,
      content: _previewStep(),
    ),
    Step(
      title: const Text('4. 回收与确认'),
      isActive: _step >= 3,
      content: _confirmStep(),
    ),
  ];

  Widget _departureStep() => Form(
    key: _departureFormKey,
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        DropdownButtonFormField<StableResignType>(
          initialValue: _resignType,
          decoration: const InputDecoration(
            labelText: '离职类型',
            border: OutlineInputBorder(),
          ),
          items: [
            for (final type in StableResignType.values)
              DropdownMenuItem(value: type, child: Text(type.label)),
          ],
          onChanged: (value) {
            if (value != null) setState(() => _resignType = value);
          },
        ),
        const SizedBox(height: UtenSpacing.s12),
        Semantics(
          button: true,
          label: '选择离职日期',
          child: InkWell(
            onTap: () async {
              final selected = await showDatePicker(
                context: context,
                initialDate: _effectiveDate ?? ChinaDateTime.today(),
                firstDate: DateTime(2020),
                lastDate: ChinaDateTime.today(),
              );
              if (selected != null) {
                setState(() => _effectiveDate = selected);
              }
            },
            borderRadius: UtenRadius.mdAll,
            child: InputDecorator(
              decoration: InputDecoration(
                labelText: '离职日期 *',
                border: const OutlineInputBorder(),
                errorText: _showDepartureErrors && _effectiveDate == null
                    ? '请选择离职日期'
                    : null,
              ),
              child: Text(
                _effectiveDate == null
                    ? '请选择日期'
                    : DateFormat('yyyy-MM-dd').format(_effectiveDate!),
              ),
            ),
          ),
        ),
        const SizedBox(height: UtenSpacing.s12),
        UtenInput(
          controller: _reasonController,
          label: '离职原因',
          hint: '请填写真实原因，任职历史将保留该说明',
          required: true,
          maxLines: 3,
          inputFormatters: [LengthLimitingTextInputFormatter(2000)],
          validator: (value) =>
              value?.trim().isEmpty != false ? '请填写离职原因' : null,
        ),
      ],
    ),
  );

  Widget _successorStep() {
    final noData = _preview != null && !_preview!.requiresTarget;
    return Form(
      key: _handoverFormKey,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            noData
                ? '当前没有需要移交的责任数据，可不选择默认接手人。'
                : '选择一名在册员工默认承接尚未交接的责任；已有分模块接手关系保留，历史操作人保持不变。',
          ),
          const SizedBox(height: UtenSpacing.s12),
          UtenEmployeePicker(
            key: ValueKey('offboarding-successor-${_successor?.id ?? 'none'}'),
            label: '默认接手人',
            hint: noData ? '无数据，可不选择' : '请选择在册接手人',
            sheetTitle: '选择离职数据默认接手人',
            required: _preview?.requiresTarget == true,
            initial: _successor,
            allowClear: noData,
            loader: _successorCandidates,
            validator: (value) =>
                _preview?.requiresTarget == true && value == null
                ? '仍有责任数据，请选择一名在册默认接手人'
                : null,
            onChanged: (value) => unawaited(_changeSuccessor(value)),
          ),
          if (_preview?.requiresTarget == true) ...[
            const SizedBox(height: UtenSpacing.s12),
            UtenInput(
              controller: _handoverReasonController,
              label: '数据交接原因',
              hint: '说明本次交接目的和责任安排',
              required: true,
              maxLines: 3,
              inputFormatters: [LengthLimitingTextInputFormatter(2000)],
              validator: (value) =>
                  value?.trim().isEmpty != false ? '请填写数据交接原因' : null,
            ),
          ],
          if (_previewError != null) ...[
            const SizedBox(height: UtenSpacing.s8),
            UtenEmpty.error(
              message: _previewError,
              actionLabel: '重试盘点',
              onAction: _loadPreview,
            ),
          ],
        ],
      ),
    );
  }

  Widget _previewStep() {
    if (_previewLoading) {
      return const Padding(
        padding: EdgeInsets.all(UtenSpacing.s24),
        child: Center(child: CircularProgressIndicator()),
      );
    }
    if (_previewError != null || _preview == null) {
      return UtenEmpty.error(
        message: _previewError ?? '尚未完成数据盘点',
        actionLabel: '重新盘点',
        onAction: _loadPreview,
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Align(
          alignment: Alignment.centerRight,
          child: UtenButton(
            type: UtenButtonType.secondary,
            icon: Icons.refresh_rounded,
            onPressed: _loadPreview,
            child: const Text('刷新盘点'),
          ),
        ),
        const SizedBox(height: UtenSpacing.s8),
        DataHandoverPreviewCard(preview: _preview!),
      ],
    );
  }

  Widget _confirmStep() {
    final preview = _preview!;
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          padding: const EdgeInsets.all(UtenSpacing.s12),
          decoration: BoxDecoration(
            color: theme.colorScheme.surfaceContainerHighest,
            borderRadius: UtenRadius.mdAll,
          ),
          child: Text(
            '影响摘要：${preview.total} 项次（分类合计）；默认接手人 ${_successor?.name ?? '无需交接'}。'
            '以下确认会随离职命令提交并写入任职历史；只有交接和离职事务全部成功后，'
            '系统账号才会自动停用。',
            style: theme.textTheme.bodySmall?.copyWith(height: 1.5),
          ),
        ),
        const SizedBox(height: UtenSpacing.s8),
        for (var index = 0; index < _checks.length; index++)
          CheckboxListTile(
            value: _checks[index],
            title: Text(_recoveryItems[index].label),
            contentPadding: EdgeInsets.zero,
            controlAffinity: ListTileControlAffinity.leading,
            onChanged: _submitting
                ? null
                : (value) => setState(() => _checks[index] = value ?? false),
          ),
      ],
    );
  }
}

String _employeeStatusLabel(String? status) => switch (status) {
  'active' => '在职',
  'probation' => '试用',
  'onLeave' => '休假',
  _ => status ?? '状态未知',
};
