# UtenDialog

源码: [`lib/components/feedback/uten_dialog.dart`](../../lib/components/feedback/uten_dialog.dart)。

`UtenDialog.show` 提供已有的统一确认样式。需要定制输入布局时，沿用业务弹窗的 builder，并通过 `UtenDialog.showAndWaitForExit<T>` 等待弹层完全退出后再释放外部控制器。

## 2026-10-28 统一渐变弹窗与模块

设计默认使用 `frontend-design`，以本次用户提供的第三张图为视觉依据。顶部青绿色渐变向下融入主题底色，左侧图标块对应标题和说明，内容左对齐，底部用细分隔线和整组居中的操作建立层次。普通弹窗、业务工作区、同一表单的手机底部弹层复用以下入口，业务代码只组合内容和回调。

| 公共入口 | 职责及参数 |
|---|---|
| `UtenAlertDialog` | 短确认和表单；传 `title`、`subtitle`、`headingIcon`、`content`、`actions`。`showCloseButton` 在允许取消的流程显式启用；`onClose` 可配置关闭动作 |
| `UtenDialogFrame` | 表格、编辑器、核对和预览的有界工作区；自动提供渐变表面、圆角和轻柔阴影 |
| `UtenDialogSurface` | 没有约束、滚动或路由行为的渐变表面；全屏/底部弹层可以复用；嵌套时只绘制一层渐变 |
| `UtenDialogHeader` / `UtenDialogHeading` | 标题、可选说明、图标块、可组合 `leading`/`trailing` 及关闭按钮；`Header` 的 `showCloseButton: true, onClose: null` 保持可见但禁用，供保存/下载保护；可传 `closeTooltip` 保留原入口标签 |
| `UtenDialogActions` | 细分隔线、间距、居中按钮组、窄屏溢出堆叠；同时统一 Material 按钮和 `UtenButton` 的视觉规格，保留禁用、危险操作及回调 |
| `UtenDialogField` | 外置字段标签、输入模块、可选说明；控制器和验证由调用方持有 |
| `UtenDialogSettingTile` | 整行可点击的图标、标题、说明、尾部箭头/自定义控件；用于密码等设置，默认浅底和整卡主色细描边 |
| `UtenDialogOptionCard` | 全卡片选择、右侧单选标记、选中描边与浅色底，支持键盘和大字布局 |

设置卡片默认采用与导入选中项一致的主题主色细边框；单选卡片仍明确区分选中主色、未选中浅灰。组合原生 Radio/Switch 时传 `canRequestFocus: false`，由原生控件负责键盘焦点，保留 RadioGroup 箭头导航；纯设置入口继续支持整卡 Tab/Enter。普通信息、提示和业务状态卡不套用选择状态。

模块源码位于 [`uten_dialog_chrome.dart`](../../lib/components/feedback/uten_dialog_chrome.dart)、[`uten_dialog_modules.dart`](../../lib/components/feedback/uten_dialog_modules.dart)，标题/表面/操作区由原 `uten_dialog.dart` 统一导出。

配色使用已有主题语义：默认浅色主色 `#0F766E`、白色表面 `#FFFFFF`、主文字 `#0F172A`、辅助文字 `#475569`、细边框 `#E2E8F0`；深色底面 `#101A2C` 配主题亮青绿。公司自定义品牌继续跟随 `ColorScheme`，不在业务弹窗硬编码上述颜色。浅色顶部主色叠加 7.5%，深色 16%，渐变最多延伸 220 逻辑像素，底部恢复原表面。标题 20/700，说明使用 `bodyMedium`，沿用 NotoSansSC；弹窗圆角 `UtenRadius.dialog`（20），输入、按钮和模块圆角 `UtenRadius.control`（10）。

底部按钮由公共布局先测量组内实际最大高度，再以同一个紧高度重新布局所有按钮表面；带图标、混合原生/自定义按钮、放大字号或文案换行时仍等高，窄屏堆叠也沿用这一高度，不能只设置相同 `minHeight`。常规最小高度 48，宽度随文案和图标调整；取消使用浅灰底/淡描边，主动作保留主题主色和轻微阴影。可点击面积继续遵循 `UtenControlMetrics`，缩放不会缩小手机触控目标。图标块在极窄局部空间缩小或省略装饰，正文、标题和关闭控件继续保留；选项卡正常字号等高，大字时允许内容自然增高。

