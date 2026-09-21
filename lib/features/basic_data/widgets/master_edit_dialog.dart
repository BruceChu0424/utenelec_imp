// 主档通用编辑（货品/模具/客户/供应商 新建 + 编辑 共用）。
//
// 各主档字段集不同，但表单交互一致：调用方按 [MasterFieldDef] 列表提供字段，
// 可用 [MasterFieldDef.group] 分段；固定值（如 categoryId）走 [fixedValues] 随提交
// 带上、不渲染输入框。
//
// 表单本体抽成公共 [MasterEditForm]（字段网格 + 校验 + buildBody），既给
// [showMasterEditDialog]（自带 header/actions 的弹窗）用，也给货品详情整页的
// 「基本信息」内联编辑 Tab 用（嵌入、由外层触发保存）。
//
// 容器自适应（参照 showMasterEditDialog）：compact 底部抽屉 / medium+ 居中面板。
// 字段双列分组（compact 退单列），底部按钮居中。
import 'package:flutter/material.dart';

import '../../../components/buttons/click_guard.dart';
import '../../../components/buttons/uten_button.dart';
import '../../../components/inputs/required_field_decoration.dart';
import '../../../components/inputs/uten_dropdown_field.dart';
import '../../../components/inputs/uten_field_message.dart';
import '../../../components/inputs/uten_input_decoration.dart';
import '../../../components/layout/uten_section_header.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/responsive/breakpoint.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../core/ui/action_feedback.dart';

/// 主档字段值类型：文本 / 整数 / 金额（double）/ 下拉选择。
enum MasterFieldType { text, integer, money, select, custom }

/// 下拉选项（select 类型用）：[value] 提交值、[label] 展示文案。
/// 颜色/单位选择器：value = legacy_id 字符串、label = 名称。
class MasterSelectOption {
  const MasterSelectOption({required this.value, required this.label});

  final String value;
  final String label;
}

/// 状态字段固定选项（使用/禁用），10 个主档共用。配合后端 CHECK(status IN ('使用','禁用'))。
const List<MasterSelectOption> kMasterStatusOptions = [
  MasterSelectOption(value: '使用', label: '使用'),
  MasterSelectOption(value: '禁用', label: '禁用'),
];

/// 货品「来源」字段固定选项（自制/采购/委外），对应 goods.source_type。
/// 值域与移植脚本 import_product_lists.py 的「产品角色」映射一致（自制件/外购件/委外件）。
const List<MasterSelectOption> kGoodsSourceTypeOptions = [
  MasterSelectOption(value: '自制', label: '自制'),
  MasterSelectOption(value: '采购', label: '采购'),
  MasterSelectOption(value: '委外', label: '委外'),
];

/// 自定义字段上下文：[MasterEditForm] ↔ 自定义 widget（[MasterFieldDef.customBuilder]）的值通道。
/// 初值来自 [MasterEditForm.initialValues]（字符串形式：日期=yyyy-MM-dd、picker=id）；
/// widget 内部自行转成所需类型（DateTime / UtenEmployeePickerItem 等），通过 [onChanged] 回写提交值。
class MasterFieldContext {
  const MasterFieldContext({
    this.initialValue,
    required this.onChanged,
    this.required = false,
  });

  final String? initialValue;

  final void Function(dynamic value) onChanged;

  /// 该自定义字段是否必填：customBuilder 可据此渲染红框（与表单内建字段口径一致）。
  final bool required;
}

/// 主档字段定义。
class MasterFieldDef {
  const MasterFieldDef({
    required this.key,
    required this.label,
    this.type = MasterFieldType.text,
    this.required = false,
    this.hint,
    this.info,
    this.group,
    this.options,
    this.selectInteger = false,
    this.readOnly = false,
    this.onAddNew,
    this.customBuilder,
  });

  /// 与后端 SaveRequest 字段名对齐（如 name / colorLegacyId）。
  final String key;

  /// 中文标签。
  final String label;

  final MasterFieldType type;

  /// 是否必填（label 后附 *，提交时空则报错）。
  final bool required;

  final String? hint;

  /// Optional guidance disclosed inside the field, never as a bottom caption.
  final String? info;

  /// 字段所属分组：表单按此分段、双列展示。null 归入「其他」。
  final String? group;

  /// select 类型的下拉选项（其他类型忽略）。
  final List<MasterSelectOption>? options;

