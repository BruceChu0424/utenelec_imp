# UtenInlineEditCell

源码: `lib/components/inputs/uten_inline_edit_cell.dart`。

该组件从货品主档的单格编辑入口提取延迟挂载机制，沿用现有预览外观，不增加保存、网络请求或业务状态。相关前端工作默认使用 `frontend-design`，继续复用 Uten 主题及组件。

## 挂载与身份

- 未激活时只构建 `preview`，不调用 `editorBuilder`。选项查询、文本控制器等编辑准备应放在宿主的激活回调或编辑器自身的初始化中。
- 点击或键盘激活后才构建编辑器。`preview` 更新、父组件重建和临时置忙不使编辑器退回预览。
- `key` 表示编辑身份。行、字段和业务草稿相同时保持稳定；确认切换业务对象或重置编辑会话时才改变。
- `activationKey` 只定位预览的激活入口，不替代业务输入框原有的 key。

## 输入与冻结

- 预览使用 Material 的焦点和激活动作，支持 Tab/Shift+Tab 遍历及 Enter/Space 激活。
- `editorBuilder` 内的文本框自行设置 `autofocus`，使第一次激活后焦点进入目标输入框。
- `enabled=false` 阻止未激活的入口，并冻结已经挂载编辑器的鼠标操作。默认同时排除键盘焦点；宿主仍须在业务变更入口检查权限及置忙状态。
- 临时加载中的文本格可设置 `retainFocusWhenDisabled=true`，并同步设置自身 `TextField.readOnly=true`。该组合保留 FocusNode、controller、选择区及 composing 值，同时阻止键盘继续修改。不能只用 IgnorePointer 代替键盘冻结。
- 真实权限撤销、账号或资料作用域变化仍由宿主清理会话和拒绝保存，不能由此组件恢复旧授权。

## 值与控制器

- TextEditingController、FocusNode、草稿、校验、CAS 和保存回执归业务宿主所有，本组件不创建或重置它们。
- 不应在无关父组件重建中以归一化值回写正在输入的文本。尤其不能因为 trim 后 patch 为空，就清除空格、选择区或 IME composing。
- 相同业务格的多个挂载副本共享业务草稿。未获得焦点的副本可同步当前值；有焦点或正在组合输入的副本保留本地编辑值。
- `requiredEmpty` 保留新增必填空值的既有红框提示。字段必填校验和保存规则仍由宿主负责。

## 消费路径

- 主档已有行: `MasterInlineEditController.columns` / `MasterInlineRecordEditor`。
- 主档追加新增行: `MasterInlineCreateConfig` 对应的单格编辑器。
- 组装信息: `GoodsBomTab` 的业务单元格。

基础资料共享消费方包括货品、客户、供应商、模具的分类列表，以及单位、颜色、币种、仓库、结算方式、收付款类别和账户的扁平工作区。分类表单与详情表单继续沿用自身的控制器及草稿，不因复用本组件改变提交语义。
