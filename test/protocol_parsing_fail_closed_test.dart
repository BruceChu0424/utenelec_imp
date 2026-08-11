import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/features/profile/models/profile_change_request.dart';
import 'package:uten_imp/features/suggestion/repositories/suggestion_repository.dart';
import 'package:uten_imp/features/visitor/models/visitor_application.dart';

void main() {
  group('visitor protocol parsing', () {
    test('rejects unknown status instead of treating it as pending', () {
      final json = _visitorJson()..['status'] = 'awaiting_magic';

      expect(
        () => VisitorApplication.fromJson(json),
        throwsA(isA<FormatException>()),
      );
    });

    test('rejects missing or malformed required dates', () {
      for (final field in ['plannedVisitAt', 'appliedAt']) {
        final malformed = _visitorJson()..[field] = 'not-a-date';
        final missing = _visitorJson()..remove(field);

        expect(
          () => VisitorApplication.fromJson(malformed),
          throwsA(isA<FormatException>()),
          reason: field,
        );
        expect(
          () => VisitorApplication.fromJson(missing),
          throwsA(isA<FormatException>()),
          reason: field,
        );
      }
    });

    test('rejects malformed optional and approval-step dates when present', () {
      final json = _visitorJson()..['approvedAt'] = 'invalid';

      expect(
        () => VisitorApplication.fromJson(json),
        throwsA(isA<FormatException>()),
      );
      expect(
        () => VisitorApprovalStep.fromJson({
          'action': 'approved',
          'actorType': 'employee',
          'actorName': 'Reviewer',
          'actedAt': 'invalid',
        }),
        throwsA(isA<FormatException>()),
      );
    });
  });

  group('suggestion repository protocol parsing', () {
    test('rejects unknown category and status codes', () async {
      final unknownCategory = _suggestionJson()..['category'] = 'unknown';
      final unknownStatus = _suggestionJson()..['status'] = 'queued';

      await expectLater(
        _repositoryReturning(unknownCategory).getById('suggestion-1'),
        throwsA(isA<FormatException>()),
      );
      await expectLater(
        _repositoryReturning(unknownStatus).getById('suggestion-1'),
        throwsA(isA<FormatException>()),
      );
    });

    test('rejects malformed suggestion and reply dates', () async {
      final invalidSubmission = _suggestionJson()
        ..['submittedAt'] = 'not-a-date';
      final invalidReply = _suggestionJson()
        ..['replies'] = [
          {
            'id': 'reply-1',
            'replier': 'Reviewer',
            'replierRole': 'manager',
            'content': 'Handled',
            'repliedAt': 'not-a-date',
          },
        ];

      await expectLater(
        _repositoryReturning(invalidSubmission).getById('suggestion-1'),
        throwsA(isA<FormatException>()),
      );
      await expectLater(
        _repositoryReturning(invalidReply).getById('suggestion-1'),
        throwsA(isA<FormatException>()),
      );
    });
  });

  test('profile change rejects malformed required and optional dates', () {
    void expectFailClosed(
      String name,
      Map<String, dynamic> valid,
      Object Function(Map<String, dynamic>) parse,
    ) {
      final missingSubmitted = Map<String, dynamic>.from(valid)
        ..remove('submittedAt');
      final invalidSubmitted = Map<String, dynamic>.from(valid)
        ..['submittedAt'] = 'not-a-date';
      final invalidReviewed = Map<String, dynamic>.from(valid)
        ..['reviewedAt'] = 'not-a-date';

      expect(
        () => parse(missingSubmitted),
        throwsA(isA<FormatException>()),
        reason: '$name missing submittedAt',
      );
      expect(
        () => parse(invalidSubmitted),
        throwsA(isA<FormatException>()),
        reason: '$name invalid submittedAt',
      );
      expect(
        () => parse(invalidReviewed),
        throwsA(isA<FormatException>()),
        reason: '$name invalid reviewedAt',
      );
    }

    expectFailClosed('item', _profileItemJson(), ProfileChangeItem.fromJson);
    expectFailClosed('batch', _profileBatchJson(), ProfileChangeBatch.fromJson);
    expectFailClosed(
      'my list item',
      _myProfileChangeJson(),
      MyProfileChangeListItem.fromJson,
    );
    expectFailClosed(
      'HR list item',
      _hrProfileChangeJson(),
      HrProfileChangeListItem.fromJson,
    );
  });
  test('profile change rejects unknown status instead of pending', () {
    final json = <String, dynamic>{
      'id': 'change-1',
      'batchId': 'batch-1',
      'fieldCode': 'phone',
      'fieldLabel': 'Phone',
      'fieldGroup': 'contact',
      'newValue': '13800138000',
      'status': 'waiting',
      'submittedBy': 'employee-1',
      'submittedAt': '2026-08-01T08:00:00+08:00',
    };

    expect(
      () => ProfileChangeItem.fromJson(json),
      throwsA(isA<FormatException>()),
    );
  });
}

Map<String, dynamic> _visitorJson() => {
  'id': 'visitor-1',
  'visitorName': 'Visitor',
  'visitPurpose': 'Business',
  'status': 'pending',
  'plannedVisitAt': '2026-08-01T09:00:00+08:00',
  'appliedAt': '2026-08-01T08:00:00+08:00',
};

Map<String, dynamic> _suggestionJson() => {
  'id': 'suggestion-1',
  'submitterId': 'employee-1',
  'submitterName': 'Employee',
  'category': 'product',
  'title': 'Improve process',
  'content': 'Details',
  'status': 'submitted',
  'submittedAt': '2026-08-01T08:00:00+08:00',
  'replies': <Map<String, dynamic>>[],
};

DioSuggestionRepository _repositoryReturning(Map<String, dynamic> json) {
  final dio = Dio(BaseOptions(baseUrl: 'http://localhost:8080/api'));
  dio.interceptors.add(
    InterceptorsWrapper(
      onRequest: (request, handler) => handler.resolve(
        Response<dynamic>(requestOptions: request, statusCode: 200, data: json),
      ),
    ),
  );
  return DioSuggestionRepository(ApiClient(dio));
}

Map<String, dynamic> _profileItemJson() => {
  'id': 'change-1',
  'batchId': 'batch-1',
  'fieldCode': 'phone',
  'fieldLabel': 'Phone',
  'fieldGroup': 'contact',
  'newValue': '13800138000',
  'status': 'pending',
  'submittedBy': 'employee-1',
  'submittedAt': '2026-08-01T08:00:00+08:00',
};

Map<String, dynamic> _profileBatchJson() => {
  'batchId': 'batch-1',
  'employeeId': 'employee-1',
  'status': 'pending',
  'itemCount': 0,
  'items': <Map<String, dynamic>>[],
  'submittedAt': '2026-08-01T08:00:00+08:00',
};

Map<String, dynamic> _myProfileChangeJson() => {
  'batchId': 'batch-1',
  'status': 'pending',
  'itemCount': 1,
  'fieldCodes': <String>['phone'],
  'fieldLabels': <String>['Phone'],
  'submittedAt': '2026-08-01T08:00:00+08:00',
};

Map<String, dynamic> _hrProfileChangeJson() => {
  'batchId': 'batch-1',
  'employeeId': 'employee-1',
  'status': 'pending',
  'itemCount': 1,
  'fieldCodes': <String>['phone'],
  'submittedAt': '2026-08-01T08:00:00+08:00',
};
