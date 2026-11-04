import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Only the session owner may publish a replacement that actually ended the
/// visible session. Raw HTTP failures and startup restoration never own a dialog.
class SessionKickNotice {
  const SessionKickNotice({required this.message, required this.intentEpoch});

  final String? message;
  final int intentEpoch;
}

class SessionKickNoticeNotifier extends Notifier<SessionKickNotice?> {
  @override
  SessionKickNotice? build() => null;

  void publish(SessionKickNotice notice) => state = notice;

  void consume(SessionKickNotice notice) {
    if (identical(state, notice)) state = null;
  }
}

final sessionKickNoticeProvider =
    NotifierProvider<SessionKickNoticeNotifier, SessionKickNotice?>(
      SessionKickNoticeNotifier.new,
    );
