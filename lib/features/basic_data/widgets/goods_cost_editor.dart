part of 'goods_cost_tab.dart';

extension _GoodsCostEditor on _GoodsCostTabState {
  /// Local controllers outlive the reverse dialog animation. Navigator's pop
  /// future alone completes before the text fields leave the overlay.
  Future<T?> _dialogWhenRemoved<T>({
    required BuildContext context,
    required WidgetBuilder builder,
  }) async {
    final route = DialogRoute<T>(context: context, builder: builder);
    final value = await Navigator.of(context, rootNavigator: true).push(route);
    await route.completed;
    return value;
  }

  Future<void> _loadClientContext() async {
    final id = costText(_input['clientId']);
    final request = ++_templateRequest;
    final frozenName = costText(
      costMap(_input['extraFields'])['serverClientName'],
    );
    if (frozenName != null && frozenName.isNotEmpty) {
      if (mounted) setState(() => _clientName = frozenName);
      if (_sheet?.status != 'DRAFT' || _historical != null) return;
    }
    try {
      final client = id == null
          ? null
          : await ref.read(clientRepositoryProvider).detail(id);
      final templates = await _repository.templates(widget.detail.id, id);
      if (mounted &&
          _capability.canRead &&
          request == _templateRequest &&
          _input['clientId'] == id) {
        setState(() {
          _clientName = frozenName ?? client?.name;
          _templates = templates;
        });
      }
    } catch (e) {
      if (mounted && request == _templateRequest && _input['clientId'] == id) {
        setState(() => _error = _message(e));
      }
    }
  }

  void _adoptTemplateSuggestions(GoodsCostCalculation calculation) {
    _replacingFees = true;
    try {
      final existingRows = {
        for (final row in _feeGrid.rows) row.json['key']: row,
      };
      final templateInputs = calculation.resolvedInput == null
          ? calculation.fees
          : costMaps(calculation.resolvedInput!['fees']);
      for (final result in [
        ...templateInputs.where(
          (f) => costText(f['source'])?.startsWith('TEMPLATE:') == true,
        ),
        ...calculation.fees.where((f) => f['source'] == 'PRICE_COLUMN'),
      ]) {
        final existing = existingRows[result['key']];
        final input = <String, dynamic>{
          for (final key in [
            'key',
            'name',
            'type',
            'category',
            'targetPath',
            'value',
            'quantity',
            'baseKeys',
            'source',
            'reason',
          ])
            key: result[key],
        };
        if (existing == null) {
          _feeGrid.addRow(GoodsCostFeeRow(input));
        } else if (existing.generated ||
            costText(existing.json['source'])?.startsWith('TEMPLATE:') ==
                true) {
          existing.adoptSuggestion(input);
        }
      }
      final currentKeys = calculation.fees.map((f) => f['key']).toSet();
      for (var i = _feeGrid.length - 1; i >= 0; i--) {
        if ((_feeGrid[i].generated ||
                costText(_feeGrid[i].json['source'])?.startsWith('TEMPLATE:') ==
                    true) &&
            !currentKeys.contains(_feeGrid[i].json['key'])) {
          _feeGrid.removeAt(i);
        }
      }
    } finally {
      _replacingFees = false;
    }
  }

  void _syncRecommendedCells(GoodsCostCalculation calculation) {
    final overrides = {
      for (final row in costMaps(_input['lineOverrides'])) row['path']: row,
    };
    for (final row in calculation.lines) {
      final path = row['path'].toString();
      for (final field in ['adoptedQty', 'unitPrice']) {
        if (field == 'unitPrice') {
          if (normalizedCostPriceOverride(
            overrides[path],
            costText(_input['exchangeRateToLocal']),
          )) {
            continue;
          }
        } else if (overrides[path]?[field] != null) {
          continue;
        }
        final controller = _controllers['$path:$field'];
        final next = costText(row[field]) ?? '';
        if (controller != null && controller.text != next) {
          controller.text = next;
        }
      }
    }
  }

  void _removeFee(GoodsCostFeeRow row, int index) {
    if (row.generated) {
      final path = row.json['targetPath'].toString(), key = row.columnKey;
      _input = updateCostPriceCell(
        _currentInput(),
        path,
        key,
        null,
        applicable: false,
      );
      _controllers['fee:$key:$path']?.clear();
      _controllers['feeQty:$key:$path']?.clear();
    }
    if (costText(row.json['source'])?.startsWith('TEMPLATE:') == true) {
      final extra = costMap(_input['extraFields']);
      List<dynamic> excluded;
      try {
        excluded =
            jsonDecode(costText(extra['costExcludedFeeKeys']) ?? '[]')
                as List<dynamic>;
      } catch (_) {
        excluded = [];
      }
      extra['costExcludedFeeKeys'] = jsonEncode(
        {...excluded, row.json['key']}.toList(),
      );
      _input['extraFields'] = extra;
    }
    _feeGrid.removeAt(index);
  }

