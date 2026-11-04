part of 'finance_doc_edit_page.dart';

/// Creation keeps one shared date/operator and puts settlement terms in rows.
/// Existing documents and old draft recovery retain the single-document editor.
extension _FinanceBatchEntry on _FinanceDocEditPageState {
  Widget _entryDropdown({
    required String label,
    required String? value,
    required Map<String, String> entries,
    required ValueChanged<String?> onChanged,
  }) => _dropdown(label, value, entries, onChanged);

  FinanceGridRow _newEntryRow() {
    final row = FinanceGridRow(mode: _cfg.itemMode);
    row.entry.bookedAt = _bankBookedAt;
    row.entry.rateEffectiveAt = _exchangeRateEffectiveAt;
    row.enableEntryPricing();
    return row;
  }

  bool _entryCurrent(FinanceGridRow row) =>
      mounted &&
      formDraftIdentityIsCurrent &&
      !_saving &&
      _createdBatchIds.isEmpty &&
      _batchCommand == null &&
      _grid.rows.contains(row);

  void _changeEntryCurrency(FinanceGridRow row, String? currency) {
    row.entry.currencyId = currency;
    final names = ref.read(financeNameServiceProvider);
    row.exchangeRate.text = names.currencyIsBase(currency) == true
        ? '1'
        : names.currencyReferenceRateText(currency) ?? '';
    row.entry.touch();
  }

  Future<String?> _pickEntryPartyId(
    BuildContext panelContext, {
    required bool Function() isCurrent,
  }) async {
    final names = ref.read(financeNameServiceProvider);
    if (_cfg.isClient) {
      return (await resolvePickedParty(
        ref,
        () => showUtenClientPicker(panelContext, ref),
        idOf: (party) => party.id,
        loadNames: names.loadClientNames,
        isResolved: names.clientReferenceSelectable,
        isCurrent: isCurrent,
      ))?.id;
    }
    return (await resolvePickedParty(
      ref,
      () => showUtenSupplierPicker(panelContext, ref),
      idOf: (party) => party.id,
      loadNames: names.loadSupplierNames,
      isResolved: names.supplierReferenceSelectable,
      isCurrent: isCurrent,
    ))?.id;
  }

  Future<void> _pickEntryParty(FinanceGridRow row) async {
    if (!_entryCurrent(row)) return;
    if (row.appliedLedgerId != null || row.entry.salesOrderId != null) {
      context.appWarning('往来单位由引用来源确定；更换单位请新增行');
      return;
    }
    final checkpoint = JsonValueSnapshot.capture(row.entry.toJson());
    final id = await _pickEntryPartyId(
      context,
      isCurrent: () =>
          _entryCurrent(row) && checkpoint.matches(row.entry.toJson()),
    );
    if (id == null ||
        !_entryCurrent(row) ||
        !checkpoint.matches(row.entry.toJson())) {
      return;
    }
    row.entry.partyId = id;
    row.entry.touch();
  }

  Future<void> _pickEntryAccount(FinanceGridRow row) async {
    if (!_entryCurrent(row)) return;
    final before = row.entry.accountId;
    final selected = await showFinanceAccountPickerPanel(
      context: context,
      accounts: ref
          .read(financeNameServiceProvider)
          .accountReferences
          .values
          .toList(),
      selectedId: before,
      title: '选择${_cfg.accountLabel}',
    );
    if (selected == null ||
        !_entryCurrent(row) ||
        row.entry.accountId != before) {
      return;
    }
    row.entry.accountId = selected;
    row.entry.touch();
  }

  Future<void> _importEntrySource() async {
    if (_saving || _preparingLedgerRows || !formDraftIdentityIsCurrent) return;
    final selected = _grid.selectedRows;
    if (selected.length > 1) {
      context.appWarning('请选一行作为引用入口；引用后可继续添加其他往来单位');
      return;
    }
    final row =
        selected.firstOrNull ??
        _grid.rows
            .where(
              (row) =>
                  row.appliedLedgerId == null && row.entry.salesOrderId == null,
            )
            .lastOrNull;
    if (row != null) return _pickEntrySource(row);
    final added = _newEntryRow();
    _grid.addRow(added);
    await _pickEntrySource(added);
  }

