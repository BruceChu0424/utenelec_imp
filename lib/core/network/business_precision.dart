import 'dart:async';
import 'dart:convert';
import 'api_exception.dart';

const businessPrecisionHeader = 'X-Uten-Precision-Choices';
const businessPrecisionDraftKey = '_businessPrecisionTransport';

class BusinessPrecisionRequirement {
  const BusinessPrecisionRequirement({
    required this.key,
    required this.groupKey,
    required this.label,
    required this.maxScale,
    required this.reason,
    this.suggestedScale,
    this.selectionRejected = false,
  });
  final String key, groupKey, label, reason;
  final int maxScale;
  final int? suggestedScale;
  final bool selectionRejected;
  static BusinessPrecisionRequirement? parse(Object? raw) {
    if (raw is! Map ||
        raw['notWritten'] != true ||
        raw['calculationKey'] is! String ||
        raw['label'] is! String ||
        raw['maxScale'] is! int) {
      return null;
    }
    final key = raw['calculationKey'] as String,
        label = raw['label'] as String,
        max = raw['maxScale'] as int,
        reason = raw['reason'];
    if (key.isEmpty ||
        key.length > 200 ||
        label.isEmpty ||
        label.length > 1000 ||
        max < 0 ||
        max > 30 ||
        !const {'NON_TERMINATING', 'PRECISION_LIMIT'}.contains(reason)) {
      return null;
    }
    return BusinessPrecisionRequirement(
      key: key,
      groupKey: raw['groupKey']?.toString() ?? key,
      label: label,
      maxScale: max,
      reason: reason.toString(),
      selectionRejected: raw['selectionRejected'] == true,
      suggestedScale: raw['suggestedScale'] is int
          ? raw['suggestedScale'] as int
          : null,
    );
  }
}

class BusinessPrecisionChoice {
  const BusinessPrecisionChoice(this.scale, this.rounding);
  final int scale;
  final String rounding;
  Map<String, dynamic> toJson() => {'scale': scale, 'rounding': rounding};
  static BusinessPrecisionChoice? parse(Object? value) {
    if (value is! Map ||
        value['scale'] is! int ||
        !const {'HALF_UP', 'DOWN'}.contains(value['rounding'])) {
      return null;
    }
    final scale = value['scale'] as int;
    if (scale < 0 || scale > 30) {
      return null;
    }
    return BusinessPrecisionChoice(scale, value['rounding'].toString());
  }
}

/// Private per-operation transport metadata. It never contains request bodies,
/// credentials, source amounts or a default choice for another operation.
class BusinessPrecisionTransport {
  BusinessPrecisionTransport({
    this.checkpoint,
    this.isCurrent,
    this.readOnly = false,
  });
  final Future<void> Function()? checkpoint;
  final bool Function()? isCurrent;
  final bool readOnly;
  static final Object _zoneKey = Object();
  static BusinessPrecisionTransport? get current =>
      Zone.current[_zoneKey] as BusinessPrecisionTransport?;
  Future<T> run<T>(Future<T> Function() work) =>
      runZoned(work, zoneValues: {_zoneKey: this});
  final choices = <String, BusinessPrecisionChoice>{};
  final _attempts = <String, Map<String, dynamic>>{};
  bool priorUnknown = false, seenPrecision = false, continuation = false;
  String? _primary;
  bool _firstInRun = true;
  void beginRun({required bool unknown}) {
    priorUnknown = unknown;
    _firstInRun = true;
  }

  bool get currentIdentity => isCurrent?.call() ?? true;
  bool get definitelyUnwritten =>
      seenPrecision &&
      _attempts.isNotEmpty &&
      _attempts.values.every(
        (entry) =>
            entry['uncertain'] != true && entry['completedMutation'] != true,
      ) &&
      _attempts.values.any((entry) => entry['notWritten'] == true);
  bool get canAsk =>
      !priorUnknown &&
      !_attempts.values.any((entry) => entry['uncertain'] == true) &&
      currentIdentity;
  bool get canReselect =>
      canAsk &&
      !_attempts.values.any((entry) => entry['completedMutation'] == true);
  Map<String, dynamic> snapshot() => {
    'version': 1,
    'choices': {
      for (final entry in choices.entries) entry.key: entry.value.toJson(),
    },
    'attempts': {
      for (final entry in _attempts.entries)
        entry.key: Map<String, dynamic>.from(entry.value),
    },
    'primary': _primary,
    'continuation': continuation,
  };
  void restore(Object? value) {
    if (value == null) {
      return;
    }
    if (value is! Map ||
        value['version'] != 1 ||
        value['choices'] is! Map ||
        value['attempts'] is! Map) {
      throw const FormatException('原精度选择的提交资料不完整');
    }
    choices.clear();
    for (final entry in (value['choices'] as Map).entries) {
      final choice = BusinessPrecisionChoice.parse(entry.value);
      if (entry.key is! String || choice == null || choices.length >= 32) {
        throw const FormatException('原精度选择无效');
      }
      choices[entry.key as String] = choice;
    }
    _attempts.clear();
    for (final entry in (value['attempts'] as Map).entries) {
      if (entry.key is! String || entry.value is! Map) {
        throw const FormatException('原精度请求状态无效');
      }
      _attempts[entry.key as String] = Map<String, dynamic>.from(
        entry.value as Map,
      );
    }
    _primary = value['primary']?.toString();
    continuation = value['continuation'] == true;
    seenPrecision = true;
  }

