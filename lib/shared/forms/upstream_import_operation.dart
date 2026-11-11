/// One upstream import owns the picker, enrichment and final append together.
/// A retired operation cannot become current again after an account or document ABA.
class UpstreamImportOperation {
  UpstreamImportOperation(this._check);
  final bool Function() _check;
  bool _retired = false;
  bool get isCurrent {
    if (_retired) return false;
    if (!_check()) _retired = true;
    return !_retired;
  }

  void retire() => _retired = true;
}
