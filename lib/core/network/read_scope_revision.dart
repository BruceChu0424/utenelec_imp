import 'package:flutter_riverpod/legacy.dart';

/// Scope changes retire derived reads without logging out or changing grants.
final readScopeRevisionProvider = StateProvider<int>((ref) => 0);
