import '../../../core/theme/uten_tokens.dart';
import 'package:uten_imp/components/feedback/uten_dialog.dart';
import 'package:flutter/material.dart';

/// Local, reversible color selection; nothing is published until platform save.
class PlatformColorPickerDialog extends StatefulWidget {
  const PlatformColorPickerDialog({
    super.key,
    required this.title,
    required this.initial,
  });
  final String title;
  final Color initial;
  @override
  State<PlatformColorPickerDialog> createState() => _PlatformColorPickerState();
}

class _PlatformColorPickerState extends State<PlatformColorPickerDialog> {
  late HSVColor _color;
  @override
  void initState() {
    super.initState();
    _color = HSVColor.fromColor(widget.initial);
  }

  String get _hex =>
      '#${(_color.toColor().toARGB32() & 0xFFFFFF).toRadixString(16).padLeft(6, '0').toUpperCase()}';

  @override
  Widget build(BuildContext context) => UtenAlertDialog(
    scrollable: false,
    title: Text('选择${widget.title}'),
    content: SizedBox(
      width: 340,
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              height: 72,
              width: double.infinity,
              decoration: BoxDecoration(
                color: _color.toColor(),
                borderRadius: BorderRadius.circular(UtenRadius.lg),
                border: Border.all(
                  color: Theme.of(context).colorScheme.outline,
                ),
              ),
            ),
            const SizedBox(height: 12),
            SelectableText(
              _hex,
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 16),
            const Text('色相'),
            Slider(
              value: _color.hue,
              max: 360,
              divisions: 360,
              semanticFormatterCallback: (value) => '${value.round()} 度',
              onChanged: (value) =>
                  setState(() => _color = _color.withHue(value)),
            ),
            const Text('饱和度'),
            Slider(
              value: _color.saturation,
              divisions: 100,
              semanticFormatterCallback: (value) => '${(value * 100).round()}%',
              onChanged: (value) =>
                  setState(() => _color = _color.withSaturation(value)),
            ),
            const Text('明度'),
            Slider(
              value: _color.value,
              divisions: 100,
              semanticFormatterCallback: (value) => '${(value * 100).round()}%',
              onChanged: (value) =>
                  setState(() => _color = _color.withValue(value)),
            ),
            Text(
              '深浅模式会自动生成可读的文字和按钮色。',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ),
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('取消'),
      ),
      FilledButton(
        onPressed: () => Navigator.pop(context, _hex),
        child: const Text('使用此颜色'),
      ),
    ],
  );
}
