// 客户/供应商资料子表仓库（V579）：联系方式 / 地址 / 跟进记录 / 客户信誉分。
// partyType 决定前缀 /api/master/clients 或 /api/master/suppliers。
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/network/api_client.dart';
import '../models/party_directory_models.dart';

enum PartyDirectoryType { client, supplier }

extension PartyDirectoryTypePath on PartyDirectoryType {
  String get basePath => this == PartyDirectoryType.client
      ? '/master/clients'
      : '/master/suppliers';
}

class PartyDirectoryRepository {
  PartyDirectoryRepository(this.api, this.type);

  final ApiClient api;
  final PartyDirectoryType type;

  String get _base => type.basePath;

  // ===== 联系方式 =====
  Future<List<PartyContactMethod>> contactMethods(String partyId) async {
    final list = await api.getList('$_base/$partyId/contact-methods');
    return [for (final item in list) PartyContactMethod.fromJson(item)];
  }

  Future<void> addContactMethod(
    String partyId, {
    required String kind,
    required String value,
    bool primary = false,
    String? remark,
  }) async {
    await api.post(
      '$_base/$partyId/contact-methods',
      body: {
        'kind': kind,
        'value': value,
        'isPrimary': primary,
        if (remark != null && remark.trim().isNotEmpty) 'remark': remark.trim(),
      },
    );
  }

  Future<void> deleteContactMethod(String partyId, String contactId) async {
    await api.delete('$_base/$partyId/contact-methods/$contactId');
  }

  // ===== 地址 =====
  Future<List<PartyAddress>> addresses(String partyId) async {
    final list = await api.getList('$_base/$partyId/addresses');
    return [for (final item in list) PartyAddress.fromJson(item)];
  }

  Future<void> addAddress(
    String partyId, {
    required String kind,
    required String address,
    bool defaultAddress = false,
    String? remark,
  }) async {
    await api.post(
      '$_base/$partyId/addresses',
      body: {
        'kind': kind,
        'address': address,
        'isDefault': defaultAddress,
        if (remark != null && remark.trim().isNotEmpty) 'remark': remark.trim(),
      },
    );
  }

  Future<void> deleteAddress(String partyId, String addressId) async {
    await api.delete('$_base/$partyId/addresses/$addressId');
  }

  // ===== 跟进记录 =====
  Future<List<PartyActivityRecord>> activityRecords(String partyId) async {
    final list = await api.getList('$_base/$partyId/activity-records');
    return [for (final item in list) PartyActivityRecord.fromJson(item)];
  }

  Future<void> addActivityRecord(
    String partyId, {
    required String kind,
    required String content,
    int scoreDelta = 0,
  }) async {
    await api.post(
      '$_base/$partyId/activity-records',
      body: {'kind': kind, 'content': content, 'scoreDelta': scoreDelta},
    );
  }

  // ===== 客户信誉分 =====
  Future<int?> creditScore(String partyId) async {
    final json = await api.get('$_base/$partyId/credit-score');
    return (json['creditScore'] as num?)?.toInt();
  }
}

final clientDirectoryRepositoryProvider = Provider<PartyDirectoryRepository>(
  (ref) => PartyDirectoryRepository(
    ref.watch(apiClientProvider),
    PartyDirectoryType.client,
  ),
);

final supplierDirectoryRepositoryProvider = Provider<PartyDirectoryRepository>(
  (ref) => PartyDirectoryRepository(
    ref.watch(apiClientProvider),
    PartyDirectoryType.supplier,
  ),
);
