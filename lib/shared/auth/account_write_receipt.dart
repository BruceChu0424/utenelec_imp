/// An account write returned without a verifiable receipt. The server may have
/// committed it; callers must preserve that uncertainty rather than guess a
/// username, display another employee's credentials, or replay the write.
class AccountWriteReceiptException extends FormatException {
  const AccountWriteReceiptException()
    : super(
        'Account write receipt is incomplete or does not match the request',
      );
}
