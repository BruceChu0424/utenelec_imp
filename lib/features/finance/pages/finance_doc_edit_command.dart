part of 'finance_doc_edit_page.dart';

extension _FinanceExistingEditCommand on _FinanceDocEditPageState {
  Map<String, String> _editCurrencyEntries(FinanceNameService names) => {
    ...financeEntryCurrencyChoices(_cfg, names),
    if (_currencyId != null &&
        !financeEntryCurrencyChoices(_cfg, names).containsKey(_currencyId))
      _currencyId!: names.currency(_currencyId),
  };

  Map<String, String> _editAccountEntries(FinanceNameService names) => {
    for (final account in financeEntryAccountChoices(_cfg, names))
      account.id: names.account(account.id),
    ?_accountId: names.account(_accountId),
  };
  Future<void> _sendEditIntent({bool fresh = false}) async {
    if (_saving ||
        _editIntent == null ||
        !_editCanWrite ||
        !formDraftIdentityIsCurrent) {
      return;
    }
    bool dispatched = false;
    setState(() => _saving = true);
    try {
      await saveFormDraftNow();
      final scope = await captureFormDraftRequestScope();
      final envelope = await runFormDraftSubmission(
        () => scope.run(() {
          dispatched = true;
          return ref
              .read(financeRepositoryProvider(widget.docType))
              .executeDocumentIntent(_editIntent!);
        }),
        isDefiniteRejection: (_) => false,
      );
      if (!mounted) return;
      if (!scope.isCurrent) return;
      _editIntent!.precisionChoices = formDraftPrecisionChoices;
      await _acceptEditReceipt(envelope);
    } catch (error) {
      if (fresh && !dispatched) {
        _editIntent = null;
        await releaseFormDraftBeforeDispatch();
      }
      if (mounted && formDraftIdentityIsCurrent) {
        await saveFormDraftNow();
        if (!mounted || !formDraftIdentityIsCurrent) return;
        context.appError(
          describeSubmitError(error, fallback: '原保存结果待核对，原内容、币种和精度已保留'),
        );
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _acceptEditReceipt(Map<String, dynamic> envelope) async {
    final intent = _editIntent!;
    await intent.original.verifyResponsive(
      envelope,
      isCurrent: () => mounted && formDraftIdentityIsCurrent,
    );
    if (envelope['outcome'] == 'CANCELLED_UNWRITTEN') {
      _editRetired = {'intent': intent.toJson(), 'receipt': envelope};
      _editIntent = null;
      _editNeedsReview = true;
      await checkpointFormDraftAfterConfirmedMutation(
        originalReceiptAcknowledged: true,
      );
      if (mounted) setState(() {});
      return;
    }
    final result = FinanceDocDetail.fromJson(
      Map<String, dynamic>.from(envelope['result'] as Map),
    );
    if (result.id != widget.id) throw StateError('原保存回执的单据身份不一致');
    await completeFormDraft();
    if (!mounted) return;
    bumpListRefresh(ref, _cfg.refreshKey);
    context.appSuccess('已保存${financeDocumentPrecisionLabel(envelope)}');
    context.replace('/finance/${widget.docType.pathSegment}/${widget.id}');
  }

  Future<void> _recoverEdit(bool cancel) async {
    final identity = ref.read(authenticatedScopeProvider);
    if (_saving ||
        _editIntent == null ||
        !_editCanRead ||
        !formDraftIdentityIsCurrent ||
        cancel &&
            (identity == null ||
                identity.readOnly ||
                identity.actorId != null)) {
      return;
    }
    setState(() => _saving = true);
    try {
      final scope = await captureFormDraftRequestScope();
      final envelope = await scope.run(
        () => cancel
            ? _editIntent!.cancel(
                ref.read(apiClientProvider),
                isCurrent: () => mounted && scope.isCurrent,
              )
            : _editIntent!.receipt(
                ref.read(apiClientProvider),
                isCurrent: () => mounted && scope.isCurrent,
              ),
      );
      if (!mounted) return;
      if (!scope.isCurrent) return;
      if (envelope['found'] != true) {
        context.appWarning('尚未取得原保存回执，不能据此认定未写入');
        return;
      }
      await _acceptEditReceipt(envelope);
    } catch (error) {
      if (mounted && formDraftIdentityIsCurrent) {
        context.appError(describeSubmitError(error, fallback: '原保存结果仍待核对'));
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _reviewEditCurrent() async {
    if (_saving ||
        _editIntent != null ||
        !_editCanWrite ||
        !formDraftIdentityIsCurrent) {
      return;
    }
    setState(() => _saving = true);
    try {
      final scope = await captureFormDraftRequestScope();
      if (!mounted || !scope.isCurrent) return;
      final current = await UtenBusyOverlay.run(
        context,
        title: '正在读取当前单据',
        action: () => scope.run(
          () => ref
              .read(financeRepositoryProvider(widget.docType))
              .detail(widget.id!),
        ),
      );
      if (!mounted) return;
      if (!scope.isCurrent) return;
      if (!financeDocumentHasReviewSnapshot(current, type: widget.docType) ||
          current.status != kFinanceStatusDraft ||
          current.legacyImported) {
        context.appWarning('当前单据已不能编辑，原输入继续保留');
        return;
      }
      // No waiting overlay covers this complete, frozen current-document review.
      setState(() => _saving = false);
      final accepted = await Navigator.of(context).push<bool>(
        MaterialPageRoute(
          builder: (_) => FinanceDocDetailPage(
            docType: widget.docType,
            id: widget.id!,
            reviewSnapshot: current,
            allowVersionAdoption: true,
          ),
        ),
      );
      if (!mounted || !scope.isCurrent || accepted != true) return;
      _editReviewed = current;
      _expectedVersion = current.approvalVersion;
      _editNeedsReview = false;
      _editRetired = null;
      await saveFormDraftNow();
      if (mounted) setState(() {});
    } catch (error) {
      if (mounted && formDraftIdentityIsCurrent) {
        context.appError(
          describeSubmitError(error, fallback: '当前单据尚未核对完成，原输入继续保留'),
        );
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _leaveEditor() async {
    if (_saving || _editMenu) return;
    if (_editIntent != null) {
      await saveFormDraftNow();
      if (!mounted) return;
    }
    if (mounted) popOrBackTo(context, defaultPath: RouteName.finance);
  }
}
