import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/shared/drafts/form_draft.dart';
import 'package:uten_imp/core/router/route_names.dart';

void main() {
  test(
    'the original body cannot disappear or change during draft reconstruction',
    () {
      final snapshot = <String, dynamic>{
        formDraftUnknownSubmissionKey: true,
        'legacyOriginalCommand': {
          'analysisId': 'analysis',
          'operation': 'notify',
          'bodyJson': '{"idempotencyKey":"original","qty":"500"}',
        },
      };
      final ids = unknownFormDraftCommandIdentities(
        snapshot,
        route: RouteName.productionMaterialAnalysis,
      );
      expect(ids, hasLength(1));
      final changed = <String, dynamic>{
        ...snapshot,
        'legacyOriginalCommand': {
          'analysisId': 'analysis',
          'operation': 'notify',
          'bodyJson': '{"idempotencyKey":"replacement","qty":"499"}',
        },
      };
      expect(
        unknownFormDraftCommandIdentities(
          changed,
          route: RouteName.productionMaterialAnalysis,
        ).containsAll(ids),
        false,
      );
      expect(
        unknownFormDraftCommandIdentities({
          formDraftUnknownSubmissionKey: true,
        }, route: RouteName.productionMaterialAnalysis).containsAll(ids),
        false,
      );
    },
  );
  test(
    'a false marker cannot make a still-present original command editable',
    () {
      final snapshot = <String, dynamic>{
        formDraftUnknownSubmissionKey: false,
        'legacyOriginalCommand': {'bodyJson': '{}'},
      };
      expect(
        hasUnknownFormDraftSubmission(
          snapshot,
          route: RouteName.productionMaterialAnalysis,
        ),
        true,
      );
      expect(
        hasUnknownFormDraftSubmission({
          formDraftUnknownSubmissionKey: false,
        }, route: RouteName.productionMaterialAnalysis),
        false,
      );
    },
  );
}
