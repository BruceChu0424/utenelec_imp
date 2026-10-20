import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../components/inputs/uten_input_decoration.dart';
import '../../../core/theme/uten_tokens.dart';
import '../repositories/mould_manufacturer_repository.dart';

/// A free text value with ranked historical suggestions. A new manufacturer
/// remains valid without creating another master or choosing a candidate.
class MouldManufacturerField extends ConsumerStatefulWidget {
  const MouldManufacturerField({
    super.key,
    this.value,
    required this.onChanged,
  });
  final String? value;
  final ValueChanged<String> onChanged;
  @override
  ConsumerState<MouldManufacturerField> createState() =>
      _MouldManufacturerFieldState();
}

class _MouldManufacturerFieldState
    extends ConsumerState<MouldManufacturerField> {
  late final TextEditingController _text = TextEditingController(
    text: widget.value,
  );
  final _focus = FocusNode();
  final _menu = MenuController();
  Timer? _debounce;
  int _generation = 0;
  List<String> _options = const [];
  bool _loading = false;
  bool _failed = false;

  @override
  void initState() {
    super.initState();
    _focus.addListener(_focusChanged);
  }

  @override
  void didUpdateWidget(MouldManufacturerField oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.value != widget.value && widget.value != _text.text) {
      _text.text = widget.value ?? '';
    }
  }

  void _focusChanged() {
    if (_focus.hasFocus) {
      _search(immediate: true);
    } else {
      _generation++;
      _debounce?.cancel();
    }
  }

  void _search({bool immediate = false}) {
    _debounce?.cancel();
    final generation = ++_generation;
    setState(() {
      _loading = true;
      _failed = false;
      _options = const [];
    });
    if (!_menu.isOpen) _menu.open();
    if (immediate) {
      unawaited(_load(generation));
    } else {
      _debounce = Timer(
        const Duration(milliseconds: 280),
        () => _load(generation),
      );
    }
  }

  Future<void> _load(int generation) async {
    final repository = ref.read(mouldManufacturerRepositoryProvider);
    try {
      final values = await repository.suggestions(_text.text);
      if (!mounted ||
          generation != _generation ||
          !identical(
            repository,
            ref.read(mouldManufacturerRepositoryProvider),
          )) {
        return;
      }
      setState(() {
        _options = values;
        _loading = false;
      });
    } catch (_) {
      if (!mounted || generation != _generation) return;
      setState(() {
        _loading = false;
        _failed = true;
      });
    }
  }

  void _choose(String value) {
    _generation++;
    _debounce?.cancel();
    _text.value = TextEditingValue(
      text: value,
      selection: TextSelection.collapsed(offset: value.length),
    );
    widget.onChanged(value);
    _menu.close();
  }

  @override
  void dispose() {
    _generation++;
    _debounce?.cancel();
    _text.dispose();
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(mouldManufacturerRepositoryProvider, (_, _) {
      _generation++;
      _debounce?.cancel();
      _menu.close();
    });
    return LayoutBuilder(
      builder: (context, constraints) => MenuAnchor(
        controller: _menu,
        crossAxisUnconstrained: false,
        style: MenuStyle(
          maximumSize: WidgetStatePropertyAll(Size(constraints.maxWidth, 280)),
        ),
        menuChildren: [
          if (_loading)
            const Padding(
              padding: EdgeInsets.all(UtenSpacing.s12),
              child: LinearProgressIndicator(),
            )
          else if (_failed || _options.isEmpty)
            MenuItemButton(
              child: Text(_failed ? '候选加载失败，仍可直接输入' : '暂无历史候选，可直接输入'),
            )
          else
            for (final value in _options)
              MenuItemButton(
                onPressed: () => _choose(value),
                child: Text(
                  value,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
        ],
        builder: (context, controller, _) => TextField(
          controller: _text,
          focusNode: _focus,
          maxLength: 200,
          onChanged: (value) {
            widget.onChanged(value);
            _search();
          },
          onTap: () {
            if (!controller.isOpen) _search(immediate: true);
          },
          decoration: UtenInputDecoration(
            InputDecoration(
              labelText: '模具制造商',
              hintText: '模具制造商',
              counterText: '',
              suffixIcon: IconButton(
                tooltip: '选择历史制造商',
                icon: const Icon(Icons.arrow_drop_down),
                onPressed: () {
                  _focus.requestFocus();
                  _search(immediate: true);
                },
              ),
            ),
          ),
        ),
      ),
    );
  }
}
