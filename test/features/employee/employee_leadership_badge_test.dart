import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/features/employee/widgets/employee_leadership_badge.dart';

void main() {
  testWidgets('负责人标识优先于岗位层级', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: EmployeeLeadershipBadge(
            departmentManager: true,
            positionLevel: '领导层',
            leaderRank: 0,
          ),
        ),
      ),
    );

    expect(find.text('负责人'), findsOneWidget);
    expect(find.byIcon(Icons.supervisor_account_rounded), findsOneWidget);
  });

  test('普通员工不生成领导标签', () {
    expect(
      employeeLeadershipLabel(
        departmentManager: false,
        positionLevel: '员工',
        leaderRank: 3,
      ),
      isNull,
    );
  });
}
