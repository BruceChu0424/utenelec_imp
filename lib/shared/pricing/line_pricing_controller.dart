import 'package:flutter/widgets.dart';

import '../business_columns/business_column.dart';
import '../formatters/exact_decimal.dart';

/// The selected value is derived; the other two values remain user inputs.
enum LinePricingMode { calculateAmount, calculatePrice, calculateQuantity }

/// Exact decimal arithmetic for quantity, unit price and the final line amount.
///
/// Controllers supplied by the row remain owned by that row. This controller
/// owns only [totalAmount] and [error]. An explicitly entered amount may be
/// authoritative only when the document API supports [totalAmountInput].
class LinePricingController extends ChangeNotifier {
  LinePricingController({
    required this.qty,
    required this.price,
    this.discount,
    this.extraColumns,
    Listenable? extraColumnsChanged,
    this.supportsTotalInput = false,
    bool Function()? canCalculateQuantity,
    bool Function()? canCalculatePrice,
    this.priceScale = 10,
  }) : _extraColumnsChanged = extraColumnsChanged,
       _quantityAllowed = canCalculateQuantity,
       _priceAllowed = canCalculatePrice {
    _qtyText = qty.text;
    _priceText = price.text;
    _discountText = discount?.text;
    qty.addListener(_onQty);
    price.addListener(_onPrice);
    discount?.addListener(_onDiscount);
    totalAmount.addListener(_onTotal);
    extraColumnsChanged?.addListener(_onExtraColumns);
    refresh();
  }

  final TextEditingController qty;
  final TextEditingController price;
  final TextEditingController? discount;
  final bool supportsTotalInput;
  final int priceScale;
  final Iterable<BusinessColumn> Function()? extraColumns;
  final Listenable? _extraColumnsChanged;
  final bool Function()? _quantityAllowed;
  final bool Function()? _priceAllowed;
  final totalAmount = TextEditingController();
  final error = ValueNotifier<String?>(null);

  LinePricingMode _mode = LinePricingMode.calculateAmount;
  LinePricingMode get mode => _mode;
  bool get canCalculateQuantity => _quantityAllowed?.call() ?? true;
  bool get canCalculatePrice => _priceAllowed?.call() ?? true;
  String? get amountExact => _amountExact;
  bool get isApproximate => _approximate;

  /// The recorded amount before ordered business columns are applied.
  /// Never submit this field to an API that derives amounts from unit price.
  String? get totalAmountInput =>
      supportsTotalInput && _mode != LinePricingMode.calculateAmount
      ? _baseAmount
      : null;

  String? _amountExact;
  String? _baseAmount;
  // Editing an adjustment changes consideration, not the entered base. Keep
  // this checkpoint through invalid operands so correcting them can recover.
  String? _columnBaseAmount;
  bool _approximate = false;
  bool _busy = false;
  late String _qtyText;
  late String _priceText;
  String? _discountText;
  String _totalText = '';

  void _onQty() {
    if (_busy || qty.text == _qtyText) return;
    if (_mode == LinePricingMode.calculateQuantity) {
      _mode = price.text.trim().isEmpty && totalAmount.text.trim().isNotEmpty
          ? LinePricingMode.calculatePrice
          : LinePricingMode.calculateAmount;
    }
    refresh();
  }

  void _onPrice() {
    if (_busy || price.text == _priceText) return;
    if (_mode == LinePricingMode.calculatePrice) {
      _mode = qty.text.trim().isEmpty && totalAmount.text.trim().isNotEmpty
          ? LinePricingMode.calculateQuantity
          : LinePricingMode.calculateAmount;
    }
    refresh();
  }

  void _onDiscount() {
    if (_busy || discount?.text == _discountText) return;
    refresh();
  }

  void _onTotal() {
    if (_busy || totalAmount.text == _totalText) return;
    _columnBaseAmount = null;
    if (_mode == LinePricingMode.calculateAmount) {
      _mode =
          canCalculateQuantity &&
              (qty.text.trim().isEmpty || !canCalculatePrice) &&
              price.text.trim().isNotEmpty
          ? LinePricingMode.calculateQuantity
          : LinePricingMode.calculatePrice;
    }
    refresh();
  }

  void _onExtraColumns() {
    if (_busy) return;
    if (_mode != LinePricingMode.calculateAmount) {
      _columnBaseAmount ??= _baseAmount;
    }
    refresh();
  }

  void setMode(LinePricingMode value) {
    _mode = value;
    refresh();
  }

  /// Re-evaluate after a source lock or business-column operand changes.
  void refresh() {
    if (_busy) return;
    if (_mode == LinePricingMode.calculateAmount) _columnBaseAmount = null;
    _busy = true;
    try {
      _amountExact = null;
      _baseAmount = null;
      _approximate = false;
      error.value = null;
      _calculate();
    } on _PricingFailure catch (failure) {
      _approximate = false;
      error.value = failure.message;
      _clearDerivedValue();
    } finally {
      _qtyText = qty.text;
      _priceText = price.text;
      _discountText = discount?.text;
      _totalText = totalAmount.text;
      _busy = false;
    }
    notifyListeners();
  }