  /// select 提交值是否按整数解析（颜色/单位 legacy_id = true，提交 JSON 数字）。
  final bool selectInteger;

  /// 只读字段（如编号）：禁用展示、不参与提交。
  /// 编辑时显既有值；新建时值为空 → 显 [hint]（如「保存后自动生成」）。
  final bool readOnly;

  /// select 字段的「添加新项」回调（颜色/单位内联新建）：非空时下拉浮层搜索下方显浅绿按钮，
  /// 返回新建项的 value（如新颜色 legacy_id 字符串）则自动选中；返回 null 不改。
  final Future<String?> Function()? onAddNew;

  /// 自定义字段 widget（date / 滑窗选择器等通用类型无法覆盖时）。
  /// 设了此项时 [type] 应为 [MasterFieldType.custom]，忽略 [options] 等；
  /// [required] 仍参与 buildBody 非空校验。widget 经 [MasterFieldContext.onChanged] 回写提交值。
  /// 闭包不可 const，故含此字段的字段表须从 `static const` 改 `static` 或实例 getter。
  final Widget Function(MasterFieldContext ctx)? customBuilder;
}

typedef MasterSubmit = Future<bool> Function(Map<String, dynamic> body);

/// 主档编辑表单的值容器：文本控制器 / 下拉值 / 自定义值 / 字段错误 / 整表错误。
///
/// [MasterEditForm] 不传 controller 时自建一个(弹窗、单页嵌入场景，生命周期随表单
/// State)；页面也可以先建好再共享给多张分区表单——客户详情页就地编辑把同一套字段按
/// group 拆到两个 Tab 各渲染一部分，保存时读的是同一份值：Tab 切换把表单 widget
/// 释放/重建不会丢输入，也不会因为某张表单当时没挂在树上而漏掉它(2026-09-20 修：
/// 此前两张表单各持 State，只改财务 Tab 再保存会静默失败、改动丢失)。
class MasterEditFormController extends ChangeNotifier {
  MasterEditFormController({
    required this.fields,
    Map<String, String> initialValues = const <String, String>{},
    this.fixedValues = const <String, dynamic>{},
  }) : initialValues = Map<String, String>.unmodifiable(initialValues) {
    for (final f in fields) {
      switch (f.type) {
        case MasterFieldType.select:
          // 初始值不在选项里（如对应记录已删）→ 视为未选，避免 Dropdown 断言。
          final init = initialValues[f.key];
          final values = {
            for (final o in f.options ?? const <MasterSelectOption>[]) o.value,
          };
          selectValues[f.key] =
              (init != null && init.isNotEmpty && values.contains(init))
              ? init
              : null;
        case MasterFieldType.custom:
          // custom 字段初值（字符串：日期/picker id）；空串统一记 null。
          final init = initialValues[f.key];
          customValues[f.key] = (init == null || init.isEmpty) ? null : init;
        case MasterFieldType.text:
        case MasterFieldType.integer:
        case MasterFieldType.money:
          final controller = TextEditingController(
            text: initialValues[f.key] ?? '',
          );
          // 字段错误（如后端编号查重）随用户开始编辑自动清除。
          controller.addListener(() {
            if (fieldErrors.remove(f.key) != null) notifyListeners();
          });
          controllers[f.key] = controller;
      }
    }
  }

  /// 整套字段（可能跨多张分区表单）。
  final List<MasterFieldDef> fields;

  /// 初始值（字符串形式），供 custom 字段的 widget 取初值。
  final Map<String, String> initialValues;

  /// 固定随提交带上、不渲染输入框的值（如 categoryId / version）。
  final Map<String, dynamic> fixedValues;

  /// text / integer / money 字段的控制器。
  final Map<String, TextEditingController> controllers = {};

  /// select 字段当前选中值（未选为 null）。
  final Map<String, String?> selectValues = {};

  /// custom 字段当前提交值（未填为 null）。
  final Map<String, dynamic> customValues = {};

  /// 外部字段错误（key → 文案），如后端编号查重 409 回填「编号已存在」。
  final Map<String, String> fieldErrors = {};

  /// 最近一次 [buildBody] 的整表错误文案与出错字段；成功后清空。
  String? error;
  String? errorFieldKey;

  MasterFieldDef? fieldOf(String key) {
    for (final f in fields) {
      if (f.key == key) return f;
    }
    return null;
  }

  void setSelect(String key, String? value) {
    selectValues[key] = value;
    notifyListeners();
  }

