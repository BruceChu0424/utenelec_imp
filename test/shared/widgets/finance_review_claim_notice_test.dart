// financeReviewClaim 身份栅栏回归测试（2026-10-10「登录身份已变化」误报根因）：
// access token 静默刷新（约每 15 分钟）曾把 SessionState 换成内容相同的新对象，
// 工厂用对象同一性判断身份，导致有效认领被本地误杀（服务端租约按人走、并未
// 失效）。改语义身份（isSameIdentity）后：同身份的状态对象更替不失效认领，
// 换号/登出仍立即失效。
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uten_imp/core/network/server_config.dart';
import 'package:uten_imp/core/security/secure_storage.dart';
import 'package:uten_imp/features/auth/repositories/auth_repository.dart';
import 'package:uten_imp/shared/models/user.dart';
import 'package:uten_imp/shared/providers/session_provider.dart';
import 'package:uten_imp/shared/repositories/task_claim_repository.dart';
import 'package:uten_imp/shared/widgets/finance_review_claim_notice.dart';

import '../../helpers/finance_claim_fixture.dart';

const _base = 'https://claim-fence.example.test/api';

class _SwappableSessionNotifier extends SessionNotifier {
  @override
  SessionState build() => const SessionState(
    user: AppUser(id: 'finance-reviewer', code: 'FIN001', name: '财务李四'),
  );

  void replace(SessionState next) => state = next;
}

class _AuthRepository extends Fake implements AuthRepository {}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => FlutterSecureStorage.setMockInitialValues({}));

  test('financeReviewClaim 在同身份状态更替下存活，换号即失效', () async {
    final storage = SecureStorage(const FlutterSecureStorage());
    final container = ProviderContainer(
      overrides: [
        apiBaseUrlProvider.overrideWithValue(_base),
        secureStorageProvider.overrideWithValue(storage),
        authRepositoryProvider.overrideWithValue(_AuthRepository()),
        sessionProvider.overrideWith(_SwappableSessionNotifier.new),
        taskClaimRepositoryProvider.overrideWithValue(FinanceClaimFixture()),
      ],
    );
    addTearDown(container.dispose);
    final notifier =
        container.read(sessionProvider.notifier) as _SwappableSessionNotifier;
    await pumpEventQueue();
    expect(container.read(sessionProvider).user?.id, 'finance-reviewer');

    final claim = financeReviewClaim(container);
    expect(claim.isCurrent, isTrue);

    // token 静默刷新：同 id 的新档案对象（旧实现在此误判换号）。
    notifier.replace(
      const SessionState(
        user: AppUser(id: 'finance-reviewer', code: 'FIN001', name: '财务李四'),
      ),
    );
    expect(claim.isCurrent, isTrue);

    // 权限滑动更新：身份不变、权限集变化，认领同样保持。
    notifier.replace(
      const SessionState(
        user: AppUser(
          id: 'finance-reviewer',
          code: 'FIN001',
          name: '财务李四',
          permissions: ['finance:extra'],
        ),
      ),
    );
    expect(claim.isCurrent, isTrue);

    // 真实换号：立即失效。
    notifier.replace(
      const SessionState(
        user: AppUser(id: 'finance-other', code: 'FIN002', name: '另一财务'),
      ),
    );
    expect(claim.isCurrent, isFalse);
  });
}