  Future<void> _pickEntrySource(FinanceGridRow target) async {
    if (!_entryCurrent(target) || _preparingLedgerRows) return;
    if (target.entry.receiptKind == _receiptKindCustomerPrepayment) {
      final checkpoint = JsonValueSnapshot.capture(target.entry.toJson());
      final order = await showSalesOrderPicker(context, ref);
      if (order == null ||
          !_entryCurrent(target) ||
          !checkpoint.matches(target.entry.toJson())) {
        return;
      }
      final permissions = ref.read(currentPermissionsProvider);
      if (!permissions.contains(Perm.financeViewAll) ||
          !permissions.contains(Perm.customerPrepaymentView)) {
        return;
      }
      target.entry.salesOrderId = order.id;
      target.entry.salesOrderNo = order.billNo;
      target.entry.partyId = order.clientId;
      _changeEntryCurrency(target, order.currencyId);
      await ref
          .read(financeNameServiceProvider)
          .loadClientNames(partyReferenceIds([order.clientId]));
      return;
    }
    if (target.entry.partyId == null) await _pickEntryParty(target);
    if (!mounted || !_entryCurrent(target) || target.entry.partyId == null) {
      return;
    }
    final snapshot = JsonValueSnapshot.capture(captureFormDraftSnapshot());
    final epoch = ++_rowPreparationEpoch;
    final owner = _rowPreparationOwner(epoch, rowsRevision: _grid.rowsRevision);
    final picked = await showArApPickerDialog(
      context,
      ref,
      direction: _cfg.isClient ? 'AR' : 'AP',
      partyId: target.entry.partyId,
    );
    if (!mounted ||
        picked == null ||
        picked.isEmpty ||
        !_entryCurrent(target) ||
        !owner() ||
        !snapshot.matches(captureFormDraftSnapshot())) {
      return;
    }
    final existing = _grid.rows
        .map((row) => row.appliedLedgerId)
        .whereType<String>()
        .toSet();
    final additions = picked
        .where((item) => !existing.contains(item.ledgerId))
        .toList();
    if (additions.isEmpty) {
      context.appWarning('所选单据已在明细中');
      return;
    }
    // A populated entry is never overwritten. New picks append with its terms.
    final reuse = target.appliedLedgerId == null && target.amount.text.isEmpty;
    if (reuse &&
        additions.length > 1 &&
        (target.entry.accountAmount.text.isNotEmpty ||
            target.entry.fee.text.isNotEmpty)) {
      context.appWarning('本行已有银行金额或费用，请一次引用一条；原输入已保留');
      return;
    }
    final terms = target.entry.toJson();
    _updateEntry(() => _preparingLedgerRows = true);
    try {
      await prepareEditableGridRows(
        additions,
        create: (_) => _newEntryRow(),
        initialize: (row, item) {
          row.entry.restore({
            ...terms,
            'accountAmount': reuse ? terms['accountAmount'] : '',
            'fee': reuse ? terms['fee'] : '',
            'bankReference': terms['bankReference'],
          });
          row.applyLedger(item);
          _changeEntryCurrency(row, item.currencyId);
        },
        isCurrent: owner,
        canPublish: () => snapshot.matches(captureFormDraftSnapshot()),
        publish: (rows) {
          if (reuse) _grid.removeRows([target]);
          _grid.addRows(rows);
        },
      );
    } on UiWorkCancelled {
      return;
    } finally {
      if (mounted && epoch == _rowPreparationEpoch) {
        _updateEntry(() => _preparingLedgerRows = false);
      }
    }
  }

