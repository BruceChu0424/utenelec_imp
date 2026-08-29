# UtenPickerConfirmBar · 滑窗选择器统一确认栏

> 源码：[`uten_picker_confirm_bar.dart`](../../lib/components/layout/uten_picker_confirm_bar.dart) · 视觉基座：[UtenBottomActionBar](UtenBottomActionBar.md) · 最后核对：2026-08-27。

## 一、用途

全站「滑窗/抽屉选择器」的统一底部确认栏，落实**二次操作契约**：点列表项仅高亮勾选，必须再点底部「确定」才把选中值 pop 回调用方；「取消」(或右上角关闭/点遮罩)= 放弃选择。公司年长用户多，点行即关的滑窗容易误选误关，2026-08-16 起所有选择滑窗统一为本契约。

## 二、参数

| 参数 | 说明 |
| --- | --- |
| `selectedCount` | 已选条数；0 时「确定」禁用、左侧显示「请选择后点『确定』」 |
| `onConfirm` | 确认回调(把选中值 `Navigator.pop` 回调用方) |
| `onCancel` | 取消回调；缺省直接关闭滑窗 |
| `selectedLabel` | 单选场景的已选项名称，左侧显示「已选择：xxx」；多选留空显示计数 |
| `onClear` | 多选场景的「清空」按钮；null 不显示 |
| `confirmLabel` | 确认按钮文案；多选调用方传「确定(n)」 |
| `hint` | 左侧提示覆盖(如报工计划行选择器显示「共 N 条可报工任务」) |

视觉沿用 `UtenBottomActionBar`(surface 吸底 + 顶部细分隔线 + 底部安全区)，左侧提示文字 + 右侧「清空(可选) / 取消 / 确定」。

## 三、接入方(2026-08-16 起)

- [UtenClientPicker](UtenClientPicker.md)(客户，单选)
- [UtenGoodsPicker](UtenGoodsPicker.md)(货品，单/多选；单选默认即二次确认)
- [UtenEmployeePicker](UtenEmployeePicker.md)(员工，单选)
- `UtenDepartmentPicker`(部门，单/多选；单选默认即二次确认)
- `UtenPositionPicker`(岗位，单选)
- [UtenDepartmentEmployeePicker](UtenDepartmentEmployeePicker.md)(部门内选员工，单选)
- 销售订单选择器(`sales_order_picker.dart`，生产计划来源单号)
- 可报工计划行选择器(`reportable_plan_line_picker.dart`)
- 公告类型选择器(`notice_type_picker.dart`)

「从上游引入」「批量发货」等带业务动作的面板(底部主按钮是「引入 / 生成出货单」)不属于纯选择器，维持各自的主按钮文案，不强改成本组件。

## 四、回归测试

各接入选择器自身的 widget 测试覆盖点行高亮与点确定返回(如 `uten_client_picker_test.dart`、`department_edit_dialog_test.dart`)。
