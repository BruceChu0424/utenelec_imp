import 'package:uten_imp/core/network/api_client.dart';

/// Existing synthetic business fixtures expose complete buckets. Exercise the new
/// POST caller contract while keeping their original business facts as the authority.
mixin NativeFacetFakeTransport on ApiClient {
  @override
  Future<Map<String, dynamic>> postForm(
    String path, {
    required Map<String, dynamic> body,
  }) async {
    final json = await get(
      path,
      query: {
        for (final entry in body.entries)
          if (!entry.key.startsWith('__facet')) entry.key: entry.value,
      },
    );
    final field = body['__facetField'] as String;
    final keyword = (body['__facetKeyword'] as String).toLowerCase();
    final page = body['__facetPage'] as int, size = body['__facetSize'] as int;
    final all = [
      for (final item in json[field] as List? ?? const [])
        if ((item as Map)['value'].toString().toLowerCase().contains(keyword))
          item,
    ];
    final offset = (page - 1) * size;
    return {
      'field': field,
      'page': page,
      'size': size,
      'items': all.skip(offset).take(size).toList(),
      'hasMore': offset + size < all.length,
      'readScopeVersion': 'synthetic-current',
    };
  }
}
