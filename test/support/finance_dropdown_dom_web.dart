import 'package:web/web.dart' as web;

const financeDropdownDomAvailable = true;

/// Exercises the web engine's actual DOM click listener, without dispatching a
/// framework semantics action or invoking a widget's callback directly.
void clickFinanceDropdownDomOption(String label) {
  String normalize(String value) =>
      value.replaceAll(RegExp(r'\s+'), ' ').trim();
  final candidates = <web.HTMLElement>[];
  final nodes = web.document.querySelectorAll('flt-semantics[flt-tappable]');
  for (var index = 0; index < nodes.length; index++) {
    final element = nodes.item(index)! as web.HTMLElement;
    if (element.getAttribute('role') != 'button') continue;
    final text = normalize(element.textContent ?? '');
    final aria = normalize(element.getAttribute('aria-label') ?? '');
    if ([
      text,
      aria,
    ].any((value) => value == label || value == '$label $label')) {
      candidates.add(element);
    }
  }
  if (candidates.length != 1) {
    throw StateError(
      'Expected one tappable DOM option, got ${candidates.length}.',
    );
  }
  final option = candidates.single;
  final bounds = option.getBoundingClientRect();
  if (bounds.width <= 0 || bounds.height <= 0) {
    throw StateError('The menu option has no visible DOM bounds.');
  }
  option.click();
}
