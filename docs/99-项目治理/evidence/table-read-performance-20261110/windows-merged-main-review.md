# 合并后公共表格 / RowWindow 原生复核

输入为候选 `e16f4fb2268dc2ac01f5611c3079c246806a0925` 与 main `e9713e539a97a0fca5e579ce1cab633002af960a` 的合并工作树；未修改产品、治理文件或原测试断言，未commit。源码前后SHA-256记录见对应acceptance JSON。

## 只读审查结论

未发现本次自动合并引入的明确P1/P2：main新增notice `_lastRowKey` 只在无业务/分组/追加行的末notice挂载；与数据末行/summary不形成重复key。活notice slot仍由本轮生命周期修复保留，不因空业务行反复重造。常驻空态Scrollbar减少了父wrapper切换，不改变private slot数据前缀证明；footer/summary移位仍不计入共同前缀。RowWindow测量epoch、当前identity定位、Fenwick删除旧尾delta及估计/字体变化回退均保留。

## 35k Windows 完整读取交互

`windows-integration-merged-main-run1.log`：`00:55 +1: All tests passed!`。20次提交、5次取消，20个旧读取退休；本次实际17个晚回到达且未重新发布。最终35k、active=0、errors=0，中文旁路输入、勾选/列显隐、3次首尾往返及无滚动补读均通过。

回执：`windows-integration-merged-main-acceptance.json`。5个关键源/测试文件前后hash一致，LocalTest/loopback-only不变。

## 空表横向pointer专项

复用调用链：隐藏临时native入口 → `integration_test/shared_table_pointer_runtime_test.dart` → 原 `test/master_data_table_view_hscrollbar_test.dart` 与 `test/components/uten_editable_grid_hscrollbar_test.dart`。只在wrapper加SharedPreferences Mock及真实窗口前提设置，所有原断言不变。

保留执行证据：

1. run1入口位于项目根`.local-artifacts/integration_test`，被Flutter归为Widget Tests；虽15项通过但提示integration plugin未检测。**不计作native证据。** SDK按项目根`integration_test`路径前缀识别，故改用被忽略的`integration_test/.local-artifacts`入口。
2. run2真正Windows：runner默认逻辑800×540，原测试固定600高导致两项视口断言失败；另一项末行横拖仍为0。12过3失败；空态覆盖层/流内/空↔有数据横拖均已通过。
3. run3临时FFI wrapper回调类型与win32 5.15声明不符，编译失败；只修wrapper的Uint32签名。
4. run4只调整**当前测试PID**所属唯一可见HWND的真实client至800×600，Win32 client与FlutterView双校验；14过1失败。系统DPI和其他用户窗口未改。
5. run5原失败例定向诊断：native字体下数据自适应收窄，horizontal viewport=784、maxScrollExtent=0、pixels=0；目标cell在可见范围、touch允许。800宽没有横向溢出是正确行为，原例“应能向左拖动超过50”的前提在native字体下不成立。
6. run6真实client改为640×600，保持原600高/拖动量/全部断言，**15/15通过**。物理client1280×1200，当前PID核验。
7. run7只读诊断在原长表例中确认 `maxScrollExtent=80`、`viewportDimension=624`、拖动前pixels=0，原例与额外“实际overflow>50”检查均通过。未通过mock尺寸或放宽阈值凑结果。

最终回执：`windows-pointer-merged-main-acceptance.json`。最终wrapper源码副本及hash保留在根`.local-artifacts/merged_pointer_native_wrapper_640x600_final.dart`；原错误路由源码副本另存。`integration_test/.local-artifacts`实际测试入口已移除，避免影响项目分析；本工作树测试exe残留进程数为0。原产品/原pointer测试hash均一致。

本轮是合并后功能与原生pointer复核，不是性能基准、Win7验收或正式包发布。此前失败日志全部保留。
