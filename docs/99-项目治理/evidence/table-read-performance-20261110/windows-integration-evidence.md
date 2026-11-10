# Windows LocalTest 实际窗口交互回执

测试入口：`integration_test/table_complete_read_stability_test.dart`。完整原始日志：`windows-integration-prebuild.log`、`windows-integration-run1.log`、`windows-integration-run2.log`。最终结构化回执：`windows-integration-acceptance.json`。

命令：`flutter test integration_test/table_complete_read_stability_test.dart -d windows --no-pub --dart-define=UTEN_LOCAL_TEST=true --dart-define=API_BASE_URL=http://127.0.0.1:9/api --reporter expanded`。

使用本工作树 Debug 测试入口。原生ProductName与manifest均为LocalTest，网络约束loopback-only，禁止自更新；SharedPreferences使用Mock，不共享安装版列布局偏好。没有运行正式业务入口、登录公司服务或发布产物。

## 失败证据与修复

run1初次35k完整场景PASS、framework errors为空，但第2次查询提交断言失败：输入期望“桌面快速查询 1”，查询范围仍为“桌面快速查询 0”。没有放宽断言。

本地Flutter SDK `TestWidgetsFlutterBinding.focusedEditable` setter仅在EditableTextState对象变化时重新requestKeyboard；原生done动作失焦后，测试直接再次enterText同一对象未必重新建立焦点。修复仅位于测试驱动：每次先通过真实pointer tap重新聚焦、pump，再enterText；新增controller文字确已更新的断言，继续用平台TextInputAction.done消息触发公开TextField.onSubmitted。产品源码和合成fixture均未改动。

## run2 结果

- 整体测试：`00:42 +1: All tests passed!`。
- 初次及最终恢复均完整35,000行；来源列表和表格controller逐行校验索引及generation。
- 实际20次查询提交、5次取消；最终累计20个旧读取退休，fixture记录20个晚回，全部未重新发布。
- 取消后的临时行整体撤下；最终active=0、errors=0。
- 旁路中文文本在连续查询/取消/恢复后保持。
- 实际勾选1行；列隐藏/恢复后选择仍为1；鼠标拖动自有滚动条3次往返首尾，首行/末行真实挂载可见且选择保持。
- 滚动前后syntheticBatchCalls不变，未通过滚动补读。

本轮与root编译可并行，所有日志中的时钟仅作定位，不是Windows性能SLA或低配帧率验收。文字输入通过Flutter测试文本/组合消息，并未验证Windows中文IME候选窗；这是生产公共表格/读取器的合成只读DTO交互，不证明财务计算、业务写入或真正持久化草稿恢复。
