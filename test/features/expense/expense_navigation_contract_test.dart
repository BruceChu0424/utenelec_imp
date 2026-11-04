import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/router/route_access_policy.dart';
import 'package:uten_imp/features/dashboard/widgets/module_badge_sum.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/badges/badge_registry.dart';

import '../../helpers/badge_summary_fixture.dart';

void main() {
  test(
    'prepayment finance linking opens follow-up without application creation',
    () {
      final grants = {Perm.applicationPrepaymentLinkFinance};
      expect(locationAllowedFor(grants, false, '/approvals/FINANCE'), isTrue);
      expect(
        locationAllowedFor(grants, false, '/applications/approval'),
        isTrue,
      );
      expect(
        locationAllowedFor(grants, false, '/applications/application-1'),
        isTrue,
      );
      expect(
        locationAllowedFor(grants, false, '/applications/new?kind=PREPAYMENT'),
        isFalse,
      );
      expect(locationAllowedFor(grants, false, '/applications'), isFalse);
    },
  );

  test('application creation routes require the selected kind grant', () {
    final travel = {Perm.applicationApplyTravel};
    expect(locationAllowedFor(travel, false, '/applications'), isTrue);
    expect(
      locationAllowedFor(travel, false, '/applications/new?kind=TRAVEL'),
      isTrue,
    );
    expect(
      locationAllowedFor(
        travel,
        false,
        '/applications/new?kind=SUPPLIER_PAYMENT',
      ),
      isFalse,
    );
    expect(
      locationAllowedFor(
        travel,
        false,
        '/applications/new?kind=PAYROLL_PAYMENT',
      ),
      isFalse,
    );
    expect(
      locationAllowedFor(
        {Perm.expenseApply},
        false,
        '/applications/new?kind=TRAVEL',
      ),
      isFalse,
    );
    expect(
      locationAllowedFor({Perm.expenseApply}, false, '/applications'),
      isTrue,
    );
  });

  test(
    'approval entry permissions are distinct for departments finance and executives',
    () {
      expect(
        locationAllowedFor(
          {Perm.expenseApproveDepartment},
          false,
          '/approvals/DEPT_HR',
        ),
        isTrue,
      );
      expect(
        locationAllowedFor(
          {Perm.expenseApproveDepartment},
          false,
          '/approvals/GM',
        ),
        isFalse,
      );
      expect(
        locationAllowedFor(
          {Perm.expenseApproveDepartment},
          false,
          '/approvals/FINANCE',
        ),
        isFalse,
      );
      expect(
        locationAllowedFor(
          {Perm.expenseApproveExecutive},
          false,
          '/approvals/GM',
        ),
        isTrue,
      );
      expect(
        locationAllowedFor(
          {Perm.applicationReceive},
          false,
          '/approvals/FINANCE',
        ),
        isTrue,
      );
      expect(
        locationAllowedFor({Perm.expenseApprove}, false, '/approvals/DEPT_HR'),
        isFalse,
      );
      expect(
        locationAllowedFor(
          {Perm.expenseApproveDepartment},
          false,
          '/approvals/UNKNOWN',
        ),
        isFalse,
      );
    },
  );

  test(
    'department cards show only their own slice and aggregate self applications once',
    () {
      final summary = badgeSummaryFixture(
        entries: {
          BadgeEntry.expenseMine: (2, 3),
          BadgeEntry.applicationMine: (5, 7),
          BadgeEntry.salesManagerReview: (11, 0),
        },
        facts: {
          'expense.departmentPendingByCode.DEPT_SALES': 13,
          'application.departmentPendingByCode.DEPT_SALES': 17,
          'expense.departmentPendingByCode.DEPT_HR': 19,
          'application.departmentPendingByCode.DEPT_HR': 23,
        },
      );
      expect(
        workbenchBadgeCounts(
          WorkbenchBadgeKind.salesManagerReview,
          summary,
        ).todo,
        41,
      );
      expect(
        workbenchBadgeCounts(WorkbenchBadgeKind.approvalHr, summary).todo,
        42,
      );
      expect(
        workbenchBadgeCounts(WorkbenchBadgeKind.approvalRail, summary).todo,
        0,
      );
      expect(
        workbenchBadgeCounts(WorkbenchBadgeKind.expenseMine, summary),
        const BadgeCounts(7, 10),
      );
    },
  );
}
