import 'package:uten_imp/core/security/auth_logout_fence.dart';

class FakeAuthLogoutFence implements AuthLogoutFence {
  FakeAuthLogoutFence({
    this.active = false,
    this.readError,
    this.activateError,
    this.clearError,
  });

  bool active;
  Object? readError;
  Object? activateError;
  Object? clearError;
  int readCalls = 0;
  int activateCalls = 0;
  int clearCalls = 0;

  @override
  Future<bool> isActive() async {
    readCalls++;
    final error = readError;
    if (error != null) throw error;
    return active;
  }

  @override
  Future<void> activate() async {
    activateCalls++;
    final error = activateError;
    if (error != null) throw error;
    active = true;
  }

  @override
  Future<void> clear() async {
    clearCalls++;
    final error = clearError;
    if (error != null) throw error;
    active = false;
  }
}
