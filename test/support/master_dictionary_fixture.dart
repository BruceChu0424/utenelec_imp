import 'package:dio/dio.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/shared/providers/master_dictionary_repository.dart';

/// These workflow fixtures supply names in their own DTOs. Incidental shared
/// dictionaries are explicitly empty; they never issue environment HTTP reads.
/// Business repositories/API overrides remain independent and unchanged.
Override emptyMasterDictionaryFixture() =>
    masterDictionaryRepositoryProvider.overrideWith((ref) {
      final repository = MasterDictionaryRepository(_EmptyDictionaryApi());
      ref.onDispose(repository.dispose);
      return repository;
    });

class _EmptyDictionaryApi extends ApiClient {
  _EmptyDictionaryApi() : super(Dio());
  @override
  Future<List<Map<String, dynamic>>> getList(
    String path, {
    Map<String, dynamic>? query,
  }) async => [];
}
