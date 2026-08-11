/// Tracks overlapping read requests so only the newest request may publish UI
/// state.
///
/// Starting a request invalidates every earlier generation. Callers should
/// check [isCurrent] before writing data, errors, pagination, or loading state.
/// This deliberately does not cancel or retry requests; repositories remain
/// responsible for transport policy, and mutating requests must not use it.
class LatestRequestGuard {
  int _generation = 0;

  int begin() => ++_generation;

  bool isCurrent(int generation) => generation == _generation;
}