  Future<void> _batchFillEntries(List<ReferenceMethodOption> methods) async {
    final targets = _grid.selectedRows.toList();
    if (targets.isEmpty) {
      context.appWarning('请先勾选要批量填写的行');
      return;
    }
    final names = ref.read(financeNameServiceProvider);
    final values = FinanceEntryTerms();
    final rate = TextEditingController();
    final quantity = TextEditingController();
    final price = TextEditingController();
    final amount = TextEditingController();
    final fee = TextEditingController();
    final remark = TextEditingController();
    String? styleId;
    String? inAccountId;
    DeptSelection? department;
    bool current() =>
        formDraftIdentityIsCurrent &&
        mounted &&
        !_saving &&
        targets.every(_grid.rows.contains);
    ModalRoute<dynamic>? panelRoute;
    try {
      final confirmed = await showUtenAdaptivePanel<bool>(
        context: context,
        drawerWidth: 560,
        builder: (panelContext) {
          panelRoute = ModalRoute.of(panelContext);
          return StatefulBuilder(
            builder: (panelContext, update) => SafeArea(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  UtenPanelHeader(
                    title: '批量填写 ${targets.length} 行',
                    onClose: () => Navigator.pop(panelContext),
                  ),
                  Flexible(
                    child: SingleChildScrollView(
                      padding: const EdgeInsets.all(UtenSpacing.s16),
                      child: UtenFormGrid(
                        children: [
                          if (_cfg.hasParty)
                            UtenButton(
                              type: UtenButtonType.secondary,
                              onPressed: () async {
                                final id = await _pickEntryPartyId(
                                  panelContext,
                                  isCurrent: () =>
                                      panelContext.mounted && current(),
                                );
                                if (id == null ||
                                    !panelContext.mounted ||
                                    !current()) {
                                  return;
                                }
                                if (panelContext.mounted && current()) {
                                  update(() => values.partyId = id);
                                }
                              },
                              child: Text(
                                values.partyId == null
                                    ? '选择${_cfg.partyLabel}'
                                    : _cfg.isClient
                                    ? names.client(values.partyId)
                                    : names.supplier(values.partyId),
                              ),
                            ),
                          _entryDropdown(
                            label: _cfg.accountLabel,
                            value: values.accountId,
                            entries: names.accountEntries,
                            onChanged: (value) =>
                                update(() => values.accountId = value),
                          ),
                          if (!_cfg.isTransfer)
                            _entryDropdown(
                              label: '收付款方式',
                              value: values.methodId,
                              entries: {
                                for (final method in methods)
                                  method.id: method.name,
                              },
                              onChanged: (value) =>
                                  update(() => values.methodId = value),
                            ),
                          _entryDropdown(
                            label: '币种',
                            value: values.currencyId,
                            entries: names.currencyEntries,
                            onChanged: (value) => update(() {
                              values.currencyId = value;
                              rate.text = names.currencyIsBase(value) == true
                                  ? '1'
                                  : names.currencyReferenceRateText(value) ??
                                        '';
                            }),
                          ),
                          TextField(
                            controller: rate,
                            readOnly:
                                names.currencyIsBase(values.currencyId) == true,
                            decoration: const UtenInputDecoration(
                              InputDecoration(labelText: '汇率'),
                            ),
                          ),
                          if (_cfg.isAllocate) ...[
                            FinanceStylePicker(
                              names: names,
                              category: _cfg.type == FinanceDocType.expense
                                  ? 'EXPENSE'
                                  : 'INCOME',
                              value: styleId,
                              onChanged: (value) =>
                                  update(() => styleId = value),
                            ),
                            UtenDepartmentPicker(
                              mode: UtenDepartmentPickerMode.single,
                              treeOverride: names.departmentTree ?? const [],
                              initialSelection: department == null
                                  ? const []
                                  : [department!],
                              onChanged: (selection) => update(
                                () => department = selection.firstOrNull,
                              ),
                            ),
                            TextField(
                              controller: quantity,
                              decoration: const UtenInputDecoration(
                                InputDecoration(labelText: '数量'),
                              ),
                            ),
                            TextField(
                              controller: price,
                              decoration: const UtenInputDecoration(
                                InputDecoration(labelText: '单价'),
                              ),
                            ),
                          ],
                          TextField(
                            controller: amount,
                            decoration: const UtenInputDecoration(
                              InputDecoration(labelText: '金额'),
                            ),
                          ),
                          if (_cfg.isTransfer)
                            _entryDropdown(
                              label: '转入账户',
                              value: inAccountId,
                              entries: names.accountEntries,
                              onChanged: (value) =>
                                  update(() => inAccountId = value),
                            ),
                          if (_cfg.isSettle)
                            TextField(
                              controller: fee,
                              decoration: const UtenInputDecoration(
                                InputDecoration(labelText: '结算费用'),
                                info: '收付款产生的手续费等费用，以账户币种填写，不是本次收付款金额。',
                              ),
                            ),
                          TextField(
                            controller: remark,
                            decoration: const UtenInputDecoration(
                              InputDecoration(labelText: '行备注'),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.all(UtenSpacing.s16),
                    child: UtenButton(
                      onPressed: () => Navigator.pop(panelContext, true),
                      child: const Text('填入所选行'),
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      );
      if (!mounted || confirmed != true || !current()) return;
      if (targets.any(
        (row) =>
            (row.appliedLedgerId != null || row.entry.salesOrderId != null) &&
            ((values.partyId != null && values.partyId != row.entry.partyId) ||
                (values.currencyId != null &&
                    values.currencyId != row.entry.currencyId)),
      )) {
        context.appWarning('所选行含引用来源，往来单位和币种须与来源一致；本次未填入');
        return;
      }
      for (final row in targets) {
        if (values.partyId != null) row.entry.partyId = values.partyId;
        if (values.accountId != null) row.entry.accountId = values.accountId;
        if (values.methodId != null) row.entry.methodId = values.methodId;
        if (values.currencyId != null) {
          _changeEntryCurrency(row, values.currencyId);
        }
        if (rate.text.isNotEmpty &&
            names.currencyIsBase(row.entry.currencyId) != true) {
          row.exchangeRate.text = rate.text;
        }
        if (quantity.text.isNotEmpty) row.qty.text = quantity.text;
        if (price.text.isNotEmpty) row.price.text = price.text;
        if (amount.text.isNotEmpty) row.amount.text = amount.text;
        if (fee.text.isNotEmpty) row.entry.fee.text = fee.text;
        if (styleId != null) row.styleId = styleId;
        if (inAccountId != null) row.inAccountId = inAccountId;
        if (department != null) {
          row.setDepartment(department!.id, department!.name);
        }
        if (remark.text.isNotEmpty) row.remark.text = remark.text;
        row.entry.touch();
      }
    } finally {
      await panelRoute?.completed;
      values.dispose();
      rate.dispose();
      quantity.dispose();
      price.dispose();
      amount.dispose();
      fee.dispose();
      remark.dispose();
    }
  }

  Future<void> _entrySettlementSettings(FinanceGridRow row) async {
    if (!_entryCurrent(row)) return;
    final snapshot = JsonValueSnapshot.capture(row.entry.toJson());
    final values = FinanceEntryTerms()..restore(row.entry.toJson());
    final names = ref.read(financeNameServiceProvider);
    ModalRoute<dynamic>? panelRoute;
    try {
      final confirmed = await showUtenAdaptivePanel<bool>(
        context: context,
        drawerWidth: 600,
        builder: (panelContext) {
          panelRoute = ModalRoute.of(panelContext);
          return StatefulBuilder(
            builder: (panelContext, update) => SafeArea(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  UtenPanelHeader(
                    title: '结算设置',
                    onClose: () => Navigator.pop(panelContext),
                  ),
                  Flexible(
                    child: SingleChildScrollView(
                      padding: const EdgeInsets.all(UtenSpacing.s16),
                      child: UtenFormGrid(
                        children: [
                          TextField(
                            key: const ValueKey('finance-entry-settlement-fee'),
                            controller: values.fee,
                            keyboardType: const TextInputType.numberWithOptions(
                              decimal: true,
                            ),
                            decoration: UtenInputDecoration(
                              InputDecoration(
                                labelText:
                                    '结算费用（${names.currency(names.accountCurrencyId(values.accountId))}）',
                              ),
                              info: _cfg.isClient
                                  ? '收款产生的手续费等费用。同币种从到账扣除时，实际入账＝本次收款金额－结算费用；费用另付不扣减到账金额。跨币种按银行实际金额填写。'
                                  : '付款产生的手续费等费用。同币种时，实际扣款＝本次付款金额＋结算费用；跨币种按银行实际金额填写。',
                            ),
                          ),
                          TextField(
                            key: const ValueKey(
                              'finance-entry-settlement-account-amount',
                            ),
                            controller: values.accountAmount,
                            keyboardType: const TextInputType.numberWithOptions(
                              decimal: true,
                            ),
                            decoration: UtenInputDecoration(
                              InputDecoration(
                                labelText:
                                    '${_cfg.isClient ? '实际入账' : '实际扣款'}（${names.currency(names.accountCurrencyId(values.accountId))}）',
                              ),
                              info:
                                  '银行账户实际发生的金额。同币种留空时根据本次收付款金额和费用自动计算；跨币种须按银行实际金额填写。',
                            ),
                          ),
                          if (_cfg.isClient) ...[
                            _entryDropdown(
                              label: '收款渠道',
                              value: values.channel,
                              entries: const {
                                _settlementChannelDirect: '公司账户直收',
                                _settlementChannelAgent: '外贸代理结汇',
                              },
                              onChanged: (value) => update(
                                () => values.channel =
                                    value ?? _settlementChannelDirect,
                              ),
                            ),
                            if (values.channel == _settlementChannelAgent) ...[
                              UtenButton(
                                type: UtenButtonType.secondary,
                                onPressed: () async {
                                  final supplier = await resolvePickedParty(
                                    ref,
                                    () => showUtenSupplierPicker(
                                      panelContext,
                                      ref,
                                    ),
                                    idOf: (party) => party.id,
                                    loadNames: names.loadSupplierNames,
                                    isResolved:
                                        names.supplierReferenceSelectable,
                                    isCurrent: () =>
                                        panelContext.mounted &&
                                        _entryCurrent(row),
                                  );
                                  if (supplier == null ||
                                      !panelContext.mounted ||
                                      !_entryCurrent(row)) {
                                    return;
                                  }
                                  if (panelContext.mounted &&
                                      _entryCurrent(row)) {
                                    update(() => values.agentId = supplier.id);
                                  }
                                },
                                child: Text(
                                  values.agentId == null
                                      ? '选择外贸代理'
                                      : names.supplier(values.agentId),
                                ),
                              ),
                              TextField(
                                controller: values.agentStatement,
                                decoration: const UtenInputDecoration(
                                  InputDecoration(labelText: '代理结算单号'),
                                ),
                              ),
                            ],
                            _entryDropdown(
                              label: '费用结算',
                              value: values.feeMode == _feeModeNone
                                  ? _feeModeDeducted
                                  : values.feeMode,
                              entries: const {
                                _feeModeDeducted: '从到账扣除',
                                _feeModeSeparate: '费用另付',
                              },
                              onChanged: (value) => update(
                                () =>
                                    values.feeMode = value ?? _feeModeDeducted,
                              ),
                            ),
                            if (values.feeMode == _feeModeSeparate)
                              _entryDropdown(
                                label: '费用付款账户',
                                value: values.feeAccountId,
                                entries: names.accountEntries,
                                onChanged: (value) =>
                                    update(() => values.feeAccountId = value),
                              ),
                          ],
                          UtenButton(
                            type: UtenButtonType.secondary,
                            onPressed: () async {
                              final next = await _pickWallDateTime(
                                values.bookedAt,
                              );
                              if (next != null &&
                                  panelContext.mounted &&
                                  _entryCurrent(row)) {
                                update(() => values.bookedAt = next);
                              }
                            },
                            child: Text(
                              '银行记账时间 ${_fmt(values.bookedAt)} ${values.bookedAt.hour.toString().padLeft(2, '0')}:${values.bookedAt.minute.toString().padLeft(2, '0')}',
                            ),
                          ),
                          if (_cfg.isClient)
                            UtenButton(
                              type: UtenButtonType.secondary,
                              onPressed: () async {
                                final next = await _pickWallDateTime(
                                  values.rateEffectiveAt,
                                );
                                if (next != null &&
                                    panelContext.mounted &&
                                    _entryCurrent(row)) {
                                  update(() => values.rateEffectiveAt = next);
                                }
                              },
                              child: Text(
                                '汇率生效时间 ${_fmt(values.rateEffectiveAt)}',
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.all(UtenSpacing.s16),
                    child: UtenButton(
                      onPressed: () => Navigator.pop(panelContext, true),
                      child: const Text('保存设置'),
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      );
      if (confirmed == true &&
          _entryCurrent(row) &&
          snapshot.matches(row.entry.toJson())) {
        row.entry.restore(values.toJson());
      }
    } finally {
      await panelRoute?.completed;
      values.dispose();
    }
  }

  Future<void> _applyEntryPrepayment() async {
    final rows = _grid.selectedRows;
    if (rows.length != 1 || rows.single.entry.partyId == null) {
      context.appWarning('请选择一行已填客户的明细');
      return;
    }
    final result = await showCustomerPrepaymentApplyPanel(
      context,
      clientId: rows.single.entry.partyId!,
    );
    if (!mounted || !formDraftIdentityIsCurrent || result == null) return;
    bumpListRefresh(ref, _cfg.refreshKey);
    context.appSuccess('预收抵扣已处理，请按最新余额引用应收');
  }

  Future<void> _saveEntryBatch() async {
    if (_saving ||
        _intakeBusy ||
        _preparingLedgerRows ||
        _loading ||
        _initializationError != null ||
        !formDraftIdentityIsCurrent) {
      return;
    }
    if (!ref.read(currentPermissionsProvider).contains(_cfg.createPerm)) return;
    if (_createdBatchIds.isNotEmpty) {
      await _finishEntryBatch();
      return;
    }
    final documents = <Map<String, dynamic>>[];
    final names = ref.read(financeNameServiceProvider);
    if (_batchCommand == null) {
      for (final row in _grid.rows) {
        if (_entryIsBlank(row)) continue;
        try {
          if (row.entry.receiptKind == _receiptKindCustomerPrepayment) {
            final permissions = ref.read(currentPermissionsProvider);
            if (!permissions.contains(Perm.financeViewAll) ||
                !permissions.contains(Perm.customerPrepaymentView)) {
              throw const FinanceEntryError('当前无登记订单预收权限', 'entryKind');
            }
          }
          documents.add(
            financeEntryRequest(
              row,
              config: _cfg,
              names: names,
              billDate: _fmt(_billDate),
              commandKey: '$_createIdempotencyKey.${documents.length}',
              operatorId: _operatorId,
              remark: _remark.text.trim(),
              requireMethod: _financeMethodOptionsAvailable,
            ),
          );
        } on FinanceEntryError catch (error) {
          if (!mounted) return;
          context.appError(
            '第 ${_grid.rows.indexOf(row) + 1} 行：${error.message}',
          );
          final settlementError = const {
            'entryFee',
            'entryAccountAmount',
            'entrySettings',
          }.contains(error.column);
          await _grid.revealError(
            row,
            columnKey: settlementError ? 'entrySettings' : error.column,
          );
          if (settlementError && _entryCurrent(row)) {
            await _entrySettlementSettings(row);
          }
          return;
        }
      }
      if (!mounted) return;
      if (documents.isEmpty) {
        context.appError('请至少填写一条明细');
        return;
      }
      _batchCommand = {
        'idempotencyKey': _createIdempotencyKey,
        'documents': documents,
      };
    }
    _updateEntry(() => _saving = true);
    final wasUnknown = formDraftHasUnknownSubmission;
    try {
      await saveFormDraftNow();
      final result = await runFormDraftSubmission(
        () => ref
            .read(financeRepositoryProvider(widget.docType))
            .createBatch(_batchCommand!),
        isDefiniteRejection: (error) =>
            !wasUnknown &&
            (error.httpStatus == 400 ||
                error.httpStatus == 422 ||
                (error.httpStatus == 409 && error.code == 'CONFLICT')),
      );
      if (!mounted || !formDraftIdentityIsCurrent) return;
      if (result.isEmpty) throw StateError('批次未返回创建结果');
      _updateEntry(
        () => _createdBatchIds = result.map((doc) => doc.id).toList(),
      );
      await checkpointFormDraftAfterCreation();
      if (!mounted || !formDraftIdentityIsCurrent) return;
      bumpListRefresh(ref, _cfg.refreshKey);
      context.appSuccess('已生成 ${result.length} 张${_cfg.label}');
      await _finishEntryBatch();
    } on ApiException catch (error) {
      if (!formDraftHasUnknownSubmission) {
        _batchCommand = null;
        await saveFormDraftNow();
      }
      if (mounted) context.appError(error.message);
    } catch (error, stack) {
      debugPrint('钱流批量创建失败: $error\n$stack');
      if (mounted) {
        context.appError(describeFormSaveError(error) ?? '保存结果待核对，请保留草稿后重试原批次');
      }
    } finally {
      if (mounted) _updateEntry(() => _saving = false);
    }
  }

  Future<void> _finishEntryBatch() async {
    _updateEntry(() => _saving = true);
    try {
      final done = await flushPendingAttachments(
        context,
        ref,
        _pendingFiles,
        ownerType: _attachmentOwnerType,
        ownerIds: _createdBatchIds,
        canContinue: () => mounted && formDraftIdentityIsCurrent,
        persistCheckpoint: saveFormDraftNow,
      );
      if (!mounted || !formDraftIdentityIsCurrent || !done) return;
      await completeFormDraft();
      if (!mounted) return;
      context.replace(
        _createdBatchIds.length == 1
            ? '${_cfg.listLocation}/${_createdBatchIds.single}'
            : _cfg.listLocation,
      );
    } finally {
      if (mounted) _updateEntry(() => _saving = false);
    }
  }

  bool _entryIsBlank(FinanceGridRow row) =>
      row.entry.partyId == null &&
      row.entry.accountId == null &&
      row.entry.methodId == null &&
      row.appliedLedgerId == null &&
      row.entry.salesOrderId == null &&
      row.styleId == null &&
      row.inAccountId == null &&
      row.department.text.isEmpty &&
      row.qty.text.isEmpty &&
      row.price.text.isEmpty &&
      row.amount.text.isEmpty &&
      row.remark.text.isEmpty &&
      row.entry.fee.text.isEmpty &&
      row.entry.accountAmount.text.isEmpty &&
      row.entry.bankReference.text.isEmpty &&
      row.entry.currencyId == null &&
      row.exchangeRate.text.isEmpty &&
      row.entry.agentId == null &&
      row.entry.agentStatement.text.isEmpty &&
      row.entry.feeAccountId == null &&
      row.entry.receiptKind == _receiptKindArSettlement &&
      row.occurDate == null;

  Widget _entryBatchTotals(FinanceNameService names) => ListenableBuilder(
    listenable: Listenable.merge([_grid, _entryDraftRevision, names]),
    builder: (context, _) {
      final totals = <String, List<String>>{};
      final groups = <String>{};
      var incomplete = 0;
      for (final row in _grid.rows.where((row) => !_entryIsBlank(row))) {
        (totals[row.entry.currencyId ?? ''] ??= []).add(row.amount.text);
        try {
          groups.add(
            financeEntryGroupKey(
              financeEntryRequest(
                row,
                config: _cfg,
                names: names,
                billDate: _fmt(_billDate),
                commandKey: _createIdempotencyKey,
                operatorId: _operatorId,
                remark: _remark.text.trim(),
                requireMethod: _financeMethodOptionsAvailable,
              ),
            ),
          );
        } on FinanceEntryError {
          incomplete++;
        }
      }
      return UtenTotalsSummaryBar(
        key: const ValueKey('finance-entry-totals'),
        compact: true,
        rowCount: _grid.length,
        entries: [
          UtenTotalEntry('预计生成', '${groups.length} 张单据'),
          if (incomplete > 0) UtenTotalEntry('待填写', '$incomplete 行'),
          for (final entry in totals.entries)
            UtenTotalEntry(
              utenAmountTotalLabel(
                entry.key.isEmpty ? '未选币种' : names.currency(entry.key),
              ),
              entry.value.every((amount) => financeAmountUnits(amount) != null)
                  ? exactAmountSumText(entry.value)
                  : '待填写',
              danger: true,
            ),
        ],
      );
    },
  );

  Widget _freezeEntry({required bool absorbing, required Widget child}) =>
      AbsorbPointer(
        absorbing: absorbing,
        child: ExcludeFocus(excluding: absorbing, child: child),
      );

  Widget _buildEntryBatch(
    FinanceNameService names,
    List<ReferenceMethodOption> methods,
    bool canPrepay,
    bool canApplyPrepayment,
  ) {
    final frozen =
        _saving || _batchCommand != null || _createdBatchIds.isNotEmpty;
    return withFormDraft(
      Scaffold(
        appBar: UtenAppBar(
          title: '新建${_cfg.label}',
          leading: UtenBackButton(
            onPressed: () =>
                popOrBackTo(context, defaultPath: RouteName.finance),
          ),
          actions: [..._draftsAction],
        ),
        body: SafeArea(
          child: Stack(
            children: [
              if (_loading)
                const Center(child: CircularProgressIndicator())
              else if (_initializationError != null)
                UtenEmpty.error(
                  message: '${_cfg.label}加载失败',
                  description: _initializationError!,
                  actionLabel: '重试',
                  onAction: _init,
                )
              else
                UtenGridPageScrollbar(
                  pinned: _gridPinned,
                  controller: _scrollCtl,
                  child: UtenContentContainer(
                    child: ListView(
                      controller: _scrollCtl,
                      padding: const EdgeInsets.fromLTRB(
                        UtenSpacing.s12,
                        UtenSpacing.s12,
                        UtenSpacing.s12,
                        UtenFloatingActionGroup.scrollClearance,
                      ),
                      children: [
                        _freezeEntry(
                          absorbing: frozen,
                          child: _entryCard(
                            child: UtenFormGrid(
                              children: [
                                UtenDateField(
                                  label: '单据日期',
                                  required: true,
                                  value: _billDate,
                                  onChanged: (value) =>
                                      _updateEntry(() => _billDate = value),
                                ),
                                _employeePicker(
                                  label: '经办人',
                                  currentId: _operatorId,
                                  onChanged: (value) =>
                                      _updateEntry(() => _operatorId = value),
                                ),
                                if (_cfg.hasParty)
                                  ListenableBuilder(
                                    listenable: Listenable.merge([
                                      _grid,
                                      for (final row in _grid.rows) row.entry,
                                    ]),
                                    builder: (context, _) => InputDecorator(
                                      decoration: UtenInputDecoration(
                                        InputDecoration(
                                          labelText: '本批${_cfg.partyLabel}',
                                        ),
                                      ),
                                      child: UtenMultiValueCell(
                                        title: '本批${_cfg.partyLabel}',
                                        values: _grid.rows
                                            .map((row) => row.entry.partyId)
                                            .whereType<String>()
                                            .toSet()
                                            .map(
                                              (id) => _cfg.isClient
                                                  ? names.client(id)
                                                  : names.supplier(id),
                                            )
                                            .toList(),
                                      ),
                                    ),
                                  ),
                                TextField(
                                  controller: _remark,
                                  decoration: const UtenInputDecoration(
                                    InputDecoration(labelText: '整批备注'),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                        const SizedBox(height: UtenSpacing.s12),
                        _freezeEntry(
                          absorbing:
                              frozen || _preparingLedgerRows || _intakeBusy,
                          child: UtenEditableGrid<FinanceGridRow>(
                            tableKey: 'finance.${widget.docType.name}.entry.v1',
                            columnEditingEnabled: !frozen,
                            controller: _grid,
                            selectable: true,
                            stickyHeaderPinned: _gridPinned,
                            columns: financeEntryColumns(
                              context: context,
                              config: _cfg,
                              names: names,
                              methods: methods,
                              canPrepay: canPrepay,
                              pickParty: _pickEntryParty,
                              pickAccount: _pickEntryAccount,
                              pickSource: _pickEntrySource,
                              settings: _entrySettlementSettings,
                              changeCurrency: _changeEntryCurrency,
                            ),
                            createBlankRow: _newEntryRow,
                            cloneRow: (row) => row.clone(),
                            toolbarActions: [
                              if (_cfg.isSettle)
                                UtenImportButton(
                                  label: _cfg.isClient ? '引用应收' : '引用应付',
                                  compactLabel: _cfg.isClient ? '引用应收' : '引用应付',
                                  onPressed: _importEntrySource,
                                ),
                              UtenButton(
                                type: UtenButtonType.secondary,
                                icon: Icons.edit_note_rounded,
                                onPressed: () => _batchFillEntries(methods),
                                child: const Text('批量填写'),
                              ),
                              if (canApplyPrepayment)
                                UtenButton(
                                  type: UtenButtonType.secondary,
                                  onPressed: _applyEntryPrepayment,
                                  child: const Text('预收抵扣'),
                                ),
                              if (_canUseIntake)
                                UtenButton(
                                  type: UtenButtonType.secondary,
                                  onPressed: _recognizeEntryReceipt,
                                  child: const Text('识别银行回单'),
                                ),
                            ],
                            rowMenuExtraBuilder: (_, selected) => [
                              UtenMenuItem(
                                label: '批量填写 (${selected.length})',
                                icon: Icons.edit_note_rounded,
                                enabled: selected.isNotEmpty,
                                onTap: () => _batchFillEntries(methods),
                              ),
                            ],
                            footer: _entryBatchTotals(names),
                            emptyMessage: '点击“添加行”开始录入',
                          ),
                        ),
                        const SizedBox(height: UtenSpacing.s12),
                        if (_createdBatchIds.isNotEmpty)
                          PendingAttachmentRetryNotice(
                            documentLabel: _cfg.label,
                            controller: _pendingFiles,
                          ),
                        BusinessAttachmentSection.draft(
                          controller: _pendingFiles,
                          canManage:
                              !_saving &&
                              ref
                                  .watch(currentPermissionsProvider)
                                  .contains(_cfg.createPerm),
                          title: '单据和凭证',
                          categories: const ['银行回单', '发票', '其他凭证'],
                        ),
                      ],
                    ),
                  ),
                ),
              if (_saving || _preparingLedgerRows)
                UtenBusyOverlay(
                  title: _saving ? '正在创建单据' : '正在引入明细',
                  description: '请稍候',
                ),
            ],
          ),
        ),
        floatingActionButtonLocation: FloatingActionButtonLocation.endFloat,
        floatingActionButtonAnimator: FloatingActionButtonAnimator.noAnimation,
        floatingActionButton: _loading || _initializationError != null
            ? null
            : UtenEditFloatingActions(
                onCancel: () =>
                    popOrBackTo(context, defaultPath: RouteName.finance),
                onSave: _intakeBusy || _preparingLedgerRows
                    ? null
                    : _saveEntryBatch,
                saving: _saving,
              ),
      ),
    );
  }

  Future<void> _recognizeEntryReceipt() async {
    final selected = _grid.selectedRows;
    if (selected.length != 1) {
      context.appWarning('请选一行后识别该行的银行回单');
      return;
    }
    // The established intake validates identity, snapshot, file hash and account
    // currency. Its optional target makes the same protocol apply to a row.
    await _recognizeBankReceipt(entry: selected.single);
  }
}
