// 检测上传页（Phase 4）
// 文档：docs/03-页面/检测上传页.md

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../components/buttons/uten_button.dart';
import '../../../components/cards/uten_card.dart';
import '../../../components/layout/uten_app_bar.dart';
import '../../../components/layout/uten_bottom_action_bar.dart';
import '../../../components/layout/uten_section_header.dart';
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
      _toast('请填写样品编号、名称、项目和结果');
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
      testDate: DateTime.now(),
      testerName: _tester.text,
    );
    await ref.read(labRepositoryProvider).create(test);
    if (mounted) {
      setState(() => _saving = false);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('检测数据已上传（Mock）')),
      );
      ref.invalidate(labListProvider);
      context.go('/lab/test/${test.id}');
    }
  }

  @override
  Widget build(BuildContext context) {
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
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 720),
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const UtenSectionHeader(title: '样品信息'),
                const SizedBox(height: 8),
                UtenCard(
                  padding: const EdgeInsets.all(12),
                  child: Column(
                    children: [
                      _F(_sampleCode, '样品编号 *'),
                      _F(_sampleName, '样品名称 *'),
                      _F(_project, '检测项目 *'),
                    ],
                  ),
                ),
                const SizedBox(height: 20),
                const UtenSectionHeader(title: '检测结果'),
                const SizedBox(height: 8),
                UtenCard(
                  padding: const EdgeInsets.all(12),
                  child: Column(
                    children: [
                      _F(_result, '检测结果 *'),
                      _F(_standard, '标准值'),
                      SwitchListTile(
                        dense: true,
                        contentPadding: EdgeInsets.zero,
                        title: const Text('合格判定'),
                        value: _qualified,
                        onChanged: (v) => setState(() => _qualified = v),
                      ),
                      _F(_tester, '检测员'),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  void _toast(String msg) =>
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
}

class _F extends StatelessWidget {
  const _F(this.controller, this.label);
  final TextEditingController controller;
  final String label;
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: TextField(
          controller: controller,
          decoration: InputDecoration(
            labelText: label,
            border: const OutlineInputBorder(),
            isDense: true,
          ),
        ),
      );
}