```dart
UtenAlertDialog(
  title: const Text('选择处理方式'),
  subtitle: const Text('请选择本次导入的处理方式'),
  headingIcon: Icons.file_upload_outlined,
  showCloseButton: true,
  content: UtenDialogOptionCard(
    icon: Icons.note_add_outlined,
    title: const Text('新建货品'),
    subtitle: const Text('全部新建，保留文件中的分类'),
    selected: selected,
    onTap: selectCreate,
  ),
  actions: [
    UtenButton(type: UtenButtonType.secondary, onPressed: cancel,
      child: const Text('取消')),
    UtenButton(onPressed: next, child: const Text('下一步')),
  ],
)
```

保留差异：原生日历/时钟继续保留专用交互，文件选择器由系统拥有；侧滑面板保持响应式路线，打印纸面保持白色和原始版式。庆典插画保留居中内容，复杂业务标题可组合原有帮助/权限控件，不自动拆解其 Widget。仅视觉统一，金额、数量、单位、原始来源、权限、草稿、身份代次、提交和控制器退出协议不变。

完整逐调用清单、迁移回执、测试日志及实际功能路由测试截图位于 `output/dialog-unification-20261028/`。清单将源码接入、组件/调用方回归和真实员工验收分别记录；源码接入不代表已逐一人工点击或已部署。

## 外部控制器的生命周期

Flutter `showDialog` 返回的结果在 `Navigator.pop` 时完成，此时退场动画中的 `TextField` 仍然挂载。外部创建的 `TextEditingController` 只有在路由 `completed` 之后才能释放。`showAndWaitForExit` 包装原 Material `showDialog`，保留其 root navigator、barrier、主题、媒体信息、safe area 和 route settings 默认行为；它从实际 builder 上捕获 `ModalRoute` 并等待 `completed`，没有另建一套 DialogRoute 协议。

- 数量、原因等业务输入在确认按钮中读取并作为类型化结果返回，确认后不再读取可变控制器来组装命令。
- 调用方等待 helper 后释放控制器，再校验页面、资源和身份是否仍属于本次动作，才可执行命令。
- 属于弹窗自身 `State` 的控制器继续在该 State 的 `dispose` 中释放。
- 不用固定延迟估计动画何时结束；本次采购/委外改量的 300ms 近似延迟已改为实际路由完成。

```dart
final controller = TextEditingController();
final result = await UtenDialog.showAndWaitForExit<String>(
  context,
  builder: (dialogContext) => UtenAlertDialog(
    content: TextField(controller: controller),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(dialogContext, controller.text),
        child: const Text('确认'),
      ),
    ],
  ),
);
controller.dispose();
```

当前外置控制器审计覆盖42处直接创建、34个所有者函数：原7个已使用路由完成等待的函数保留，另27个迁入统一等待。覆盖表格粘贴数量/追加行、员工电话、采购退货、车间物料更正/取消、访客审批、委外短交决定、盘点审核、销售改量/驳回、薪资审核、财务订单确认/资产过账/委外损失索赔/供应商结算、岗位编辑及往来单位联系人/地址/活动，并补齐通过`UtenDialog.show`借用局部控制器的保安拉黑和物料整批撤回；原生产计划包取消/冲销、仓库成品实收、账户余额警戒线、销售稀缺让单、仓库销售出库备注、采购/委外订货改量继续采用同一协议。弹窗自身State拥有的控制器仍在State.dispose释放。

需要统一确认样式且正文借用局部控制器时，`UtenDialog.show(waitForExit: true, onPopped: ...)`复用等待协议；`onPopped`只冻结输入，caller用finally释放控制器。普通`show`默认时序保留。全仓`show`正文直接借用控制器的4点中，上述2点属于局部所有者；另外盘点会话/行内盘点的理由由页面State持有，保持State的原销毁边界。

