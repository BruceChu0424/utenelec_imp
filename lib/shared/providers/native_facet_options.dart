import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/network/api_client.dart';
import '../../features/basic_data/models/master_facet.dart';
import 'export_context_epoch_provider.dart';

import '../../core/network/native_facet_routes.dart';
export '../../core/network/native_facet_routes.dart' show nativeFacetPaths;

Map<String, dynamic> _body(Map<String, dynamic> filters) => Map.unmodifiable({
  for (final entry in filters.entries)
    if (entry.value != null && entry.value != '') entry.key: entry.value,
});

/// Each column searches its complete original authorized fact query, one bounded page at a time.
Map<String, MasterFacetColumnLoader> nativeFacetLoaders(
  WidgetRef ref, {
  required String path,
  required Iterable<String> fields,
  Map<String, dynamic> filters = const {},
}) {
  if (!nativeFacetPaths.contains(path)) throw ArgumentError.value(path, 'path');
  final query = _body(filters);
  return {
    for (final field in fields)
      field: (keyword, page) async {
        final context = ref.context;
        final api = ref.read(apiClientProvider);
        final epoch = ref.read(exportContextEpochProvider);
        final json = await api.postForm(
          path,
          body: {
            ...query,
            '__facetField': field,
            '__facetKeyword': keyword,
            '__facetPage': page,
            '__facetSize': 100,
          },
        );
        if (!context.mounted ||
            epoch != ref.read(exportContextEpochProvider) ||
            !identical(api, ref.read(apiClientProvider))) {
          throw StateError('单号候选读取作用域已变化');
        }
        if (json['field'] != field ||
            json['page'] != page ||
            json['size'] != 100 ||
            json['items'] is! List ||
            (json['items'] as List).length > 100 ||
            json['hasMore'] is! bool) {
          throw StateError('单号候选分页响应无效');
        }
        return MasterFacetPage.fromJson(json);
      },
  };
}

/// Changes to owner, server, read authority or any original filter retire an open search panel.
Object nativeFacetSearchScope(
  WidgetRef ref,
  String path,
  Map<String, dynamic> filters,
) => (ref.watch(exportContextEpochProvider), path, jsonEncode(_body(filters)));