  void _calculate() {
    final columns = extraColumns?.call().toList() ?? const <BusinessColumn>[];
    final factor = _discountFactor();
    if (_mode == LinePricingMode.calculateAmount) {
      final quantity = _read(qty.text, '数量', scale: 4, positive: true);
      final unitPrice = _read(price.text, '单价', scale: priceScale);
      if (quantity == null || unitPrice == null) {
        _write(totalAmount, '');
        return;
      }
      final base = financeExactMultiplyTexts([quantity, unitPrice, factor])!;
      final amount = businessColumnAmount(base, columns);
      if (amount == null) {
        throw const _PricingFailure('附加列计算无效，请检查数值、除数和总金额');
      }
      _amountExact = businessExactDecimal(amount);
      _write(totalAmount, _amountExact ?? '');
      return;
    }

    if (_mode == LinePricingMode.calculatePrice && !canCalculatePrice) {
      throw const _PricingFailure('本行单价由来源单据或财务确定，不能反算单价');
    }
    if (_mode == LinePricingMode.calculateQuantity && !canCalculateQuantity) {
      throw const _PricingFailure('本行数量由来源单据确定，不能反算数量');
    }
    String? amount;
    final String base;
    if (_columnBaseAmount case final preservedBase?) {
      base = preservedBase;
      amount = businessExactDecimal(businessColumnAmount(base, columns));
      if (amount == null) {
        throw const _PricingFailure('附加列计算无效，请检查数值、除数和总金额');
      }
      // An adjustment may produce a 30-place book value even though an
      // explicitly entered base total is bounded to 24 fractional places.
      _write(totalAmount, amount);
    } else {
      amount = _read(totalAmount.text, '总金额', scale: financeAmountScale);
      if (amount == null) {
        _clearDerivedValue();
        return;
      }
      base = _reverseColumns(amount, columns);
    }
    if (base.startsWith('-')) {
      throw const _PricingFailure('扣除附加列后基础总金额不能小于 0');
    }
    if (supportsTotalInput && financeAmountUnits(base) == null) {
      throw const _PricingFailure('基础总金额超过 24 位小数，无法精确保存');
    }

    if (_mode == LinePricingMode.calculatePrice) {
      final quantity = _read(qty.text, '数量', scale: 4, positive: true);
      if (quantity == null) {
        _clearDerivedValue();
        return;
      }
      final denominator = financeExactMultiplyTexts([quantity, factor])!;
      final division = _divide(base, denominator, priceScale);
      if (!division.exact && !supportsTotalInput) {
        throw _PricingFailure('总金额无法换算为 $priceScale 位内的精确单价，请调整数量或总金额');
      }
      _approximate = !division.exact;
      _write(price, division.text);
    } else {
      final unitPrice = _read(
        price.text,
        '单价',
        scale: priceScale,
        positive: true,
      );
      if (unitPrice == null) {
        _clearDerivedValue();
        return;
      }
      final denominator = financeExactMultiplyTexts([unitPrice, factor])!;
      final division = _divide(base, denominator, 4);
      if (!division.exact) {
        throw const _PricingFailure('总金额无法换算为 4 位内的精确数量，请调整单价或总金额');
      }
      if (division.text == '0') {
        throw const _PricingFailure('反算数量必须大于 0');
      }
      _write(qty, division.text);
    }

    // Verify the same sequential business-column contract used by the server.
    final checkedAmount = businessColumnAmount(base, columns);
    if (checkedAmount == null || !_equal(checkedAmount, amount)) {
      throw const _PricingFailure('附加列无法精确还原总金额，请检查运算顺序和数值');
    }
    _baseAmount = base;
    _amountExact = amount;
  }

  String _discountFactor() {
    final raw = discount?.text.trim() ?? '';
    if (raw.isEmpty) return '1';
    final value = _read(raw, '折扣', scale: 4)!;
    // Existing line-amount semantics treat an empty or zero discount as 1.
    return _equal(value, '0') ? '1' : value;
  }

  String? _read(
    String raw,
    String label, {
    required int scale,
    bool positive = false,
  }) {
    if (raw.trim().isEmpty) return null;
    final canonical = businessExactDecimal(raw);
    if (canonical == null) throw _PricingFailure('$label请输入有效数字');
    final units = financeExactDecimalUnits(canonical, scale: scale);
    if (units == null) throw _PricingFailure('$label最多支持 $scale 位小数');
    if (units.isNegative || (positive && units == BigInt.zero)) {
      throw _PricingFailure('$label${positive ? '必须大于 0' : '不能小于 0'}');
    }
    return canonical;
  }