  Future<void> _importWorkbook() async {
    final adopted = await _action(() async {
      final selected = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: const ['xlsx', 'xls'],
        withData: true,
      );
      final file = selected?.files.firstOrNull;
      if (file?.bytes == null || !mounted) return null;
      final preview = await _repository.importPreview(
        widget.detail.id,
        file!.bytes!,
        file.name,
      );
      if (!mounted) return null;
      final mapping = await showDialog<Map<String, dynamic>>(
        context: context,
        builder: (_) => GoodsCostImportDialog(
          preview: preview,
          lines: _calculation?.lines ?? [],
        ),
      );
      if (mapping == null) return null;
      return _repository.importApply({...mapping, 'input': _currentInput()});
    });
    if (adopted == null || !mounted) return;
    _change(() {
      _input = copyCostJson(costMap(adopted['input']));
      _calculation = GoodsCostCalculation(costMap(adopted['calculation']));
      _resetEditors();
    });
  }

  Future<void> _compareVersions() async {
    final current = _calculation;
    if (current == null || _versions.isEmpty) return;
    String? baselineId;
    GoodsCostCalculation? baseline;
    String? error;
    bool loading = false;
    final keys = [
      'goodsName',
      'goodsCode',
      'unitName',
      'adoptedQty',
      'unitPrice',
      'unitContribution',
      'amount',
    ];
    final labels = [
      _l.costGoodsName,
      _l.costGoodsCode,
      _l.costUnit,
      _l.costAdoptedQty,
      _l.costPrice,
      _l.costUnitContribution,
      _l.costLineAmount,
    ];
    List<UtenRevisionRow<Map<String, dynamic>>> rows() {
      final old = {
        for (final r in baseline?.lines ?? <Map<String, dynamic>>[])
          r['path']: r,
      };
      final next = {for (final r in current.lines) r['path']: r};
      final result = <UtenRevisionRow<Map<String, dynamic>>>[];
      for (final path in {...old.keys, ...next.keys}) {
        final before = old[path], after = next[path];
        final changed = {
          for (final k in keys)
            if (before?[k] != after?[k]) k,
        };
        if (before != null && after != null && changed.isEmpty) {
          result.add(
            UtenRevisionRow(
              value: after,
              kind: UtenRevisionKind.unchanged,
              label: _l.costUnchanged,
            ),
          );
        } else {
          if (before != null) {
            result.add(
              UtenRevisionRow(
                value: before,
                kind: UtenRevisionKind.removed,
                label: _l.costBefore,
                changedKeys: changed,
              ),
            );
          }
          if (after != null) {
            result.add(
              UtenRevisionRow(
                value: after,
                kind: UtenRevisionKind.added,
                label: _l.costAfter,
                changedKeys: changed,
              ),
            );
          }
        }
      }
      return result;
    }

    await showDialog<void>(
      context: context,
      builder: (dialog) => StatefulBuilder(
        builder: (context, update) => AlertDialog(
          title: Text(_l.costCompare),
          content: SizedBox(
            width: 1400,
            height: MediaQuery.sizeOf(context).height * .72,
            child: Column(
              children: [
                UtenDropdownField(
                  label: _l.costCompareBefore,
                  value: baselineId,
                  items: [
                    for (final version in _versions)
                      UtenDropdownItem(
                        value: costText(version['id']),
                        label:
                            '${version['name'] ?? ''} · ${_l.costVersion} ${version['version']} · ${version['batchQty']}',
                      ),
                  ],
                  onChanged: (id) async {
                    if (id == null) return;
                    update(() {
                      baselineId = id;
                      loading = true;
                      error = null;
                    });
                    try {
                      final sheet = await _repository.detail(id);
                      if (context.mounted) {
                        update(() => baseline = sheet.calculation);
                      }
                    } catch (e) {
                      if (context.mounted) update(() => error = _message(e));
                    } finally {
                      if (context.mounted) update(() => loading = false);
                    }
                  },
                ),
                if (loading) const LinearProgressIndicator(),
                if (error != null) Text(error!),
                const SizedBox(height: 12),
                Expanded(
                  child: UtenRevisionTable<Map<String, dynamic>>(
                    tableKey: 'master.goods.cost.comparison',
                    rows: rows(),
                    columns: [
                      for (var i = 0; i < keys.length; i++)
                        _readColumn(keys[i], labels[i], i == 0 ? 260 : 150),
                    ],
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialog),
              child: Text(_l.commonBack),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _convertCostCurrency(
    String? targetId, {
    bool editRate = false,
  }) async {
    if (!_editable || (!editRate && targetId == _input['currencyId'])) return;
    _debounce?.cancel();
    _previewRequest++;
    setState(() => _calculating = false);
    final currentId = costText(_input['currencyId']);
    final currentCurrency = _currencies
        .where((c) => c.id == currentId)
        .firstOrNull;
    final targetCurrency = _currencies
        .where((c) => c.id == targetId)
        .firstOrNull;
    final sameCurrency = currentId == targetId;
    final oldRate = costText(_input['exchangeRateToLocal']);
    final needsSource = !positiveCostRate(oldRate);
    final targetIsBase =
        targetId == null || targetCurrency?.baseCurrency == true;
    final target = TextEditingController(
      text: targetIsBase
          ? '1'
          : sameCurrency
          ? oldRate ?? ''
          : targetCurrency?.exchangeRateText ?? '',
    );
    final source = TextEditingController(
      text: currentId == null || currentCurrency?.baseCurrency == true
          ? '1'
          : oldRate ?? '',
    );
    final form = GlobalKey<FormState>();
    String? rateValidator(String? value) =>
        positiveCostRate(value) ? null : _l.costExchangeRateRequired;
    final accepted = await _dialogWhenRemoved<bool>(
      context: context,
      builder: (dialog) => AlertDialog(
        title: Text(_l.costConvertCurrency),
        content: SizedBox(
          width: 520,
          child: Form(
            key: form,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  '${currentCurrency?.name ?? costText(_calculation?.json['currencyName']) ?? _l.costCurrency} → ${targetCurrency?.name ?? _l.costCurrency}',
                ),
                const SizedBox(height: 12),
                Text(_l.costCurrencyConversionHint),
                const SizedBox(height: 16),
                if (needsSource && !sameCurrency) ...[
                  TextFormField(
                    key: const Key('cost-convert-source-rate'),
                    controller: source,
                    keyboardType: const TextInputType.numberWithOptions(
                      decimal: true,
                    ),
                    validator: rateValidator,
                    errorBuilder: utenTextFieldErrorBuilder,
                    decoration: UtenInputDecoration(
                      InputDecoration(labelText: _l.costSourceExchangeRate),
                    ),
                  ),
                  const SizedBox(height: 12),
                ],
                TextFormField(
                  key: const Key('cost-convert-target-rate'),
                  controller: target,
                  readOnly: targetIsBase,
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                  ),
                  validator: rateValidator,
                  errorBuilder: utenTextFieldErrorBuilder,
                  decoration: UtenInputDecoration(
                    InputDecoration(labelText: _l.costTargetExchangeRate),
                  ),
                ),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialog, false),
            child: Text(_l.commonCancel),
          ),
          TextButton(
            key: const Key('cost-currency-convert-confirm'),
            onPressed: () {
              if (form.currentState?.validate() == true) {
                Navigator.pop(dialog, true);
              }
            },
            child: Text(_l.commonConfirm),
          ),
        ],
      ),
    );
    final targetRate = target.text.trim(),
        sourceRate = needsSource
            ? (sameCurrency ? target.text.trim() : source.text.trim())
            : oldRate!;
    target.dispose();
    source.dispose();
    if (accepted != true || !mounted) {
      if (mounted && _stale) unawaited(_preview());
      return;
    }
    final converted = await _action<bool>(() async {
      final payload = copyCostJson(_currentInput());
      if (needsSource) payload['exchangeRateToLocal'] = sourceRate;
      final result = await _repository.convertCurrency(
        payload,
        targetId,
        targetRate,
      );
      if (!mounted) return false;
      final convertedInput = costMap(result['input']);
      if (convertedInput['goodsId'] != widget.detail.id ||
          convertedInput['clientId'] != _input['clientId']) {
        throw StateError(_l.commonError);
      }
      setState(
        () => _adoptCurrencyConversion(
          convertedInput,
          GoodsCostCalculation(costMap(result['calculation'])),
        ),
      );
      return true;
    });
    if (converted == true && mounted) {
      context.appSuccess(_l.costCurrencyConverted);
    }
  }

  void _adoptCurrencyConversion(
    Map<String, dynamic> input,
    GoodsCostCalculation calculation,
  ) {
    _input = copyCostJson(input);
    _calculation = calculation;
    _dirty = true;
    _inputRevision++;
    _calculatedRevision = _inputRevision;
    _saveKey = const Uuid().v4();
    _confirmKey = null;
    _copyKey = null;
    _controllers['header:exchangeRateToLocal']?.text =
        costText(_input['exchangeRateToLocal']) ?? '';
    final overrides = {
      for (final line in costMaps(_input['lineOverrides'])) line['path']: line,
    };
    for (final row in calculation.lines) {
      final controller = _controllers['${row['path']}:unitPrice'];
      final next =
          costUnitPriceEditorText(
            row,
            overrides[row['path']],
            costText(_input['exchangeRateToLocal']),
          ) ??
          '';
      if (controller != null && controller.text != next) controller.text = next;
    }
    for (final cell in costMaps(_input['priceCells'])) {
      final controller =
          _controllers['fee:${cell['columnKey']}:${cell['path']}'];
      final next = costText(cell['value']) ?? '';
      if (controller != null && controller.text != next) controller.text = next;
    }
    final desired = {
      for (final fee in costMaps(_input['fees'])) fee['key']: fee,
      for (final fee in calculation.fees.where(
        (f) => f['source'] == 'PRICE_COLUMN',
      ))
        fee['key']: fee,
    };
    _replacingFees = true;
    try {
      for (var index = _feeGrid.length - 1; index >= 0; index--) {
        final row = _feeGrid[index],
            next = desired.remove(_feeGrid[index].json['key']);
        if (next == null) {
          _feeGrid.removeAt(index);
        } else {
          row.adoptConverted(next);
        }
      }
      _feeGrid.addRows(desired.values.map(GoodsCostFeeRow.new));
    } finally {
      _replacingFees = false;
    }
  }

  Widget _customerField() => AbsorbPointer(
    absorbing: !_editable,
    child: ClientPickerField(
      label: _l.costCustomer,
      initialId: costText(_input['clientId']),
      initialName: _clientName,
      onChanged: (id) {
        if (!_editable) return;
        _change(() {
          _input = _currentInput();
          _input['clientId'] = id;
          final extras = costMap(_input['extraFields'])
            ..remove('serverClientName');
          _input['extraFields'] = extras;
          _input['templateId'] = null;
          _templates = [];
          if (id == null) _clientName = null;
          _input['fees'] = costMaps(_input['fees'])
              .where(
                (f) => costText(f['source'])?.startsWith('TEMPLATE:') != true,
              )
              .toList();
          _resetEditors();
        });
        unawaited(_loadClientContext());
      },
      onPick: () async {
        final revision = _inputRevision;
        final client = await showUtenClientPicker(context, ref);
        if (!mounted || !_editable || revision != _inputRevision) return null;
        if (client != null) _clientName = client.name;
        return client;
      },
    ),
  );
  Widget _header() => LayoutBuilder(
    builder: (context, box) => Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(vertical: UtenSpacing.s4),
          child: Wrap(
            spacing: UtenSpacing.s12,
            runSpacing: UtenSpacing.s4,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Text(
                (costText(_calculation?.json['unitName']) ?? '').isEmpty
                    ? _l.costEstimateBasisWithoutUnit(
                        costText(_input['batchQty']) ?? '—',
                      )
                    : _l.costEstimateBasis(
                        costText(_input['batchQty']) ?? '—',
                        costText(_calculation?.json['unitName'])!,
                      ),
                key: const Key('cost-estimate-basis'),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.titleMedium,
              ),
              if (_sheet != null)
                _oneLine('${_sheet!.number} · ${_status(_sheet!.status)}'),
              if ((_clientName ?? '').isNotEmpty)
                Tooltip(message: _l.costCustomer, child: _oneLine(_clientName)),
              if (_historical != null) _oneLine(_l.costSnapshotReadOnly),
              if (_historical == null &&
                  (_sheet == null || _sheet!.status == 'DRAFT'))
                ConstrainedBox(
                  constraints: BoxConstraints(
                    maxWidth: box.maxWidth < 640 ? box.maxWidth : 640,
                  ),
                  child: GoodsCostProductionEvidence(
                    goodsId: widget.detail.id,
                    onOpenCosts: (scope) => setState(() {
                      _actualExecutionScope = scope;
                      _tab = 1;
                    }),
                  ),
                ),
              if (_pendingIssues.isNotEmpty || _stale)
                Text(
                  _stale
                      ? (_calculating || (_debounce?.isActive ?? false)
                            ? _l.costAutoCalculating
                            : _l.costResultNotUpdated)
                      : _l.costNeedsReviewCount(_pendingIssues.length),
                  key: const Key('cost-pending-summary'),
                ),
              if (_pendingIssues.isNotEmpty)
                TextButton(
                  onPressed: _showCalculationIssues,
                  child: Text(_l.costViewEvidence),
                ),
            ],
          ),
        ),
        if (_showSettings) ...[
          if (_settingsLoading) const LinearProgressIndicator(),
          _calculationSettings(),
        ],
      ],
    ),
  );
  Widget _calculationSettings() => UtenCard(
    child: LayoutBuilder(
      builder: (context, box) {
        final width = box.maxWidth < 480 ? box.maxWidth : 245.0;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Wrap(
              spacing: UtenSpacing.s12,
              runSpacing: UtenSpacing.s12,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                SizedBox(
                  width: width,
                  child: _headerText('batchQty', _l.costBatch, numeric: true),
                ),
                SizedBox(width: width, child: _customerField()),
                UtenButton(
                  key: const Key('cost-advanced-settings'),
                  type: UtenButtonType.tonal,
                  icon: _showAdvancedSettings
                      ? Icons.expand_less
                      : Icons.expand_more,
                  onPressed: () => setState(
                    () => _showAdvancedSettings = !_showAdvancedSettings,
                  ),
                  child: Text(_l.costAdvancedOptions),
                ),
              ],
            ),
            if (_showAdvancedSettings) ...[
              const SizedBox(height: UtenSpacing.s12),
              _advancedHeader(),
            ],
          ],
        );
      },
    ),
  );
  Widget _advancedHeader() => LayoutBuilder(
    builder: (context, box) {
      final width = box.maxWidth < 480 ? box.maxWidth : 245.0;
      Widget field(Widget child) => SizedBox(width: width, child: child);
      return Wrap(
        spacing: 12,
        runSpacing: 12,
        children: [
          field(_headerText('name', _l.costName)),
          field(
            UtenDropdownField(
              key: const Key('cost-currency-selector'),
              label: _l.costCurrency,
              value: costText(_input['currencyId']),
              enabled: _editable,
              allowClear: false,
              items: [
                for (final c in _currencies)
                  UtenDropdownItem(value: c.id, label: c.name ?? c.code ?? '—'),
              ],
              onChanged: (value) => _convertCostCurrency(value),
            ),
          ),
          field(
            TextFormField(
              key: const Key('cost-header-exchangeRateToLocal'),
              controller: _controller(
                'header:exchangeRateToLocal',
                costText(_input['exchangeRateToLocal']),
              ),
              readOnly: true,
              onTap: _editable
                  ? () => _convertCostCurrency(
                      costText(_input['currencyId']),
                      editRate: true,
                    )
                  : null,
              errorBuilder: utenTextFieldErrorBuilder,
              decoration: UtenInputDecoration(
                InputDecoration(labelText: _l.costExchangeRate),
                info: _l.costCurrencyConversionHint,
              ),
            ),
          ),
          field(
            UtenDateField(
              label: _l.costEffectiveDate,
              value: DateTime.tryParse(costText(_input['effectiveDate']) ?? ''),
              enabled: _editable,
              onChanged: (d) => _change(
                () => _input['effectiveDate'] = d
                    .toIso8601String()
                    .split('T')
                    .first,
              ),
            ),
          ),
          field(
            UtenDropdownField(
              label: _l.costUsageStrategy,
              value: costText(_input['usageStrategy']),
              enabled: _editable,
              allowClear: false,
              items: [
                UtenDropdownItem(
                  value: 'ACTUAL_FIRST',
                  label: _l.costActualFirst,
                ),
                UtenDropdownItem(value: 'DESIGN', label: _l.costDesignOnly),
              ],
              onChanged: (v) => _change(() => _input['usageStrategy'] = v),
            ),
          ),
          field(
            UtenDropdownField(
              label: _l.costPriceStrategy,
              value: costText(_input['priceStrategy']),
              enabled: _editable,
              allowClear: false,
              items: [
                UtenDropdownItem(value: 'AUTO', label: _l.costAutoPrice),
                UtenDropdownItem(
                  value: 'APPROVED_PURCHASE',
                  label: _l.costApprovedPrice,
                ),
                UtenDropdownItem(value: 'MANUAL', label: _l.costManualPrice),
              ],
              onChanged: (v) => _change(() => _input['priceStrategy'] = v),
            ),
          ),
          field(
            UtenDropdownField(
              label: _l.costTemplate,
              value: costText(_input['templateId']),
              enabled: _editable,
              hintText: _l.costNoTemplate,
              items: [
                for (final t in _templates)
                  UtenDropdownItem(
                    value: costText(t['id']),
                    label: costText(costMap(t['input'])['name']) ?? '—',
                  ),
              ],
              onChanged: (id) => _change(() {
                _input['templateId'] = id;
                // The template owns a frozen currency. Its values must be
                // resolved/converted by the server, never copied verbatim.
              }),
            ),
          ),
          field(_headerText('notes', _l.costNotes)),
          if (_sheet != null)
            field(
              _oneLine(
                '${_sheet!.number} · ${_status(_sheet!.status)} · ${_l.costVersion} ${_sheet!.version}',
              ),
            ),
        ],
      );
    },
  );
  Widget _headerText(String key, String label, {bool numeric = false}) =>
      TextFormField(
        key: ValueKey('cost-header-$key'),
        controller: _controller('header:$key', costText(_input[key])),
        readOnly: !_editable,
        keyboardType: numeric
            ? const TextInputType.numberWithOptions(decimal: true)
            : TextInputType.text,
        errorBuilder: utenTextFieldErrorBuilder,
        decoration: UtenInputDecoration(InputDecoration(labelText: label)),
        onChanged: (value) => _change(() => _input[key] = value),
      );

  Widget _materialTable() {
    final all = _calculation?.lines ?? <Map<String, dynamic>>[];
    final projection = utenTreeProjectionByRow(
      all,
      depthOf: (r) => (r['depth'] as num?)?.toInt() ?? 0,
    );
    // Fullscreen can briefly retain a row widget while a new calculation replaces
    // its Map object. The BOM occurrence path is the identity across snapshots.
    final treeByPath = {for (final row in all) row['path']: projection[row]!};
    final visible = <Map<String, dynamic>>[];
    for (var i = 0; i < all.length; i++) {
      final row = all[i];
      if (!_onlyPending ||
          _pendingIssues.any((issue) => issue['path'] == row['path'])) {
        visible.add(row);
      }
      if (!_onlyPending && _collapsed.contains(row['path'])) {
        i = projection[row]!.subtreeEnd - 1;
      }
    }
    MasterColumnDef<Map<String, dynamic>> number(
      String key,
      String label, {
      bool editable = false,
      bool hidden = false,
      double width = 110,
    }) => MasterColumnDef(
      key: key,
      label: label,
      width: width,
      type: 'number',
      info: switch (key) {
        'unitPrice' => _l.costPriceNormalizedHelp,
        'amount' => _l.costEstimateAmountHelp,
        'unitContribution' => _l.costUnitContributionHelp,
        _ => null,
      },
      defaultVisible: !hidden,
      value: (r) => costText(r[key]),
      exactValueOf: (r) =>
          _stale &&
              {
                'amount',
                'unitContribution',
                'batchQty',
                'unitPrice',
              }.contains(key)
          ? null
          : costText(r[key]),
      exactListenableOf: (_) => _calculationSignal,
      cellBuilder: (_, r) =>
          editable &&
              _editable &&
              (key == 'unitPrice' || _adjustingPaths.contains(r['path'])) &&
              (key != 'unitPrice' ||
                  (r['included'] == true && r['route'] != 'CUSTOMER_SUPPLIED'))
          ? _lineEditor(r, key)
          : Tooltip(
              message:
                  key == 'unitPrice' &&
                      (r['included'] != true ||
                          r['route'] == 'CUSTOMER_SUPPLIED')
                  ? _l.costMaterialPriceNotApplied
                  : '',
              child: _oneLine(
                _stale &&
                        {'amount', 'unitContribution', 'batchQty'}.contains(key)
                    ? '…'
                    : r[key],
                align: TextAlign.right,
              ),
            ),
    );
    final columns = <MasterColumnDef<Map<String, dynamic>>>[
      MasterColumnDef(
        key: 'goodsName',
        label: _l.costGoodsName,
        width: 200,
        value: (r) => costText(r['goodsName']),
        fillsCellHeight: true,
        cellBuilderHandlesSemantics: true,
        cellBuilder: (context, row) {
          final tree = treeByPath[row['path']];
          if (tree == null) return _oneLine(row['goodsName']);
          return UtenTreeTableCell(
            depth: tree.depth,
            sequence: '',
            title: costText(row['goodsName']) ?? '—',
            sequenceInline: true,
            showLeafMarker: false,
            hasChildren: tree.hasChildren,
            expanded: !_collapsed.contains(row['path']),
            childCount: tree.childCount,
            ancestorContinuations: tree.ancestorContinuations,
            isLastChild: tree.isLastChild,
            guideBleed: MasterDataTableView.cellVerticalPadding,
            onToggle: () => setState(() {
              if (!_collapsed.add(row['path'].toString())) {
                _collapsed.remove(row['path']);
              }
            }),
          );
        },
      ),
      _readColumn('goodsCode', _l.costGoodsCode, 120),
      _readColumn('colorName', _l.costColor, 100, defaultVisible: false),
      _readColumn('unitName', _l.costUnit, 70),
      MasterColumnDef(
        key: 'route',
        label: _l.costRoute,
        width: 170,
        defaultVisible: false,
        value: (r) => costText(r['route']),
        cellBuilder: (_, row) => _editable
            ? UtenDropdownField(
                dense: true,
                allowClear: false,
                value: costText(row['route']),
                items: [
                  UtenDropdownItem(value: 'AUTO', label: _l.costRouteAuto),
                  UtenDropdownItem(value: 'MAKE', label: _l.costRouteMake),
                  UtenDropdownItem(value: 'BUY', label: _l.costRouteBuy),
                  UtenDropdownItem(
                    value: 'SUBCONTRACT',
                    label: _l.costRouteSubcontract,
                  ),
                  UtenDropdownItem(
                    value: 'CUSTOMER_SUPPLIED',
                    label: _l.costRouteCustomer,
                  ),
                ],
                onChanged: (value) => _change(
                  () => _input = updateCostOverride(
                    _currentInput(),
                    row['path'].toString(),
                    {'route': value, 'reason': _l.costManual},
                  ),
                ),
              )
            : _oneLine(switch (row['route']) {
                'MAKE' => _l.costRouteMake,
                'BUY' => _l.costRouteBuy,
                'SUBCONTRACT' => _l.costRouteSubcontract,
                'CUSTOMER_SUPPLIED' => _l.costRouteCustomer,
                _ => _l.costRouteAuto,
              }),
      ),
      number('designQty', _l.bomDesignQty, width: 120, hidden: true),
      number('actualQty', _l.bomActualQty, width: 120, hidden: true),
      number('adoptedQty', _l.costAdoptedQty, editable: true),
      MasterColumnDef(
        key: 'usageBasis',
        label: _l.costUsageSource,
        width: 90,
        defaultVisible: false,
        value: (r) => _status(r['usageBasis']),
        cellBuilder: (_, r) => Tooltip(
          message:
              '${r['usageReason'] ?? ''}\n${_l.bomLearningSampleCount}: ${r['sampleCount'] ?? 0}\n${_l.bomLearningExposure}: ${r['actualOutputQty'] ?? '—'}',
          child: _oneLine(_status(r['usageBasis'])),
        ),
      ),
      number('batchQty', _l.costPricingQty, hidden: true),
      number('unitPrice', _l.costPrice, editable: true, width: 160),
      number(
        'unitContribution',
        (costText(_calculation?.json['unitName']) ?? '').isEmpty
            ? _l.costUnitContributionShort
            : _l.costPerUnitLabel(costText(_calculation?.json['unitName'])!),
      ),
      number('amount', _l.costLineAmountShort),
      MasterColumnDef(
        key: 'priceSource',
        label: _l.costPriceSource,
        width: 165,
        defaultVisible: false,
        value: (r) =>
            costText(costMap(r['priceEvidence'])['sourceNumber']) ??
            _status(costMap(r['priceEvidence'])['sourceType']),
        cellBuilder: (_, r) => InkWell(
          onTap: () => _showEvidence(r),
          child: Tooltip(
            message: _l.costExplanation,
            child: _oneLine(
              costMap(r['priceEvidence'])['sourceNumber'] ??
                  _status(costMap(r['priceEvidence'])['sourceType']),
            ),
          ),
        ),
      ),
      for (final column in costMaps(_input['priceColumns'])) ...[
        MasterColumnDef(
          key: 'fee:${column['key']}',
          label: costText(column['name']) ?? '',
          width: 110,
          type: 'money',
          value: (r) => _priceCell(
            r['path'].toString(),
            column['key'].toString(),
          )?['value']?.toString(),
          info: _l.costFeeApplicability,
          cellBuilder: (_, row) => _priceEditor(row, column),
        ),
        MasterColumnDef(
          key: 'feeQty:${column['key']}',
          label: '${column['name']} · ${_l.costFeeQuantity}',
          width: 160,
          type: 'number',
          defaultVisible: column['type'] == 'PER_CYCLE',
          value: (r) => costText(
            _priceCell(
              r['path'].toString(),
              column['key'].toString(),
            )?['quantity'],
          ),
          cellBuilder: (_, r) => _feeQuantityEditor(r, column),
        ),
        MasterColumnDef(
          key: 'feeAmount:${column['key']}',
          label: '${column['name']} · ${_l.costLineAmount}',
          width: 150,
          type: 'money',
          defaultVisible: false,
          value: (r) => costText(costMap(r['extraCosts'])[column['key']]),
          cellBuilder: (_, r) => _oneLine(
            _stale ? '…' : costMap(r['extraCosts'])[column['key']],
            align: TextAlign.right,
          ),
        ),
      ],
      _readColumn(
        'valueState',
        _l.costStatus,
        130,
        defaultVisible: false,
        text: (r) => _status(r['valueState']),
      ),
      MasterColumnDef(
        key: 'adjust',
        label: _l.costAdjustment,
        width: 130,
        value: (_) => _l.costAdjustment,
        cellBuilder: (_, row) => !_editable
            ? const SizedBox.shrink()
            : UtenButton(
                key: ValueKey('cost-adjust-${row['path']}'),
                type: UtenButtonType.tonal,
                onPressed: () => setState(() {
                  final path = row['path'].toString();
                  if (!_adjustingPaths.add(path)) _adjustingPaths.remove(path);
                }),
                child: Flexible(
                  child: Text(
                    _adjustingPaths.contains(row['path'])
                        ? _l.commonConfirm
                        : _l.costAdjustment,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ),
      ),
      MasterColumnDef(
        key: 'details',
        label: _l.costExplanation,
        width: 90,
        value: (_) => _l.costExplanation,
        cellBuilder: (_, r) => UtenButton(
          type: UtenButtonType.tonal,
          onPressed: () => _showEvidence(r),
          child: Text(_l.costOpen, maxLines: 1),
        ),
      ),
    ];
    return MasterDataTableView<Map<String, dynamic>>(
      key: ValueKey('cost-material-${widget.detail.id}'),
      tableKey: _GoodsCostTabState._tableKey,
      primary: true,
      summaryBarInline: true,
      onFullscreenChanged: (value) {
        _materialFullscreen = value;
        if (!value) {
          _fullscreenClosed?.complete();
          _fullscreenClosed = null;
        }
      },
      batchActionsBuilder: _canCostEdit ? (_, _) => _saveActions() : null,
      rowMenuBuilder: (row) => [
        UtenMenuItem(
          label: _l.costViewEvidence,
          onTap: () => _showEvidence(row),
        ),
        if (_editable)
          UtenMenuItem(
            label: _l.costAdjustment,
            onTap: () =>
                setState(() => _adjustingPaths.add(row['path'].toString())),
          ),
      ],
      platformBinding: PlatformTableBinding<Map<String, dynamic>>(
        tableKey: _GoodsCostTabState._tableKey,
        scope: 'view_goods_cost',
        recordIdOf: (_) => null,
        factValuesOf: (row) => {
          for (final key in [
            'designQty',
            'actualQty',
            'adoptedQty',
            'batchQty',
            'perProductQty',
            'unitPrice',
            'amount',
            'materialAmount',
            'feeAmount',
            'unitContribution',
          ])
            key: _stale ? null : costText(row[key]),
        },
        factListenablesOf: (_) => [_calculationSignal],
      ),
      columns: columns,
      items: visible,
      facets: const {},
      nullCounts: const {},
      filters: const {},
      onFilterChanged: (_, _) {},
      rowKeyOf: (r) => r['path'].toString(),
      selectable: true,
      idOf: (r) => r['path'].toString(),
      selectedIds: _selectedPaths,
      onSelectedIdsChanged: (paths) => setState(() {
        _selectedPaths
          ..clear()
          ..addAll(paths);
      }),
      enableTextSelection: !_editable,
      emptyMessage: _l.costEmpty,
      toolbarLeadingActions: _tableActions(),
      summaryBar: _costSummary(),
    );
  }

  Widget _lineEditor(Map<String, dynamic> row, String field) {
    final path = row['path'].toString();
    final override = costMaps(
      _input['lineOverrides'],
    ).where((r) => r['path'] == path).firstOrNull;
    final automaticPrice =
        field == 'unitPrice' &&
        row['unitPrice'] != null &&
        override?['unitPrice'] == null &&
        costMap(row['priceEvidence'])['sourceType'] != 'MANUAL';
    return TextFormField(
      key: ValueKey('cost-$field-$path'),
      textAlign: TextAlign.right,
      controller: _controller(
        '$path:$field',
        field == 'unitPrice'
            ? costUnitPriceEditorText(
                row,
                override,
                costText(_input['exchangeRateToLocal']),
              )
            : costText(override?[field] ?? row[field]),
      ),
      keyboardType: const TextInputType.numberWithOptions(decimal: true),
      errorBuilder: utenTextFieldErrorBuilder,
      decoration: applyAutofillHint(
        UtenInputDecoration(
          InputDecoration(
            isDense: true,
            hintText: field == 'unitPrice' ? _l.costMissingPriceInput : null,
          ),
          info: field != 'unitPrice'
              ? null
              : automaticPrice
              ? _l.costAutomaticPriceHelp(
                  costText(costMap(row['priceEvidence'])['sourceNumber']) ??
                      _status(costMap(row['priceEvidence'])['sourceType']),
                )
              : override?['unitPrice'] != null
              ? _l.costManual
              : null,
        ),
        Theme.of(context),
        autofilled: automaticPrice,
      ),
      onChanged: (text) => _change(
        () => _input = updateCostOverride(_currentInput(), path, {
          field: text,
          'reason': _l.costManual,
          if (field == 'unitPrice') ...{
            'priceSourceType': 'MANUAL',
            'priceUnitRate': '1',
            'priceExchangeRateToLocal': _input['exchangeRateToLocal'],
            'taxMode': 'AS_RECORDED',
          },
        }),
      ),
    );
  }

  Map<String, dynamic>? _priceCell(String path, String key) => costMaps(
    _input['priceCells'],
  ).where((c) => c['path'] == path && c['columnKey'] == key).firstOrNull;
  Widget _priceEditor(Map<String, dynamic> row, Map<String, dynamic> column) {
    final path = row['path'].toString(), key = column['key'].toString();
    final cell = _priceCell(path, key);
    if (!_editable) {
      return _oneLine(
        cell == null ? _l.costNotApplicable : cell['value'],
        align: TextAlign.right,
      );
    }
    return TextFormField(
      key: ValueKey('cost-fee-$key-$path'),
      textAlign: TextAlign.right,
      controller: _controller('fee:$key:$path', costText(cell?['value'])),
      keyboardType: const TextInputType.numberWithOptions(decimal: true),
      errorBuilder: utenTextFieldErrorBuilder,
      decoration: UtenInputDecoration(
        InputDecoration(
          isDense: true,
          hintText: cell == null ? _l.costNotApplicable : _l.costPending,
          suffixIcon: cell == null
              ? null
              : IconButton(
                  tooltip: _l.costNotApplicable,
                  onPressed: () => _change(() {
                    _input = updateCostPriceCell(
                      _currentInput(),
                      path,
                      key,
                      null,
                      applicable: false,
                    );
                    _controllers['fee:$key:$path']?.clear();
                  }),
                  icon: const Icon(Icons.close_rounded),
                ),
        ),
      ),
      onChanged: (text) => _change(
        () => _input = updateCostPriceCell(
          _currentInput(),
          path,
          key,
          text,
          reason: _l.costManual,
        ),
      ),
    );
  }

  Widget _feeQuantityEditor(
    Map<String, dynamic> row,
    Map<String, dynamic> column,
  ) {
    final path = row['path'].toString(), key = column['key'].toString();
    final cell = _priceCell(path, key);
    if (!_editable || !costFeeUsesQuantity(column['type'])) {
      return Tooltip(
        message: costFeeUsesQuantity(column['type'])
            ? _l.costFeeQuantity
            : _l.costNotApplicable,
        child: _oneLine(cell?['quantity'], align: TextAlign.right),
      );
    }
    return TextFormField(
      key: ValueKey('cost-fee-quantity-$key-$path'),
      textAlign: TextAlign.right,
      controller: _controller('feeQty:$key:$path', costText(cell?['quantity'])),
      keyboardType: const TextInputType.numberWithOptions(decimal: true),
      errorBuilder: utenTextFieldErrorBuilder,
      decoration: const UtenInputDecoration(InputDecoration(isDense: true)),
      onChanged: (value) => _change(
        () => _input = updateCostPriceCell(
          _currentInput(),
          path,
          key,
          costText(cell?['value']),
          quantity: value,
          reason: _l.costManual,
        ),
      ),
    );
  }

  String _method(String? type) => switch (type) {
    'PER_UNIT' => _l.costPerUnit,
    'FIXED_BATCH' => _l.costFixedBatch,
    'PERCENT' => _l.costPercent,
    'PER_CYCLE' => _l.costPerCycle,
    _ => _l.costPerQuantity,
  };
  List<UtenDropdownItem> get _methods => [
    for (final key in [
      'PER_QUANTITY',
      'PER_UNIT',
      'FIXED_BATCH',
      'PERCENT',
      'PER_CYCLE',
    ])
      UtenDropdownItem(value: key, label: _method(key)),
  ];
  String _category(String? category) => switch (category) {
    'MATERIAL' => _l.costMaterial,
    'MANAGEMENT' => _l.costManagement,
    'OTHER' => _l.costOther,
    _ => _l.costProcess,
  };
  Map<String, String> get _baseLabels => {
    'MATERIAL': _l.costMaterial,
    'PROCESS': _l.costProcess,
    'DIRECT_COST': _l.costDirectCost,
    for (final row in _feeGrid.rows)
      row.json['key'].toString(): row.controller('name').text,
  };
  String _baseText(String text) => text
      .split(',')
      .where((k) => k.isNotEmpty)
      .map((k) => _baseLabels[k] ?? _l.costPending)
      .join(' + ');
  Future<List<String>?> _pickBases(
    String current, {
    String? excludedKey,
  }) async {
    final selected = current.split(',').where((k) => k.isNotEmpty).toSet();
    return _dialogWhenRemoved<List<String>>(
      context: context,
      builder: (dialog) => StatefulBuilder(
        builder: (context, update) => AlertDialog(
          title: Text(_l.costFeeBase),
          content: SizedBox(
            width: 480,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  for (final entry in _baseLabels.entries)
                    if (entry.key != excludedKey)
                      CheckboxListTile(
                        title: Text(entry.value),
                        value: selected.contains(entry.key),
                        onChanged: (value) => update(() {
                          if (value == true) {
                            selected.add(entry.key);
                          } else {
                            selected.remove(entry.key);
                          }
                        }),
                      ),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialog),
              child: Text(_l.commonCancel),
            ),
            TextButton(
              onPressed: () => Navigator.pop(dialog, selected.toList()),
              child: Text(_l.commonConfirm),
            ),
          ],
        ),
      ),
    );
  }

  List<UtenDropdownItem> get _categories => [
    for (final key in ['MATERIAL', 'PROCESS', 'MANAGEMENT', 'OTHER'])
      UtenDropdownItem(value: key, label: _category(key)),
  ];
  Future<void> _addPriceColumn() async {
    final name = TextEditingController();
    var type = 'PER_UNIT', category = 'PROCESS';
    var advanced = false;
    final base = TextEditingController(text: 'MATERIAL');
    Map<String, dynamic>? reuse;
    final known = <String, Map<String, dynamic>>{
      for (final template in _templates)
        for (final column in costMaps(
          costMap(template['input'])['priceColumns'],
        ))
          column['key'].toString(): column,
      for (final column in costMaps(_input['priceColumns']))
        column['key'].toString(): column,
    };
    final saved = await _dialogWhenRemoved<Map<String, dynamic>>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, update) => AlertDialog(
          title: Text(_l.costAddPriceColumn),
          content: SizedBox(
            width: 480,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (known.isNotEmpty) ...[
                    UtenDropdownField(
                      label: _l.costFeeReuse,
                      value: costText(reuse?['key']),
                      searchable: true,
                      items: [
                        for (final column in known.values)
                          UtenDropdownItem(
                            value: costText(column['key']),
                            label: costText(column['name']) ?? '—',
                          ),
                      ],
                      onChanged: (key) => update(() {
                        reuse = known[key];
                        if (reuse != null) {
                          name.text = costText(reuse!['name']) ?? '';
                          type = costText(reuse!['type']) ?? 'PER_QUANTITY';
                          category = costText(reuse!['category']) ?? 'PROCESS';
                          base.text = (reuse!['baseKeys'] as List? ?? []).join(
                            ',',
                          );
                        }
                      }),
                    ),
                    const SizedBox(height: 12),
                  ],
                  TextFormField(
                    key: const Key('cost-column-name'),
                    controller: name,
                    errorBuilder: utenTextFieldErrorBuilder,
                    decoration: UtenInputDecoration(
                      InputDecoration(labelText: _l.costFeeName),
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(_l.costDefaultFeeHelp),
                  TextButton(
                    key: const Key('cost-column-advanced'),
                    onPressed: () => update(() => advanced = !advanced),
                    child: Text(_l.costAdvancedOptions),
                  ),
                  if (advanced) ...[
                    const SizedBox(height: 12),
                    UtenDropdownField(
                      label: _l.costFeeMethod,
                      value: type,
                      allowClear: false,
                      items: _methods,
                      onChanged: (v) => update(() => type = v!),
                    ),
                    const SizedBox(height: 12),
                    UtenDropdownField(
                      label: _l.costFeeCategory,
                      value: category,
                      allowClear: false,
                      items: _categories,
                      onChanged: (v) => update(() => category = v!),
                    ),
                    if (type == 'PERCENT') ...[
                      const SizedBox(height: 12),
                      UtenButton(
                        type: UtenButtonType.tonal,
                        onPressed: () async {
                          final selected = await _pickBases(base.text);
                          if (selected != null && context.mounted) {
                            update(() => base.text = selected.join(','));
                          }
                        },
                        child: Text(
                          '${_l.costFeeBase}: ${_baseText(base.text)}',
                        ),
                      ),
                    ],
                  ],
                ],
              ),
            ),
          ),
          actions: [
            if (reuse != null &&
                costMaps(
                  _input['priceColumns'],
                ).any((c) => c['key'] == reuse!['key']))
              TextButton(
                onPressed: () async {
                  final confirmed = await UtenDialog.show(
                    context,
                    title: _l.costDeleteColumn,
                    content: Text(_l.costDeleteFeePrompt),
                    confirmLabel: _l.costDelete,
                    cancelLabel: _l.commonCancel,
                  );
                  if (confirmed == true && dialogContext.mounted) {
                    Navigator.pop(dialogContext, <String, dynamic>{
                      '_deleteKey': reuse!['key'],
                    });
                  }
                },
                child: Text(_l.costDeleteColumn),
              ),
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: Text(_l.commonCancel),
            ),
            TextButton(
              key: const Key('cost-column-create'),
              onPressed: () {
                if (name.text.trim().isEmpty) return;
                final existing = costMaps(_input['priceColumns'])
                    .where(
                      (c) =>
                          costText(c['name'])?.toLowerCase() ==
                          name.text.trim().toLowerCase(),
                    )
                    .firstOrNull;
                if (existing != null && existing['key'] != reuse?['key']) {
                  Navigator.pop(dialogContext);
                  return;
                }
                Navigator.pop(dialogContext, <String, dynamic>{
                  'key': reuse?['key'] ?? const Uuid().v4(),
                  'name': name.text.trim(),
                  'type': type,
                  'category': category,
                  'baseKeys': base.text
                      .split(',')
                      .map((v) => v.trim())
                      .where((v) => v.isNotEmpty)
                      .toList(),
                });
              },
              child: Text(_l.commonConfirm),
            ),
          ],
        ),
      ),
    );
    name.dispose();
    base.dispose();
    if (saved != null && mounted) {
      _change(() {
        final deleted = costText(saved['_deleteKey']);
        final key = deleted ?? saved['key'];
        final columns = costMaps(
          _input['priceColumns'],
        ).where((c) => c['key'] != key).toList();
        if (deleted != null) {
          _input['priceCells'] = costMaps(
            _input['priceCells'],
          ).where((c) => c['columnKey'] != deleted).toList();
          final extra = costMap(_input['extraFields']);
          List<dynamic> excluded;
          try {
            excluded =
                jsonDecode(
                      costText(extra['costExcludedPriceColumnKeys']) ?? '[]',
                    )
                    as List<dynamic>;
          } catch (_) {
            excluded = [];
          }
          extra['costExcludedPriceColumnKeys'] = jsonEncode(
            {...excluded, deleted}.toList(),
          );
          _input['extraFields'] = extra;
        } else {
          columns.add(saved);
        }
        _input['priceColumns'] = columns;
        _input = markCostPriceColumnManual(_input, key.toString());
      });
    }
  }

  Widget _feeTable() {
    Widget field(GoodsCostFeeRow row, String key) => TextFormField(
      key: ValueKey('cost-fee-row-${row.json['key']}-$key'),
      controller: row.controller(key),
      readOnly:
          !_editable ||
          (key == 'quantity' && !costFeeUsesQuantity(row.json['type'])) ||
          (row.generated && !{'value', 'quantity', 'reason'}.contains(key)),
      textAlign: {'value', 'quantity'}.contains(key)
          ? TextAlign.right
          : TextAlign.left,
      keyboardType: {'value', 'quantity'}.contains(key)
          ? const TextInputType.numberWithOptions(decimal: true)
          : TextInputType.text,
      errorBuilder: utenTextFieldErrorBuilder,
      decoration: const UtenInputDecoration(InputDecoration(isDense: true)),
      onChanged: (_) => _change(() {
        if (row.generated) {
          final path = row.json['targetPath'].toString(),
              column = row.columnKey;
          _input = updateCostPriceCell(
            _currentInput(),
            path,
            column,
            row.controller('value').text,
            quantity: row.controller('quantity').text,
            reason: row.controller('reason').text,
          );
          _controllers['fee:$column:$path']?.text = row
              .controller('value')
              .text;
          _controllers['feeQty:$column:$path']?.text = row
              .controller('quantity')
              .text;
        } else {
          row.json['source'] = 'MANUAL';
        }
      }),
    );
    String? amount(GoodsCostFeeRow r) =>
        _stale ? null : costText(_feeResultsByKey[r.json['key']]?['amount']);
    return UtenEditableGrid<GoodsCostFeeRow>(
      tableKey: 'master.goods.cost.fees',
      stickyHeaderPinned: _feePinned,
      toolbarActions: _tableActions(),
      platformBinding: PlatformTableBinding<GoodsCostFeeRow>(
        tableKey: 'master.goods.cost.fees',
        scope: 'view_goods_cost',
        recordIdOf: (_) => null,
        factValuesOf: (row) {
          final result = _feeResultsByKey[row.json['key']];
          return {
            'value': row.controller('value').text,
            'quantity': row.controller('quantity').text,
            for (final key in ['baseAmount', 'amount', 'unitAmount'])
              key: _stale ? null : costText(result?[key]),
          };
        },
        factListenablesOf: (row) => [
          row.controller('value'),
          row.controller('quantity'),
          _calculationSignal,
        ],
      ),
      controller: _feeGrid,
      showAddRow: _editable,
      showRowDelete: _editable,
      showRemoveRowsAction: _editable,
      addRowLabel: _l.costFees,
      addRowsLabel: _l.costFees,
      emptyMessage: _l.commonNoData,
      deleteConfirmLabel: _l.costDeleteFeePrompt,
      createBlankRow: () => GoodsCostFeeRow({
        'key': const Uuid().v4(),
        'name': '',
        'type': 'FIXED_BATCH',
        'category': 'PROCESS',
        'baseKeys': ['MATERIAL'],
        'source': 'MANUAL',
      }),
      onDeleteRow: (row, index) => _change(() => _removeFee(row, index)),
      onRemoveRows: (rows) => _change(() {
        for (final row in rows) {
          final index = _feeGrid.rows.indexOf(row);
          if (index >= 0) _removeFee(row, index);
        }
      }),
      columns: [
        EditableGridColumn(
          key: 'goodsName',
          label: _l.costGoodsName,
          width: 200,
          cellBuilder: (_, r) => _oneLine(
            _costLinesByPath[r.json['targetPath']]?['goodsName'] ??
                _l.costTotalLabel,
          ),
        ),
        for (final (key, label, width) in [
          ('name', _l.costFeeName, 200.0),
          ('value', _l.costValue, 150.0),
          ('quantity', _l.costFeeQuantity, 150.0),
        ])
          EditableGridColumn(
            key: key,
            label: label,
            width: width,
            numeric: key != 'name',
            exactValueOf: key == 'name' ? null : (r) => r.controller(key).text,
            exactListenableOf: key == 'name' ? null : (r) => r.controller(key),
            cellBuilder: (_, r) => field(r, key),
            frozenTextOf: (r) => r.controller(key).text,
          ),
        EditableGridColumn(
          key: 'type',
          label: _l.costFeeMethod,
          width: 230,
          cellBuilder: (_, r) => r.generated
              ? _oneLine(_method(costText(r.json['type'])))
              : UtenDropdownField(
                  value: costText(r.json['type']),
                  items: _methods,
                  enabled: _editable,
                  dense: true,
                  allowClear: false,
                  onChanged: (v) => _change(() {
                    r.json['type'] = v;
                    r.json['source'] = 'MANUAL';
                  }),
                ),
        ),
        EditableGridColumn(
          key: 'category',
          label: _l.costFeeCategory,
          width: 170,
          cellBuilder: (_, r) => r.generated
              ? _oneLine(_category(costText(r.json['category'])))
              : UtenDropdownField(
                  value: costText(r.json['category']),
                  items: _categories,
                  enabled: _editable,
                  dense: true,
                  allowClear: false,
                  onChanged: (v) => _change(() {
                    r.json['category'] = v;
                    r.json['source'] = 'MANUAL';
                  }),
                ),
        ),
        EditableGridColumn(
          key: 'baseKeys',
          label: _l.costFeeBase,
          width: 180,
          cellBuilder: (_, r) => InkWell(
            onTap: !_editable || r.generated
                ? null
                : () async {
                    final bases = await _pickBases(
                      r.controller('baseKeys').text,
                      excludedKey: costText(r.json['key']),
                    );
                    if (bases != null && mounted) {
                      _change(() {
                        r.controller('baseKeys').text = bases.join(',');
                        r.json['source'] = 'MANUAL';
                      });
                    }
                  },
            child: _oneLine(_baseText(r.controller('baseKeys').text)),
          ),
        ),
        EditableGridColumn(
          key: 'amount',
          label: _l.costLineAmount,
          width: 160,
          numeric: true,
          exactValueOf: amount,
          cellBuilder: (_, r) =>
              _oneLine(_stale ? '…' : amount(r), align: TextAlign.right),
        ),
        EditableGridColumn(
          key: 'reason',
          label: _l.costNotes,
          width: 220,
          cellBuilder: (_, r) => field(r, 'reason'),
        ),
      ],
      footer: _costSummary(),
    );
  }

  Future<void> _showEvidence(Map<String, dynamic> row) async {
    final evidence = costMap(row['priceEvidence']);
    final items = <Map<String, dynamic>>[
      {'name': _l.costGoodsName, 'value': row['goodsName']},
      {'name': _l.costGoodsCode, 'value': row['goodsCode']},
      {'name': _l.costUsageSource, 'value': _status(row['usageBasis'])},
      {'name': _l.costExplanation, 'value': row['usageReason']},
      {'name': _l.bomLearningSampleCount, 'value': row['sampleCount']},
      {'name': _l.bomLearningExposure, 'value': row['actualOutputQty']},
      {'name': _l.costSourceDocument, 'value': evidence['sourceNumber']},
      {'name': _l.costPrice, 'value': evidence['originalUnitPrice']},
      {'name': _l.costUnit, 'value': evidence['unitName']},
      {'name': _l.costPriceUnitRate, 'value': evidence['unitRate']},
      {'name': _l.costCurrency, 'value': evidence['currencyName']},
      {'name': _l.costExchangeRate, 'value': evidence['exchangeRateToLocal']},
      {'name': _l.costEffectiveDate, 'value': evidence['sourceDate']},
      {'name': _l.costLineAmount, 'value': row['amount']},
    ];
    await showDialog<void>(
      context: context,
      builder: (dialog) => AlertDialog(
        title: Text(_l.costExplanation),
        content: SizedBox(
          width: 760,
          height: 480,
          child: MasterDataTableView<Map<String, dynamic>>(
            tableKey: 'master.goods.cost.evidence',
            columns: [
              _readColumn('name', _l.costSource, 220),
              _readColumn('value', _l.costValue, 460),
            ],
            items: items,
            facets: const {},
            nullCounts: const {},
            filters: const {},
            onFilterChanged: (_, _) {},
          ),
        ),
        actions: [
          if (_editable && evidence.isNotEmpty)
            TextButton(
              onPressed: () {
                Navigator.pop(dialog);
                _confirmTax(row);
              },
              child: Text(_l.costTaxMode),
            ),
          if (_editable)
            TextButton(
              onPressed: () {
                _change(() {
                  _input = _currentInput();
                  _input['lineOverrides'] = costMaps(
                    _input['lineOverrides'],
                  ).where((r) => r['path'] != row['path']).toList();
                  _resetEditors();
                });
                Navigator.pop(dialog);
              },
              child: Text(_l.costRestoreRecommended),
            ),
          TextButton(
            onPressed: () => Navigator.pop(dialog),
            child: Text(_l.commonBack),
          ),
        ],
      ),
    );
  }

  Future<void> _confirmTax(Map<String, dynamic> row) async {
    final reason = TextEditingController(text: _l.costTaxConfirmedReason);
    String? mode;
    final accepted = await _dialogWhenRemoved<bool>(
      context: context,
      builder: (dialog) => StatefulBuilder(
        builder: (context, update) => AlertDialog(
          title: Text(_l.costTaxMode),
          content: SizedBox(
            width: 500,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                UtenDropdownField(
                  value: mode,
                  allowClear: false,
                  label: _l.costTaxMode,
                  hintText: _l.costTaxUnconfirmed,
                  items: [
                    UtenDropdownItem(
                      value: 'AS_RECORDED',
                      label: _l.costTaxRecorded,
                    ),
                    UtenDropdownItem(
                      value: 'EXCLUDE_TAX',
                      label: _l.costTaxExclude,
                    ),
                  ],
                  onChanged: (v) => update(() => mode = v),
                ),
                const SizedBox(height: 12),
                TextFormField(
                  controller: reason,
                  errorBuilder: utenTextFieldErrorBuilder,
                  decoration: UtenInputDecoration(
                    InputDecoration(labelText: _l.costOverrideReason),
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialog, false),
              child: Text(_l.commonCancel),
            ),
            TextButton(
              onPressed: mode == null
                  ? null
                  : () => Navigator.pop(dialog, reason.text.trim().isNotEmpty),
              child: Text(_l.commonConfirm),
            ),
          ],
        ),
      ),
    );
    final explanation = reason.text.trim();
    reason.dispose();
    if (accepted == true && mounted) {
      _change(
        () => _input = updateCostOverride(
          _currentInput(),
          row['path'].toString(),
          {
            'taxMode': mode,
            'reason': explanation,
            'priceSourceItemId': costMap(row['priceEvidence'])['sourceItemId'],
            'priceSourceType': costMap(row['priceEvidence'])['sourceType'],
            'priceSourceVersion': costMap(
              row['priceEvidence'],
            )['sourceVersion'],
            if (costMap(row['priceEvidence'])['sourceType'] != 'MANUAL')
              'unitPrice': null,
          },
        ),
      );
    }
  }

  Future<void> _saveTemplate() async {
    if (!_capability.canManageTemplates || !_editable) return;
    final result = await _action(
      () => _repository.saveTemplate({
        'name': _input['name'],
        'goodsId': widget.detail.id,
        'clientId': _input['clientId'],
        'fees': _currentInput()['fees'],
        'priceColumns': _input['priceColumns'],
        'notes': _input['notes'],
        'validFrom': _input['effectiveDate'],
        'currencyId': _input['currencyId'],
        'exchangeRateToLocal': _input['exchangeRateToLocal'],
      }, const Uuid().v4()),
    );
    if (result != null && mounted) {
      _templates = await _repository.templates(
        widget.detail.id,
        costText(_input['clientId']),
      );
      if (mounted) {
        setState(() {});
        context.appSuccess(_l.costTemplateSaved);
      }
    }
  }

  Future<void> _showSnapshots() async {
    await _leaveMaterialFullscreen();
    if (!mounted) return;
    if (_dirty) {
      context.appError(_l.costLeavePrompt);
      return;
    }
    final id = _sheet?.id;
    if (id == null) return;
    await _action(() async {
      _snapshots = await _repository.snapshots(id);
    });
    if (!mounted) return;
    final selected = await showDialog<String>(
      context: context,
      builder: (dialog) => AlertDialog(
        title: Text(_l.costHistory),
        content: SizedBox(
          width: 800,
          height: 420,
          child: MasterDataTableView<Map<String, dynamic>>(
            tableKey: 'master.goods.cost.snapshots',
            columns: [
              _readColumn('sheetVersion', _l.costVersion, 100),
              _readColumn('kind', _l.costStatus, 150),
              _readColumn('createdAt', _l.costUpdated, 200),
              MasterColumnDef(
                key: 'open',
                label: _l.costOpen,
                width: 120,
                value: (_) => _l.costOpen,
                cellBuilder: (_, row) => UtenButton(
                  onPressed: () => Navigator.pop(dialog, row['id'].toString()),
                  child: Text(_l.costOpen),
                ),
              ),
            ],
            items: _snapshots,
            facets: const {},
            nullCounts: const {},
            filters: const {},
            onFilterChanged: (_, _) {},
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialog),
            child: Text(_l.commonCancel),
          ),
        ],
      ),
    );
    if (selected == null || !mounted) return;
    await _action(() async {
      final snapshot = await _repository.snapshotDetail(selected);
      if (!mounted) return;
      setState(() {
        _historical = snapshot;
        _input = costMap(snapshot.json['input']);
        _clientName = costText(
          costMap(_input['extraFields'])['serverClientName'],
        );
        _calculation = snapshot.calculation;
        _inputRevision++;
        _calculatedRevision = _inputRevision;
        _dirty = false;
        _resetEditors();
        _tab = 0;
      });
    });
  }

  Future<void> _lossPolicy() async {
    final form = GlobalKey<FormState>();
    final controller = TextEditingController(
      text: widget.detail.subcontractAllowedLossPct?.toString() ?? '',
    );
    final result = await _dialogWhenRemoved<String>(
      context: context,
      builder: (dialog) => AlertDialog(
        title: Text(_l.costLossPolicy),
        content: Form(
          key: form,
          child: TextFormField(
            controller: controller,
            validator: (value) {
              final text = value?.trim() ?? '';
              if (text.isEmpty) return null;
              if (!RegExp(r'^\d{1,3}(?:\.\d{1,2})?$').hasMatch(text)) {
                return _l.costLossRange;
              }
              final amount = double.tryParse(text);
              return amount == null || amount < 0 || amount > 100
                  ? _l.costLossRange
                  : null;
            },
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            errorBuilder: utenTextFieldErrorBuilder,
            decoration: UtenInputDecoration(
              InputDecoration(labelText: _l.costLossPolicy),
              info: _l.costLossPolicyHint,
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialog),
            child: Text(_l.commonCancel),
          ),
          TextButton(
            onPressed: () {
              if (form.currentState?.validate() == true) {
                Navigator.pop(dialog, controller.text.trim());
              }
            },
            child: Text(_l.commonSave),
          ),
        ],
      ),
    );
    controller.dispose();
    if (result == null || !mounted) return;
    await _action(() async {
      await ref
          .read(apiClientProvider)
          .put(
            '/master/goods/${widget.detail.id}/subcontract-loss-policy',
            body: {
              'expectedVersion': widget.detail.version,
              'percent': result.isEmpty ? null : result,
            },
          );
      widget.onSaved?.call();
    });
  }
}

