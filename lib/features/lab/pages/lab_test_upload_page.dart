// 检测上传页（Phase 4）
// 文档：docs/03-页面/检测上传页.md
//
// 响应式：表单页走窄收敛——compact 自套 UtenContentContainer.narrow；
// medium+ 外壳已收敛，内容再限宽 720 居中。输入框统一为 UtenInput。

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../components/buttons/uten_button.dart';
import '../../../components/cards/uten_card.dart';
import '../../../components/inputs/uten_input.dart';
import '../../../components/layout/uten_app_bar.dart';
import '../../../components/layout/uten_bottom_action_bar.dart';
import '../../../components/layout/uten_content_container.dart';
import '../../../components/layout/uten_section_header.dart';
import '../../../core/responsive/breakpoint.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../core/ui/app_notification.dart';
import '../../../core/utils/china_datetime.dart';
import '../models/lab_test.dart';
import '../providers/lab_providers.dart';

class LabTestUploadPage extends ConsumerStatefulWidget {
  const LabTestUploadPage({super.key});

  @override
  ConsumerState<LabTestUploadPage> createState() => _LabTestUploadPageState();
}

class _LabTestUploadPageState extends ConsumerState<LabTestUploadPage> {
  final _sampleCode = TextEditingController();
  final _sampleName = TextEditingController();
  final _project = TextEditingController();
  final _result = TextEditingController();
  final _standard = TextEditingController();
  final _tester = TextEditingController(text: '赵敏');
  bool _qualified = true;
  bool _saving = false;

  @override
  void dispose() {
    _sampleCode.dispose();
    _sampleName.dispose();
    _project.dispose();
    _result.dispose();
    _standard.dispose();
    _tester.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_sampleCode.text.isEmpty ||
        _sampleName.text.isEmpty ||
        _project.text.isEmpty ||
        _result.text.isEmpty) {
      if (mounted) context.appError('请填写样品编号、名称、项目和结果');
      return;
    }
    setState(() => _saving = true);
    final test = LabTest(
      id: 'lab-${DateTime.now().millisecondsSinceEpoch}',
      sampleCode: _sampleCode.text,
      sampleName: _sampleName.text,
      project: _project.text,
      result: _result.text,
      standard: _standard.text,
      qualified: _qualified,
      testDate: ChinaDateTime.now(),
      testerName: _tester.text,
    );
    await ref.read(labRepositoryProvider).create(test);
    if (mounted) {
      setState(() => _saving = false);
      context.appSuccess('检测数据已上传（Mock）');
      ref.invalidate(labListProvider);
      context.go('/lab/test/${test.id}');
    }
  }

  @override
  Widget build(BuildContext context) {
    final isCompact = context.breakpoint.isCompact;

    Widget form = SingleChildScrollView(
      padding: EdgeInsets.symmetric(
        horizontal: isCompact ? 0 : UtenSpacing.s16,
        vertical: UtenSpacing.s16,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const UtenSectionHeader(title: '样品信息'),
          const SizedBox(height: UtenSpacing.s8),
          UtenCard(
            child: Column(
              children: [
                UtenInput(controller: _sampleCode, label: '样品编号', required: true),
                const SizedBox(height: UtenSpacing.s12),
                UtenInput(controller: _sampleName, label: '样品名称', required: true),
                const SizedBox(height: UtenSpacing.s12),
                UtenInput(controller: _project, label: '检测项目', required: true),
              ],
            ),
          ),
          const SizedBox(height: UtenSpacing.s20),
          const UtenSectionHeader(title: '检测结果'),
          const SizedBox(height: UtenSpacing.s8),
          UtenCard(
            child: Column(
              children: [
                UtenInput(controller: _result, label: '检测结果', required: true),
                const SizedBox(height: UtenSpacing.s12),
                UtenInput(controller: _standard, label: '标准值'),
                SwitchListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  title: const Text('合格判定'),
                  value: _qualified,
                  onChanged: (v) => setState(() => _qualified = v),
                ),
                UtenInput(controller: _tester, label: '检测员'),
              ],
            ),
          ),
        ],
      ),
    );
    if (isCompact) form = UtenContentContainer.narrow(child: form);

    return Scaffold(
      appBar: const UtenAppBar(title: '上传检测数据', showBackButton: true),
      bottomNavigationBar: UtenBottomActionBar(
        child: UtenButton(
          isLoading: _saving,
          isExpanded: true,
          icon: Icons.check_rounded,
          onPressed: _submit,
          child: const Text('提交'),
        ),
      ),
      // medium+：外壳已收敛到 1600，表单再限宽 720 居中
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 720),
          child: form,
        ),
      ),
    );
  }
}