  String _reverseColumns(String finalAmount, List<BusinessColumn> columns) {
    var value = finalAmount;
    for (final column in columns.reversed) {
      final raw = column.value?.trim() ?? '';
      if (!column.affectsAmount || raw.isEmpty) continue;
      final operand = businessExactDecimal(raw);
      if (operand == null || !column.numeric) {
        throw _PricingFailure('附加列“${column.name}”请输入有效数字');
      }
      switch (column.operation) {
        case 'ADD':
          value = financeExactSumTexts([value, _negate(operand)])!;
        case 'SUBTRACT':
          value = financeExactSumTexts([value, operand])!;
        case 'MULTIPLY':
          if (_equal(operand, '0')) {
            throw _PricingFailure('附加列“${column.name}”乘数为 0，无法反算');
          }
          final division = _divide(value, operand, 30);
          if (!division.exact) {
            throw _PricingFailure('附加列“${column.name}”无法反算出有限小数，请调整数值');
          }
          value = division.text;
        case 'DIVIDE':
          if (_equal(operand, '0')) {
            throw _PricingFailure('附加列“${column.name}”除数不能为 0');
          }
          value = financeExactMultiplyTexts([value, operand])!;
        default:
          throw _PricingFailure('附加列“${column.name}”运算不受支持');
      }
      final normalized = businessExactDecimal(value);
      if (normalized == null) {
        throw _PricingFailure('附加列“${column.name}”反算结果超出精确范围');
      }
      value = normalized;
    }
    return value;
  }

  void _clearDerivedValue() {
    if (_mode == LinePricingMode.calculateAmount) {
      _write(totalAmount, '');
    } else if (_mode == LinePricingMode.calculatePrice && canCalculatePrice) {
      _write(price, '');
    } else if (_mode == LinePricingMode.calculateQuantity &&
        canCalculateQuantity) {
      _write(qty, '');
    }
  }

  /// Returns a user-facing validation error, or null when values are coherent.
  String? validate() {
    refresh();
    if (error.value != null) return error.value;
    if (_amountExact != null) return null;
    final message = switch (_mode) {
      LinePricingMode.calculateAmount => '请输入数量和单价',
      LinePricingMode.calculatePrice => '请输入数量和总金额',
      LinePricingMode.calculateQuantity => '请输入单价和总金额',
    };
    error.value = message;
    return message;
  }

  Map<String, dynamic> exportState() => {
    'mode': _mode.name,
    'totalAmount': totalAmount.text,
    if (_columnBaseAmount != null) 'baseAmount': _columnBaseAmount,
  };

  void restoreState(Object? raw) {
    if (raw is! Map) return;
    final modeName = raw['mode'];
    _mode = LinePricingMode.values.firstWhere(
      (value) => value.name == modeName,
      orElse: () => LinePricingMode.calculateAmount,
    );
    _columnBaseAmount = businessExactDecimal(raw['baseAmount']?.toString());
    _busy = true;
    try {
      _write(totalAmount, raw['totalAmount']?.toString() ?? '');
    } finally {
      _busy = false;
    }
    refresh();
  }

  /// Restore a server-recorded base total after quantity and columns are loaded.
  void restoreRecordedTotal(String? baseTotal) {
    if (baseTotal == null || baseTotal.trim().isEmpty) return;
    final base = businessExactDecimal(baseTotal);
    final amount = businessColumnAmount(
      base,
      extraColumns?.call() ?? const <BusinessColumn>[],
      allowNegative: true,
    );
    restoreState({
      'mode': LinePricingMode.calculatePrice.name,
      'totalAmount': amount ?? baseTotal,
      'baseAmount': ?base,
    });
    if (base == null || amount == null) {
      _baseAmount = null;
      _amountExact = null;
      error.value = '已记录总金额或附加列无效，请核对后重新输入';
      notifyListeners();
    }
  }

  void copyStateTo(LinePricingController target) =>
      target.restoreState(exportState());

  @override
  void dispose() {
    qty.removeListener(_onQty);
    price.removeListener(_onPrice);
    discount?.removeListener(_onDiscount);
    _extraColumnsChanged?.removeListener(_onExtraColumns);
    totalAmount.removeListener(_onTotal);
    totalAmount.dispose();
    error.dispose();
    super.dispose();
  }
}

void _write(TextEditingController controller, String text) {
  if (controller.text == text) return;
  controller.value = TextEditingValue(
    text: text,
    selection: TextSelection.collapsed(offset: text.length),
  );
}

String _negate(String value) =>
    value.startsWith('-') ? value.substring(1) : '-$value';

bool _equal(String left, String right) =>
    businessExactDecimal(financeExactSumTexts([left, _negate(right)])) == '0';

({String text, bool exact}) _divide(String left, String right, int scale) {
  final leftScale = left.contains('.') ? left.split('.').last.length : 0;
  final rightScale = right.contains('.') ? right.split('.').last.length : 0;
  final numerator =
      financeExactDecimalUnits(left, scale: leftScale)! *
      BigInt.from(10).pow(rightScale + scale);
  final denominator =
      financeExactDecimalUnits(right, scale: rightScale)! *
      BigInt.from(10).pow(leftScale);
  if (denominator == BigInt.zero) {
    throw const _PricingFailure('除数不能为 0');
  }
  final units = numerator ~/ denominator;
  final text = businessExactDecimal(
    financeExactDecimalFromUnits(units, scale: scale),
  );
  if (text == null) throw const _PricingFailure('反算结果超出精确范围');
  return (text: text, exact: numerator.remainder(denominator) == BigInt.zero);
}

class _PricingFailure implements Exception {
  const _PricingFailure(this.message);
  final String message;
}