`showAndWaitForExit`从入口直到`route.completed`持有调用页面context的弱引用租约。同一context在弹窗尚未显示或退场动画期间再次调用会得到取消结果null，不运行第二个builder或onPopped，也不释放第一个调用的租约；不同context互不阻塞。确认、取消、构造异常和快照异常后都释放租约，允许再次打开。等待退场属于确认期，不把它显示成API请求忙态；命令仍在调用方完成身份、权限与数量校验后执行。真实销售改量和发货驳回按钮的退场指针回归验证每次仅打开一个确认窗、提交一个命令。


## 2026-10-13 统一尺寸与滚动

- `UtenDialog.show`与`UtenCenterAlert`使用520设计宽；`UtenAlertDialog`是原生AlertDialog的统一适配壳，普通设计宽560，默认可滚正文，保留原生焦点、语义、动作overflow和返回值。
- `UtenDialogFrame`承载大型业务面板，默认上限960，整窗高度最大为扣除键盘/安全区后的可用高85%。它不替代业务内部有界表格的滚动或确认状态。
- 小宽内距12；画布小于240时外侧水平边距4，避免200%手机把正文和按钮挤没。很短窗口中动作区也放不下时整体滚动，正文和动作都可达；通常窗口按钮保持在正文滚动区之外。
- 正文和标题使用同一NotoSansSC字体体系；正文16、标题18，系统非线性文字策略不丢失。外框圆角20；控制器与业务身份不随布局切换重建。
- 主体是独立有界列表或表格时，可显式 `scrollable:false`。长确认表单由共享壳统一滚动标题和正文，不再在正文外层叠加自己的ScrollView；其中的小段明细清单仍可保持有界独立滚动。
- `showAndWaitForExit`的 `onPopped`仅用来在pop时快照确认值，随后才等待退出；即使快照抛错也必须等待completed再释放外置controller。命令、权限与身份检查仍在调用方执行。

验证包含320手机至桌面、横屏低高、85%～200%、系统文字与应用倍率叠加、键盘、确认/取消、数量全文与真实点击坐标。格式与组件采用护栏：[ui_geometry_contract_test.dart](../../test/core/ui_geometry_contract_test.dart)。

多按钮选择弹窗在可用高度不足以容纳堆叠操作及最小正文时，整体进入滚动模式；标准空间仍保持操作区固定。报价模板使用共享弹窗的一处正文滚动，避免内嵌惰性视口被长操作区挤成零高度。

检验报告确认采用同一共享滚动：320×640窗口、200%应用倍率下，原先固定标题和操作区将正文视口压到13.6逻辑像素，48逻辑像素的错误提示按钮无法完整进入视口。标题与正文共同滚动后，原因输入、错误说明及精确数量均可到达；控制器、检验数量和提交校验保持原契约。只滚正文并不能解决被固定标题挤占的可用空间。

长弹窗明确显示自身滚动条，提示有更多内容；内容子树继续使用原滚动配置，业务表格不叠加自动滚动条。矮窗整窗滚动模式使用完整设计宽度，滚动条贴在弹窗边缘。验证夹具使用实际UtenScrollBehavior而非默认Windows行为。

## 2026-10-21 确认层级与实际宽度

短文案弹窗原先仅设置最大宽度，Material 内在尺寸仍会把它缩到280，造成生产下单、退出登录等确认框过小。共享壳现在显式取设计宽与当前可用画布的较小值；尺寸不再依赖正文长度。设计继续默认使用 `frontend-design`，复用主题色、字体、间距和圆角 token。

`UtenDialogHeading`统一图标、标题层级；正文使用主题 `bodyLarge` 和1.55行高，操作按钮使用大号规格并保留原生溢出换行。`UtenDialog.show`与居中提醒都使用 `UtenAnim.fast` 的轻微进退场，减少动画、lite和停用ticker时立即呈现。取消、遮罩关闭、退出完成等待与身份校验协议保持原有行为。

定向回归包括桌面520实际卡片宽、390手机200%文字、640横屏200%、暗色、取消零写入、确认租约及外部控制器退场释放；截图为widget夹具，不能代表运行中的服务器版本。
