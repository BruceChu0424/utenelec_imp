import 'package:flutter/material.dart';

/// Compatibility boundary for existing callers. Lists expose one continuous
/// authorized result; backend paging is owned by the data reader.
class UtenPagination extends StatelessWidget {
  const UtenPagination({
    super.key,
    required this.currentPage,
    required this.totalPages,
    this.onPageChanged,
    this.onPrevious,
    this.onNext,
    this.busy = false,
    this.maxPage,
    this.previousKey = const ValueKey('master-table-page-previous'),
    this.nextKey = const ValueKey('master-table-page-next'),
    this.inputOutlineKey,
    this.controller,
    this.focusNode,
  });
  final int currentPage;
  final int? totalPages;
  final ValueChanged<int>? onPageChanged;
  final VoidCallback? onPrevious, onNext;
  final bool busy;
  final int? maxPage;
  final Key? previousKey, nextKey, inputOutlineKey;
  final TextEditingController? controller;
  final FocusNode? focusNode;

  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}
