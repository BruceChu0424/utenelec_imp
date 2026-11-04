import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../components/buttons/uten_button.dart';
import '../../components/feedback/uten_dialog.dart';
import '../../components/inputs/uten_dropdown_field.dart';
import '../../components/inputs/uten_input.dart';
import '../../core/network/business_precision.dart';
import '../../core/network/business_precision_coordinator.dart';
import '../../core/router/app_router.dart' show appNavigatorKey;
import '../providers/export_context_epoch_provider.dart';

Future<BusinessPrecisionChoice?> showBusinessPrecisionDialog(
  BuildContext context,
  BusinessPrecisionRequirement requirement, {
  ValueListenable<int>? validity,
  int? expectedValidity,
}) => showDialog<BusinessPrecisionChoice>(
  context: context,
  barrierDismissible: false,
  builder: (_) => BusinessPrecisionDialog(
    requirement: requirement,
    validity: validity,
    expectedValidity: expectedValidity,
  ),
);

class BusinessPrecisionDialog extends StatefulWidget {
  const BusinessPrecisionDialog({
    super.key,
    required this.requirement,
    this.validity,
    this.expectedValidity,
  });
  final BusinessPrecisionRequirement requirement;
  final ValueListenable<int>? validity;
  final int? expectedValidity;
  @override
  State<BusinessPrecisionDialog> createState() =>
      _BusinessPrecisionDialogState();
}

class _BusinessPrecisionDialogState extends State<BusinessPrecisionDialog> {
  final _scale = TextEditingController();
  String? _rounding;
  bool _retired = false;
  bool get _current =>
      !_retired &&
      (widget.validity == null ||
          widget.validity!.value == widget.expectedValidity);
  int? get _value {
    final raw = _scale.text.trim();
    if (!RegExp(r'^\d+$').hasMatch(raw)) {
      return null;
    }
    final value = int.tryParse(raw);
    return value != null && value >= 0 && value <= widget.requirement.maxScale
        ? value
        : null;
  }

  @override
  void initState() {
    super.initState();
    widget.validity?.addListener(_changed);
    _scale.addListener(_changed);
  }

  void _changed() {
    if (widget.validity != null &&
        widget.validity!.value != widget.expectedValidity) {
      _retired = true;
    }
    if (mounted) {
      setState(() {});
    }
  }

  @override
  void dispose() {
    widget.validity?.removeListener(_changed);
    _scale.removeListener(_changed);
    _scale.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => UtenDialogFrame(
    maxWidth: 620,
    child: Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const UtenDialogHeader(title: Text('本次计算精度')),
        Flexible(
          child: SingleChildScrollView(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (!_current)
                    const Text('身份、权限或来源已变化，请关闭后回到原操作。原输入保留。')
                  else ...[
                    Text(widget.requirement.label),
                    if (widget.requirement.selectionRejected) ...[
                      const SizedBox(height: 12),
                      const Text('上次选择未能满足原数量或金额的守恒，请明确重新选择；系统不会自动提高位数或改动原值。'),
                    ],
                    const SizedBox(height: 12),
                    Text(
                      widget.requirement.reason == 'NON_TERMINATING'
                          ? '这项计算除不尽，请明确选择本次保留几位小数及处理方式。'
                          : '这项计算需要明确精度，请选择本次保留几位小数及处理方式。',
                    ),
                    const SizedBox(height: 12),
                    UtenInput(
                      label: '保留小数位数',
                      required: true,
                      controller: _scale,
                      keyboardType: TextInputType.number,
                      info:
                          '可填0至${widget.requirement.maxScale}位，不填写不会自动选择${widget.requirement.suggestedScale == null ? '' : '；建议${widget.requirement.suggestedScale}位仅供参考'}',
                    ),
                    if (_scale.text.isNotEmpty && _value == null)
                      Text(
                        '请填写0至${widget.requirement.maxScale}的整数',
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.error,
                        ),
                      ),
                    const SizedBox(height: 12),
                    UtenDropdownField(
                      label: '处理方式',
                      required: true,
                      value: _rounding,
                      items: const [
                        UtenDropdownItem(value: 'HALF_UP', label: '四舍五入'),
                        UtenDropdownItem(value: 'DOWN', label: '直接截取，不进位'),
                      ],
                      onChanged: (value) => setState(() => _rounding = value),
                    ),
                    const SizedBox(height: 12),
                    const Text('仅用于本次同类计算，原始值按来源保留，不设为全局默认。'),
                  ],
                ],
              ),
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.all(20),
          child: Wrap(
            alignment: WrapAlignment.end,
            spacing: 8,
            runSpacing: 8,
            children: [
              UtenButton(
                type: UtenButtonType.secondary,
                onPressed: () => Navigator.pop(context),
                child: const Text('取消，保留原输入'),
              ),
              UtenButton(
                onPressed: _current && _value != null && _rounding != null
                    ? () => Navigator.pop(
                        context,
                        BusinessPrecisionChoice(_value!, _rounding!),
                      )
                    : null,
                child: const Text('确认本次精度'),
              ),
            ],
          ),
        ),
      ],
    ),
  );
}

/// One nonvisual application host; the choice belongs to the active request,
/// not a saved UI preference. Epoch changes retire both queued and open prompts.
class BusinessPrecisionPromptHost extends ConsumerStatefulWidget {
  const BusinessPrecisionPromptHost({super.key, this.navigatorContext});
  final BuildContext? Function()? navigatorContext;
  @override
  ConsumerState<BusinessPrecisionPromptHost> createState() =>
      _PrecisionHostState();
}

class _PrecisionHostState extends ConsumerState<BusinessPrecisionPromptHost> {
  final _generation = ValueNotifier<int>(0);
  void Function()? _unregister;
  @override
  void initState() {
    super.initState();
    _unregister = BusinessPrecisionCoordinator.instance.register(_prompt);
    ref.listenManual(exportContextEpochProvider, (previous, next) {
      if (previous != next) {
        _generation.value++;
        BusinessPrecisionCoordinator.instance.clear();
      }
    });
  }

  Future<BusinessPrecisionChoice?> _prompt(
    BusinessPrecisionRequirement requirement,
  ) async {
    final context =
        (widget.navigatorContext ?? () => appNavigatorKey.currentContext)();
    if (context == null || !context.mounted) {
      return null;
    }
    final generation = _generation.value;
    final choice = await showBusinessPrecisionDialog(
      context,
      requirement,
      validity: _generation,
      expectedValidity: generation,
    );
    return mounted && generation == _generation.value ? choice : null;
  }

  @override
  void dispose() {
    _unregister?.call();
    _generation.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}