  void setCustom(String key, dynamic value) {
    customValues[key] = value;
    notifyListeners();
  }

  /// 外部设置某字段错误（如编号查重 409）→ 字段描红边 + 字段下显错文案。
  void setFieldError(String key, String message) {
    fieldErrors[key] = message;
    notifyListeners();
  }

  /// 校验全部字段并构造提交 body（含 [fixedValues]）；
  /// 校验失败返 null 并置 [error] / [errorFieldKey]。
  Map<String, dynamic>? buildBody() {
    final body = Map<String, dynamic>.from(fixedValues);
    for (final f in fields) {
      if (f.readOnly) continue; // 只读字段（编号）不上送：新建服务端生成、编辑保留
      switch (f.type) {
        case MasterFieldType.select:
          final sv = selectValues[f.key];
          if (f.required && (sv == null || sv.isEmpty)) {
            return _fail(f, '请选择「${f.label}」'); // TODO(l10n): 补 arb
          }
          if (sv == null || sv.isEmpty) {
            body[f.key] = null;
          } else if (f.selectInteger) {
            final v = int.tryParse(sv);
            if (v == null) {
              return _fail(f, '「${f.label}」值非法'); // TODO(l10n): 补 arb
            }
            body[f.key] = v;
          } else {
            body[f.key] = sv;
          }
        case MasterFieldType.custom:
          final v = customValues[f.key];
          if (f.required && (v == null || (v is String && v.isEmpty))) {
            return _fail(f, '请选择「${f.label}」'); // TODO(l10n): 补 arb
          }
          // 复合字段（如数字+单位）回写 {key1: v1, key2: v2} 直接展开到 body，
          // 而非塞进单个 f.key（一个可视字段格位对应多个提交字段）。
          if (v is Map<String, dynamic>) {
            body.addAll(v);
          } else {
            body[f.key] = v;
          }
        case MasterFieldType.text:
        case MasterFieldType.integer:
        case MasterFieldType.money:
          final raw = controllers[f.key]!.text.trim();
          if (f.required && raw.isEmpty) {
            return _fail(f, '请填写「${f.label}」'); // TODO(l10n): 补 arb
          }
          if (raw.isEmpty) {
            body[f.key] = null; // 空串统一存 null，保持与老库 nullable 一致
          } else if (f.type == MasterFieldType.integer) {
            final v = int.tryParse(raw);
            if (v == null) {
              return _fail(f, '「${f.label}」需为整数'); // TODO(l10n): 补 arb
            }
            body[f.key] = v;
          } else if (f.type == MasterFieldType.money) {
            final v = double.tryParse(raw);
            if (v == null) {
              return _fail(f, '「${f.label}」需为数字'); // TODO(l10n): 补 arb
            }
            body[f.key] = v;
          } else {
            body[f.key] = raw;
          }
      }
    }
    error = null;
    errorFieldKey = null;
    fieldErrors.clear(); // 重新提交：清掉旧字段错误（如编号查重），按本次结果重判
    notifyListeners();
    return body;
  }

  Map<String, dynamic>? _fail(MasterFieldDef f, String message) {
    error = message;
    errorFieldKey = f.key;
    notifyListeners();
    return null;
  }

  @override
  void dispose() {
    for (final c in controllers.values) {
      c.dispose();
    }
    super.dispose();
  }
}

/// 主档编辑表单本体（字段网格 + 校验）。无 header / 无 actions——由调用方包裹。
///
/// 调用方持 `GlobalKey<MasterEditFormState>`，保存时调 [buildBody] 取校验后的 body
/// （校验失败返 null、内部已置错文案）；多张分区表单共享一个
/// [MasterEditFormController] 时直接调它的 buildBody，不依赖表单是否挂在树上。
class MasterEditForm extends StatefulWidget {
  const MasterEditForm({
    super.key,
    required this.fields,
    this.initialValues = const <String, String>{},
    this.fixedValues = const <String, dynamic>{},
    this.readOnlyKeys,
    this.controller,
  });

  /// 本表单渲染的字段；给了 [controller] 时须是它 fields 的子集。
  final List<MasterFieldDef> fields;

  /// 自建控制器时的初始值 / 固定值；给了 [controller] 时忽略，以它为准。
  final Map<String, String> initialValues;
  final Map<String, dynamic> fixedValues;

