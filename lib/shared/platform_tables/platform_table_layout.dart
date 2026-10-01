import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../providers/uten_page_prefs_notifier.dart';
import '../providers/authenticated_scope_provider.dart';
import 'platform_table_models.dart';

String platformTableFingerprint(String value) =>
    sha256.convert(utf8.encode(value)).toString().substring(0, 32);

class PlatformTableLayout {
  const PlatformTableLayout({
    this.order = const [],
    this.hidden = const {},
    this.pinned = const {},
    this.widths = const {},
    this.added = const [],
    this.sourceInstance,
    this.filters = const {},
    this.sortColumn,
    this.sortAscending = true,
    this.hasQueryPreferences = false,
  });
  final List<String> order;
  final Set<String> hidden;
  final Set<String> pinned;
  final Map<String, double> widths;
  final List<PlatformColumnDefinition> added;
  final int? sourceInstance;
  final Map<String, String?> filters;
  final String? sortColumn;
  final bool sortAscending;
  final bool hasQueryPreferences;
  factory PlatformTableLayout.fromJson(Map<String, dynamic> json) =>
      PlatformTableLayout(
        order: (json['order'] as List? ?? []).whereType<String>().toList(),
        filters: {
          for (final entry
              in (json['filters'] as Map? ?? const {}).entries.take(64))
            if (entry.key is String &&
                (entry.key as String).length <= 256 &&
                (entry.value == null ||
                    entry.value is String &&
                        (entry.value as String).length <= 1000))
              entry.key as String: entry.value as String?,
        },
        sortColumn:
            json['sortColumn'] is String &&
                (json['sortColumn'] as String).length <= 256
            ? json['sortColumn'] as String
            : null,
        sortAscending: json['sortAscending'] != false,
        hasQueryPreferences: json['hasQueryPreferences'] == true,
        hidden: (json['hidden'] as List? ?? []).whereType<String>().toSet(),
        pinned: (json['pinned'] as List? ?? []).whereType<String>().toSet(),
        widths: {
          for (final entry in (json['widths'] as Map? ?? {}).entries)
            if (entry.value is num &&
                (entry.value as num).isFinite &&
                (entry.value as num) >= 48 &&
                (entry.value as num) <= 2000)
              entry.key.toString(): (entry.value as num).toDouble(),
        },
        added: [
          for (final entry in json['added'] as List? ?? [])
            if (entry is Map)
              PlatformColumnDefinition.fromJson(
                Map<String, dynamic>.from(entry),
              ),
        ].take(32).toList(),
      );
  Map<String, dynamic> toJson() => {
    'order': order,
    'hidden': hidden.toList(),
    'pinned': pinned.toList(),
    'widths': widths,
    'added': added
        .map(
          (d) => d.scope.isEmpty
              ? d.toJson()
              : ({...d.toJson()}..remove('formula')),
        )
        .toList(),
    'filters': filters,
    'sortColumn': sortColumn,
    'sortAscending': sortAscending,
    'hasQueryPreferences': hasQueryPreferences,
  };
  PlatformTableLayout copyWith({
    List<String>? order,
    Set<String>? hidden,
    Set<String>? pinned,
    Map<String, double>? widths,
    List<PlatformColumnDefinition>? added,
    int? sourceInstance,
    Map<String, String?>? filters,
    String? sortColumn,
    bool clearSort = false,
    bool? sortAscending,
    bool? hasQueryPreferences,
  }) => PlatformTableLayout(
    order: order ?? this.order,
    hidden: hidden ?? this.hidden,
    pinned: pinned ?? this.pinned,
    widths: widths ?? this.widths,
    added: added ?? this.added,
    sourceInstance: sourceInstance ?? this.sourceInstance,
    filters: filters ?? this.filters,
    sortColumn: clearSort ? null : sortColumn ?? this.sortColumn,
    sortAscending: sortAscending ?? this.sortAscending,
    hasQueryPreferences: hasQueryPreferences ?? this.hasQueryPreferences,
  );
}

class PlatformTableLayoutNotifier
    extends UtenPagePrefsNotifier<PlatformTableLayout> {
  PlatformTableLayoutNotifier(this.tableKey);
  final String tableKey;
  @override
  String get cacheKey {
    final scope = ref.read(authenticatedScopeProvider);
    return 'page_prefs_cache_${prefKey}_${scope?.userId ?? "anonymous"}_${scope?.actorId ?? "self"}';
  }

  @override
  PlatformTableLayout build() {
    ref.listen(authenticatedScopeProvider, (previous, next) {
      if (previous != next) state = defaultValue;
    });
    return super.build();
  }

  @override
  String get prefKey => 'platform.table.${platformTableFingerprint(tableKey)}';
  @override
  PlatformTableLayout get defaultValue => const PlatformTableLayout();
  @override
  PlatformTableLayout? decode(Object? raw) => raw is Map
      ? PlatformTableLayout.fromJson(Map<String, dynamic>.from(raw))
      : null;
  @override
  Object? encode(PlatformTableLayout value) => value.toJson();
}

final _layoutProviders =
    <
      String,
      NotifierProvider<PlatformTableLayoutNotifier, PlatformTableLayout>
    >{};
NotifierProvider<PlatformTableLayoutNotifier, PlatformTableLayout>
platformTableLayoutProvider(String tableKey) => _layoutProviders.putIfAbsent(
  tableKey,
  () => NotifierProvider<PlatformTableLayoutNotifier, PlatformTableLayout>(
    () => PlatformTableLayoutNotifier(tableKey),
  ),
);