  void clear() {
    choices.clear();
    _attempts.clear();
    _primary = null;
    seenPrecision = false;
    continuation = false;
    priorUnknown = false;
    _firstInRun = true;
  }

  Future<void> _save() async {
    if (!currentIdentity) {
      throw StateError('原精度选择的账号或页面已变化');
    }
    if (seenPrecision) {
      await checkpoint?.call();
    }
  }

  Future<void> dispatch(
    String fingerprint, {
    required bool mutating,
    required String semanticFingerprint,
  }) async {
    if (mutating &&
        priorUnknown &&
        _attempts.values.any((entry) => entry['uncertain'] == true) &&
        !_attempts.containsKey(fingerprint)) {
      throw ApiException(
        'UNKNOWN_REQUEST_CHANGED',
        '原提交结果未知，不能更换原内容或精度；请先核对原请求回执',
        httpStatus: 409,
      );
    }
    if (_firstInRun && !readOnly) {
      if (!priorUnknown &&
          _primary != null &&
          _primary != semanticFingerprint) {
        clear();
      }
      _primary = semanticFingerprint;
      _firstInRun = false;
    }
    final entry = _attempts.putIfAbsent(fingerprint, () => {});
    entry['priorUncertain'] = priorUnknown || entry['uncertain'] == true;
    entry['uncertain'] = mutating;
    entry['notWritten'] = false;
    await _save();
  }

  Future<void> required(
    String fingerprint,
    BusinessPrecisionRequirement requirement,
  ) async {
    seenPrecision = true;
    final entry = _attempts.putIfAbsent(fingerprint, () => {});
    entry['uncertain'] = entry['priorUncertain'] == true;
    entry['notWritten'] = true;
    entry['requiredKey'] = requirement.key;
    entry['selectionRejected'] = requirement.selectionRejected;
    await _save();
  }

  Future<void> rejected(String fingerprint) async {
    final entry = _attempts[fingerprint];
    if (entry != null) {
      entry['uncertain'] = entry['priorUncertain'] == true;
      entry['notWritten'] = true;
    }
    if (seenPrecision) {
      await _save();
    }
  }

  Future<void> select(String key, BusinessPrecisionChoice choice) async {
    choices[key] = choice;
    continuation = false;
    await _save();
  }

  /// A related known-unwritten preview can prepare this operation's next body
  /// without discarding its explicitly chosen policy. Unknown/committed writes
  /// keep their original binding until their matching receipt is acknowledged.
  void prepareRelatedPreview() {
    if (priorUnknown ||
        _attempts.values.any(
          (entry) =>
              entry['uncertain'] == true || entry['completedMutation'] == true,
        )) {
      return;
    }
    _attempts.clear();
    _primary = null;
    _firstInRun = true;
  }

  /// Only after a matching real successful command receipt. A multi-window
  /// operation may retain its own current explicit policy for the next request.
  void advanceConfirmedRequest({bool originalReceiptAcknowledged = false}) {
    if (!originalReceiptAcknowledged &&
        _attempts.values.any((entry) => entry['uncertain'] == true)) {
      throw StateError('原请求结果仍待核对，不能开始下一段');
    }
    _attempts.clear();
    _primary = null;
    priorUnknown = false;
    _firstInRun = true;
  }

  Future<void> holdContinuation() async {
    continuation = true;
    await _save();
  }

  Future<void> completed(String fingerprint, {required bool mutating}) async {
    final entry = _attempts[fingerprint];
    if (entry != null) {
      entry['uncertain'] = false;
      entry['completedMutation'] = mutating;
      entry['notWritten'] = false;
    }
    if (seenPrecision) {
      try {
        await _save();
      } catch (_) {
        /* A local checkpoint cannot turn server success into a duplicate write. */
      }
    }
  }

  String? get encodedHeader => choices.isEmpty
      ? null
      : base64Url.encode(
          utf8.encode(
            jsonEncode({
              'version': 1,
              'choices': {
                for (final entry in choices.entries)
                  entry.key: entry.value.toJson(),
              },
            }),
          ),
        );
}