  /// 运行期只读字段 key 集合（如无 goods:price:edit 时锁定 price/discount）：
  /// 仅 UI 禁用展示，buildBody 仍照常上送控制器现有值（与 MasterFieldDef.readOnly 不同——
  /// 后者整段跳过不上送，用于编号等系统生成字段）。故锁定字段以原值回传，后端判定「未改」放行。
  final Set<String>? readOnlyKeys;

  /// 外部共享的值容器（页面持有、跨 Tab 存活）；不传则表单自建并随 State 释放。
  final MasterEditFormController? controller;

  @override
  State<MasterEditForm> createState() => MasterEditFormState();
}

class MasterEditFormState extends State<MasterEditForm> {
  late MasterEditFormController _controller;
  bool _ownsController = false;

  /// 锁定的下拉/自定义字段没有文本控制器，只读展示按字段缓存一个（随 State 释放）。
  final Map<String, TextEditingController> _readOnlyDisplay = {};

  MasterEditFormController get controller => _controller;

  @override
  void initState() {
    super.initState();
    _attach();
  }

  @override
  void didUpdateWidget(MasterEditForm oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      _detach();
      _attach();
    }
  }

  void _attach() {
    final shared = widget.controller;
    _ownsController = shared == null;
    _controller =
        shared ??
        MasterEditFormController(
          fields: widget.fields,
          initialValues: widget.initialValues,
          fixedValues: widget.fixedValues,
        );
    _controller.addListener(_onControllerChanged);
  }

  void _detach() {
    _controller.removeListener(_onControllerChanged);
    if (_ownsController) _controller.dispose();
  }

  void _onControllerChanged() {
    if (mounted) setState(() {});
  }

  /// 外部设置某字段错误（如编号查重 409）→ 字段描红边 + 字段下显错文案；不关弹窗。
  void setFieldError(String key, String message) =>
      _controller.setFieldError(key, message);

  @override
  void dispose() {
    _detach();
    for (final c in _readOnlyDisplay.values) {
      c.dispose();
    }
    super.dispose();
  }

  /// 校验并构造提交 body（含 fixedValues）；校验失败返 null 并在表单内显错文案。
  Map<String, dynamic>? buildBody() => _controller.buildBody();

  @override
  Widget build(BuildContext context) {
    final twoColumn = !context.breakpoint.isCompact;

    // 按 group 声明顺序分段（null → 「其他」）。
    final groupOrder = <String>[];
    final groups = <String, List<MasterFieldDef>>{};
    for (final f in widget.fields) {
      final g = f.group ?? '其他'; // TODO(l10n): 补 arb
      (groups[g] ??= <MasterFieldDef>[]).add(f);
      if (!groupOrder.contains(g)) groupOrder.add(g);
    }
    // 整表错误只在出错字段所在的那张表单里显示（共享控制器时另一张表单不重复报）。
    final error = _controller.error;
    final errorKey = _controller.errorFieldKey;
    final showError =
        error != null &&
        (errorKey == null || widget.fields.any((f) => f.key == errorKey));

    return SingleChildScrollView(
      padding: const EdgeInsets.all(UtenSpacing.s16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (var i = 0; i < groupOrder.length; i++) ...[
            if (i > 0) const SizedBox(height: UtenSpacing.s20),
            UtenSectionHeader(title: groupOrder[i], subdued: true),
            const SizedBox(height: UtenSpacing.s12),
            _fieldGrid(groups[groupOrder[i]]!, twoColumn),
          ],
          if (showError) ...[
            const SizedBox(height: UtenSpacing.s4),
            UtenFieldMessage.error(error),
          ],
        ],
      ),
    );
  }

  Widget _fieldGrid(List<MasterFieldDef> fields, bool twoColumn) {
    if (!twoColumn) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (final f in fields) ...[
            _field(f),
            const SizedBox(height: UtenSpacing.s12),
          ],
        ],
      );
    }
    // 2026-09-14：列数按容器实际宽度自适应（每列约 260 宽，1-4 列），
    // 屏幕越大一行显示越多，不再固定两列。
    return LayoutBuilder(
      builder: (context, constraints) {
        final colCount = (constraints.maxWidth ~/ 260).clamp(1, 4);
        if (colCount == 1) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              for (final f in fields) ...[
                _field(f),
                const SizedBox(height: UtenSpacing.s12),
              ],
            ],
          );
        }
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (var i = 0; i < fields.length; i += colCount)
              Padding(
                padding: const EdgeInsets.only(bottom: UtenSpacing.s12),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    for (var c = 0; c < colCount; c++) ...[
                      if (c > 0) const SizedBox(width: UtenSpacing.s12),
                      Expanded(
                        child: i + c < fields.length
                            ? _field(fields[i + c])
                            : const SizedBox.shrink(),
                      ),
                    ],
                  ],
                ),
              ),
          ],
        );
      },
    );
  }

  Widget _field(MasterFieldDef f) {
    final locked = widget.readOnlyKeys?.contains(f.key) ?? false;
    if (f.readOnly || locked) return _readOnlyField(f);
    if (f.type == MasterFieldType.select) return _selectField(f);
    if (f.type == MasterFieldType.custom) {
      return f.customBuilder!(
        MasterFieldContext(
          initialValue: _controller.initialValues[f.key],
          onChanged: (v) => _controller.setCustom(f.key, v),
          required: f.required,
        ),
      );
    }
    // text / integer / money：听控制器，必填且为空时描红边 + 红 *，填好即恢复；
    // 外部字段错误(如后端编号查重 409)通过红边和框内图标提示，用户开始编辑即清除。
    final theme = Theme.of(context);
    final controller = _controller.controllers[f.key]!;
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final requiredEmpty = f.required && controller.text.trim().isEmpty;
        final fieldError = _controller.fieldErrors[f.key];
        final showRed = requiredEmpty || fieldError != null;
        return TextField(
          controller: controller,
          keyboardType: f.type == MasterFieldType.text
              ? TextInputType.text
              : const TextInputType.numberWithOptions(decimal: true),
          decoration: UtenInputDecoration(
            applyRequiredEmpty(
              InputDecoration(
                label: requiredLabel(
                  f.label,
                  theme,
                  required: f.required,
                  base: theme.inputDecorationTheme.labelStyle,
                ),
                hintText: f.hint,
                error: utenFieldError(fieldError),
              ),
              theme,
              requiredEmpty: showRed,
            ),
          ),
        );
      },
    );
  }

  /// 只读字段：禁用展示。文本类显控制器现值；下拉类显当前选项文案(此前锁定的
  /// 下拉字段会显成空)；新建时空值显 [MasterFieldDef.hint]。
  Widget _readOnlyField(MasterFieldDef f) {
    final ctl = _controller.controllers[f.key];
    if (ctl != null) {
      return TextField(
        controller: ctl,
        enabled: false,
        decoration: InputDecoration(
          labelText: f.label,
          hintText: ctl.text.isEmpty ? (f.hint ?? '') : null,
        ),
      );
    }
    String display = '';
    if (f.type == MasterFieldType.select) {
      final value = _controller.selectValues[f.key];
      display = value ?? '';
      for (final o in f.options ?? const <MasterSelectOption>[]) {
        if (o.value == value) display = o.label;
      }
    } else {
      display = _controller.customValues[f.key]?.toString() ?? '';
    }
    final displayController = _readOnlyDisplay.putIfAbsent(
      f.key,
      () => TextEditingController(text: display),
    );
    if (displayController.text != display) displayController.text = display;
    return TextField(
      controller: displayController,
      enabled: false,
      decoration: InputDecoration(
        labelText: f.label,
        hintText: display.isEmpty ? (f.hint ?? '') : null,
      ),
    );
  }

  /// select 字段：UtenDropdownField（Overlay 弹层，对齐全站下拉；根治溢出）。
  /// required → 不显示「不选」（强制选）；非 required → allowClear 可清空回 null。
  /// onAddNew（颜色/单位内联新建）：返回新值则自动选中。
  Widget _selectField(MasterFieldDef f) {
    final options = f.options ?? const <MasterSelectOption>[];
    return UtenDropdownField(
      label: f.label,
      required: f.required,
      value: _controller.selectValues[f.key],
      allowClear: !f.required,
      hintText: f.hint,
      info: f.info,
      addNewLabel: f.onAddNew == null ? null : '添加${f.label}',
      items: [
        for (final o in options)
          UtenDropdownItem(value: o.value, label: o.label),
      ],
      onChanged: (v) => _controller.setSelect(f.key, v),
      onAddNew: f.onAddNew == null
          ? null
          : () async {
              final v = await f.onAddNew!();
              if (v != null) _controller.setSelect(f.key, v);
            },
    );
  }
}

