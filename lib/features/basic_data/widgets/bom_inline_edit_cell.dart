import 'dart:async';

import 'package:flutter/material.dart';

import '../../../components/inputs/uten_inline_edit_cell.dart';
import '../../../components/inputs/uten_input_decoration.dart';
import '../../../components/inputs/uten_table_cell_spec.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/theme/uten_tokens.dart';

/// Assembly and comparison share the same activation, focus and input theme.
class BomTableInput extends StatelessWidget {
  const BomTableInput({super.key, required this.child});
  final Widget child;
  @override
  Widget build(BuildContext context) =>
      SelectionContainer.disabled(child: UtenTableCellInputTheme(child: child));
}

class BomInlineEditCell extends StatelessWidget {
  const BomInlineEditCell({
    super.key,
    required this.label,
    required this.preview,
    required this.editorBuilder,
    required this.enabled,
    this.activationKey,
    this.changed = false,
    this.retainFocusWhenDisabled = false,
    this.onActivate,
  });
  final String label;
  final Widget preview;
  final WidgetBuilder editorBuilder;
  final bool enabled, changed, retainFocusWhenDisabled;
  final Key? activationKey;
  final VoidCallback? onActivate;
  @override
  Widget build(BuildContext context) => BomTableInput(
    child: UtenInlineEditCell(
      semanticLabel: label,
      preview: preview,
      editorBuilder: editorBuilder,
      enabled: enabled,
      activationKey: activationKey,
      changed: changed,
      retainFocusWhenDisabled: retainFocusWhenDisabled,
      onActivate: onActivate,
    ),
  );
}

/// The comparison owns buffers independently of mounted/filtered table rows.
/// Typing is debounced locally; only the existing draft repository is mutated.
class BomLiveEditController extends ChangeNotifier {
  BomLiveEditController({
    required String value,
    required this.apply,
    required this.isCurrent,
    required this.onStateChanged,
    bool Function(String, String)? equivalent,
  }) : text = TextEditingController(text: value),
       original = value,
       accepted = value,
       _equivalent = equivalent ?? _sameText;
  final TextEditingController text;
  final String original;
  final Future<void> Function(String) apply;
  final bool Function() isCurrent;
  final VoidCallback onStateChanged;
  final bool Function(String, String) _equivalent;
  static bool _sameText(String left, String right) => left == right;
  String accepted;
  String? error;
  bool pending = false;
  bool _closed = false;
  Timer? _timer;
  int _revision = 0;
  bool get changed => text.text != original;

  void change(String value) {
    if (_closed || !isCurrent()) return;
    _revision++;
    error = null;
    pending = value != accepted || _inflight != null;
    _timer?.cancel();
    if (pending) _timer = Timer(const Duration(milliseconds: 250), flush);
    notifyListeners();
    onStateChanged();
  }

  Future<void>? _inflight;
  Future<void> flush() {
    if (_inflight != null) {
      return _inflight!.then((_) async {
        if (!_closed && pending && error == null && isCurrent()) await flush();
      });
    }
    final future = _flush();
    _inflight = future;
    return future.whenComplete(() {
      _inflight = null;
      _timer?.cancel();
      if (!_closed && pending && error == null && isCurrent()) {
        _timer = Timer(Duration.zero, flush);
      }
    });
  }

  Future<void> _flush() async {
    _timer?.cancel();
    if (_closed || !pending || !isCurrent()) return;
    final revision = _revision, value = text.text;
    try {
      await apply(value);
      if (_closed || !isCurrent() || revision != _revision) return;
      accepted = value;
      error = null;
      pending = false;
    } catch (failure) {
      if (_closed || !isCurrent() || revision != _revision) return;
      error = failure is ApiException ? failure.message : '修改未暂存，请重试';
    }
    if (!_closed && isCurrent()) {
      notifyListeners();
      onStateChanged();
    }
  }

  void synchronize(String value) {
    if (_closed ||
        pending ||
        text.text != accepted ||
        _equivalent(value, accepted)) {
      return;
    }
    accepted = value;
    text.value = TextEditingValue(
      text: value,
      selection: TextSelection.collapsed(offset: value.length),
    );
  }

  @override
  void dispose() {
    _closed = true;
    _timer?.cancel();
    text.dispose();
    super.dispose();
  }
}

class BomLiveTextCell extends StatelessWidget {
  const BomLiveTextCell({
    super.key,
    required this.controller,
    required this.label,
    required this.enabled,
    required this.fieldKey,
    required this.activationKey,
    this.numeric = false,
    this.unit,
    this.foregroundColor,
  });
  final BomLiveEditController controller;
  final String label;
  final bool enabled, numeric;
  final Key fieldKey, activationKey;
  final String? unit;
  final Color? foregroundColor;
  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: controller,
    builder: (context, _) => BomInlineEditCell(
      label: '编辑$label',
      activationKey: activationKey,
      enabled: enabled,
      changed: controller.changed,
      retainFocusWhenDisabled: true,
      preview: Text(
        '${controller.text.text.isEmpty ? "—" : controller.text.text}${unit?.isNotEmpty == true ? " $unit" : ""}',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          color: controller.error != null
              ? Theme.of(context).colorScheme.error
              : foregroundColor,
        ),
      ),
      editorBuilder: (_) => Tooltip(
        message: controller.error ?? label,
        child: TextField(
          key: fieldKey,
          controller: controller.text,
          autofocus: true,
          readOnly: !enabled,
          keyboardType: numeric
              ? const TextInputType.numberWithOptions(decimal: true)
              : TextInputType.text,
          textAlign: numeric ? TextAlign.end : TextAlign.start,
          style: Theme.of(
            context,
          ).textTheme.bodyMedium?.copyWith(color: foregroundColor),
          decoration: UtenInputDecoration(
            InputDecoration(
              isDense: true,
              suffixText: unit,
              enabledBorder: controller.error == null
                  ? null
                  : OutlineInputBorder(
                      borderRadius: UtenRadius.smAll,
                      borderSide: BorderSide(
                        color: Theme.of(context).colorScheme.error,
                      ),
                    ),
              focusedBorder: controller.error == null
                  ? null
                  : OutlineInputBorder(
                      borderRadius: UtenRadius.smAll,
                      borderSide: BorderSide(
                        color: Theme.of(context).colorScheme.error,
                        width: 1.6,
                      ),
                    ),
            ),
          ),
          onChanged: controller.change,
          onSubmitted: (_) => controller.flush(),
        ),
      ),
    ),
  );
}
