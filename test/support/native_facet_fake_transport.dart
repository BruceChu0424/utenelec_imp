import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:uten_imp/core/network/api_exception.dart';
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
    final nested = json['facets'];
    final buckets =
        json[field] ??
        (nested is Map ? nested[field] : null) ??
        (field == 'claimNo' ? json['claimNos'] : null) ??
        const <Map<String, dynamic>>[];
    final all = [
      for (final item in buckets as List)
        if ((item as Map)['value'].toString().toLowerCase().contains(keyword) ||
            (item['label'] ?? item['value']).toString().toLowerCase().contains(
              keyword,
            ))
          item,
    ];
    // Synthetic fixture proofs are derived from the complete original bucket
    // facts/query, never used as production authorization or a missing default.
    final dataVersion = sha256.convert(utf8.encode(jsonEncode(all))).toString();
    final revision = sha256
        .convert(
          utf8.encode(
            jsonEncode([
              path,
              field,
              keyword,
              size,
              {
                for (final entry in body.entries)
                  if (!entry.key.startsWith('__facet')) entry.key: entry.value,
              },
              dataVersion,
            ]),
          ),
        )
        .toString();
    if (page > 1 && body['__facetReadSnapshotRevision'] != revision) {
      throw ApiException(
        'SNAPSHOT_CHANGED',
        'Synthetic fixture candidate scope changed',
      );
    }
    final offset = (page - 1) * size;
    return {
      'field': field,
      'page': page,
      'size': size,
      'items': all.skip(offset).take(size).toList(),
      'hasMore': offset + size < all.length,
      'readScopeVersion': 'synthetic-current',
      'readSnapshotRevision': revision,
      'readDataVersion': dataVersion,
    };
  }
}