/// 自适应弹出主档编辑表单：compact 底部抽屉 / medium+ 居中面板（薄包装 MasterEditForm）。
///
/// [onSubmit] 返回 true 关闭、false 保持打开（仿 CategoryEditDialog 范式）。
Future<void> showMasterEditDialog({
  required BuildContext context,
  required String title,
  required List<MasterFieldDef> fields,
  required MasterSubmit onSubmit,
  Map<String, String> initialValues = const <String, String>{},
  Map<String, dynamic> fixedValues = const <String, dynamic>{},
  Set<String>? readOnlyKeys,
}) {
  final formKey = GlobalKey<MasterEditFormState>();
  final body = _MasterEditDialog(
    title: title,
    formKey: formKey,
    fields: fields,
    initialValues: initialValues,
    fixedValues: fixedValues,
    readOnlyKeys: readOnlyKeys,
    onSubmit: onSubmit,
  );
  if (context.breakpoint.isCompact) {
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(
          top: Radius.circular(UtenRadius.lg),
        ),
      ),
      builder: (ctx) => Padding(
        padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(ctx).bottom),
        child: body,
      ),
    );
  }
  return showDialog<void>(
    context: context,
    builder: (ctx) => Dialog(
      shape: const RoundedRectangleBorder(borderRadius: UtenRadius.xxlAll),
      child: ConstrainedBox(
        // 2026-09-14：弹窗宽度随屏幕放缩（原固定 560 太小，一行固定两列）；
        // 大屏最宽 900，表单网格列数在 _fieldGrid 里按实际宽度自适应。
        constraints: BoxConstraints(
          maxWidth: (MediaQuery.sizeOf(ctx).width * 0.92).clamp(560.0, 900.0),
          maxHeight: MediaQuery.sizeOf(ctx).height * 0.88,
        ),
        child: body,
      ),
    ),
  );
}

