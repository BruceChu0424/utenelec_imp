import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/router/route_names.dart';

void main() {
  group('sanitizeReturnTo', () {
    test(
      'rejects external, relative, malformed, and authentication routes',
      () {
        for (final candidate in <String?>[
          null,
          '',
          'dashboard',
          ' https://evil.example/path',
          'https://evil.example/path',
          '//evil.example/path',
          r'/\evil.example',
          'javascript:alert(1)',
          RouteName.entry,
          RouteName.login,
          RouteName.changePassword,
          RouteName.visitorLogin,
        ]) {
          expect(
            sanitizeReturnTo(candidate, scope: ReturnToScope.any),
            isNull,
            reason: '$candidate',
          );
        }
      },
    );

    test('keeps employee and visitor portals isolated', () {
      const employeeTarget = '/sales/orders/42?tab=detail&source=notice';
      const visitorTarget = '/visitor/apply/application-1?step=review';

      expect(
        sanitizeReturnTo(employeeTarget, scope: ReturnToScope.employee),
        employeeTarget,
      );
      expect(
        sanitizeReturnTo('/visitor-approval/1', scope: ReturnToScope.employee),
        '/visitor-approval/1',
      );
      expect(
        sanitizeReturnTo(visitorTarget, scope: ReturnToScope.employee),
        isNull,
      );
      expect(
        sanitizeReturnTo(visitorTarget, scope: ReturnToScope.visitor),
        visitorTarget,
      );
      expect(
        sanitizeReturnTo(employeeTarget, scope: ReturnToScope.visitor),
        isNull,
      );
    });
  });

  group('encoded returnTo route builders', () {
    test(
      'entry selection preserves the matching employee or visitor target',
      () {
        const employeeTarget = '/finance/assets?status=pending&owner=me';
        final employeeEntry = RoutePath.entry(returnTo: employeeTarget);
        final carriedEmployee = returnToFromUri(
          Uri.parse(employeeEntry),
          scope: ReturnToScope.any,
        );
        final employeeLogin = RoutePath.login(returnTo: carriedEmployee);

        expect(Uri.parse(employeeLogin).path, RouteName.login);
        expect(
          returnToFromUri(
            Uri.parse(employeeLogin),
            scope: ReturnToScope.employee,
          ),
          employeeTarget,
        );
        expect(employeeLogin, contains('%2Ffinance%2Fassets'));

        const visitorTarget = '/visitor/apply/visitor-1?from=message';
        final visitorEntry = RoutePath.entry(returnTo: visitorTarget);
        final carriedVisitor = returnToFromUri(
          Uri.parse(visitorEntry),
          scope: ReturnToScope.any,
        );
        final visitorLogin = RoutePath.visitorLogin(returnTo: carriedVisitor);

        expect(Uri.parse(visitorLogin).path, RouteName.visitorLogin);
        expect(
          returnToFromUri(
            Uri.parse(visitorLogin),
            scope: ReturnToScope.visitor,
          ),
          visitorTarget,
        );
        expect(RoutePath.login(returnTo: visitorTarget), RouteName.login);
        expect(
          RoutePath.visitorLogin(returnTo: employeeTarget),
          RouteName.visitorLogin,
        );
      },
    );

    test('forced password change carries the employee target end to end', () {
      const target = '/purchase/orders/order-42?tab=lines&from=notice';
      final login = RoutePath.login(returnTo: target);
      final loginTarget = returnToFromUri(
        Uri.parse(login),
        scope: ReturnToScope.employee,
      );
      final forcedChange = RoutePath.changePassword(
        forced: true,
        returnTo: loginTarget,
      );
      final forcedUri = Uri.parse(forcedChange);

      expect(forcedUri.path, RouteName.changePassword);
      expect(forcedUri.queryParameters['forced'], 'true');
      expect(returnToFromUri(forcedUri, scope: ReturnToScope.employee), target);
    });

    test('omitted or unsafe targets use the existing default route URLs', () {
      expect(RoutePath.entry(), RouteName.entry);
      expect(RoutePath.login(), RouteName.login);
      expect(RoutePath.visitorLogin(), RouteName.visitorLogin);
      expect(RoutePath.changePassword(), RouteName.changePassword);
      expect(
        RoutePath.login(returnTo: 'https://evil.example'),
        RouteName.login,
      );
      expect(
        RoutePath.changePassword(forced: true, returnTo: '//evil.example'),
        '${RouteName.changePassword}?forced=true',
      );
    });
  });
}