class GoodsCostFeeRow extends EditableGridRow {
  GoodsCostFeeRow(Map<String, dynamic> value) : json = copyCostJson(value);
  final Map<String, dynamic> json;
  bool get generated => json['source'] == 'PRICE_COLUMN';
  String get columnKey {
    final key = json['key'].toString(), path = json['targetPath'].toString();
    return key.substring(7, key.length - path.length - 1);
  }

  final _controllers = <String, TextEditingController>{};
  void adoptConverted(Map<String, dynamic> value) {
    json
      ..clear()
      ..addAll(value);
    final controller = _controllers['value'];
    final next = costText(value['value']) ?? '';
    if (controller != null && controller.text != next) controller.text = next;
  }

  void adoptSuggestion(Map<String, dynamic> value) {
    json
      ..clear()
      ..addAll(value);
    for (final entry in _controllers.entries) {
      final next = entry.key == 'baseKeys'
          ? (json[entry.key] as List? ?? []).join(',')
          : costText(json[entry.key]) ?? '';
      if (entry.value.text != next) entry.value.text = next;
    }
  }

  TextEditingController controller(String key) => _controllers.putIfAbsent(
    key,
    () => TextEditingController(
      text: key == 'baseKeys'
          ? (json[key] as List? ?? []).join(',')
          : costText(json[key]) ?? '',
    ),
  );
  Map<String, dynamic> encode() => {
    ...json,
    for (final entry in _controllers.entries)
      entry.key: entry.key == 'baseKeys'
          ? entry.value.text
                .split(',')
                .map((v) => v.trim())
                .where((v) => v.isNotEmpty)
                .toList()
          : entry.value.text,
  };
  @override
  void dispose() {
    for (final c in _controllers.values) {
      c.dispose();
    }
    super.dispose();
  }
}