/// showMasterEditDialog 的壳：header + MasterEditForm + actions（保存触发 buildBody→onSubmit→pop）。
class _MasterEditDialog extends StatefulWidget {
  const _MasterEditDialog({
    required this.title,
    required this.formKey,
    required this.fields,
    required this.initialValues,
    required this.fixedValues,
    required this.readOnlyKeys,
    required this.onSubmit,
  });

  final String title;
  final GlobalKey<MasterEditFormState> formKey;
  final List<MasterFieldDef> fields;
  final Map<String, String> initialValues;
  final Map<String, dynamic> fixedValues;
  final Set<String>? readOnlyKeys;
  final MasterSubmit onSubmit;

  @override
  State<_MasterEditDialog> createState() => _MasterEditDialogState();
}

class _MasterEditDialogState extends State<_MasterEditDialog> {
  Future<void> _save() async {
    final body = widget.formKey.currentState?.buildBody();
    if (body == null) return; // 校验失败，错文案已在表单内
    late final bool ok;
    try {
      ok = await widget.onSubmit(body);
    } catch (e) {
      if (!mounted) return;
      // 编号查重 409：编号字段描红 + 显文案，保持弹窗不关让用户改。
      if (e is ApiException && e.message.contains('编号已存在')) {
        widget.formKey.currentState?.setFieldError('code', e.message);
        return;
      }
      context.appApiError(e);
      return;
    }
    if (!mounted) return;
    if (ok) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(
              UtenSpacing.s16,
              UtenSpacing.s12,
              UtenSpacing.s8,
              UtenSpacing.s12,
            ),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    widget.title,
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.close_rounded),
                  onPressed: () => Navigator.of(context).pop(),
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          Flexible(
            child: MasterEditForm(
              key: widget.formKey,
              fields: widget.fields,
              initialValues: widget.initialValues,
              fixedValues: widget.fixedValues,
              readOnlyKeys: widget.readOnlyKeys,
            ),
          ),
          const Divider(height: 1),
          Padding(
            padding: const EdgeInsets.all(UtenSpacing.s16),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              mainAxisSize: MainAxisSize.min,
              children: [
                UtenButton(
                  type: UtenButtonType.secondary,
                  onPressed: () => Navigator.of(context).pop(),
                  child: const Text('取消'), // TODO(l10n): 补 arb
                ),
                const SizedBox(width: UtenSpacing.s12),
                UtenActionButton(
                  label: const Text('保存'), // TODO(l10n): 补 arb
                  onAction: _save,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
