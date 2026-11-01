import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Saved recipe changes refresh every open view; local drafts keep their own
/// baseline and remain protected by server snapshot checks.
final goodsBomChangesProvider = NotifierProvider<GoodsBomChanges, int>(
  GoodsBomChanges.new,
);

class GoodsBomChanges extends Notifier<int> {
  @override
  int build() => 0;

  void saved() => state++;
}
