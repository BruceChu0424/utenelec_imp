# 科目用途等待整改与指针独立诊断

产品 `83712ff8a412d325039bc99fbf05d0dbdad06fa1`（Root已纳4664a939e），只改PostingStyleRolePanel及回归；Dropdown、blur/current/owner保护、A布局宿主与MTDT未改。

原保存/刷新等待卡=0、回包丢失后仍可继续写入三项已真实跑红。现在共用一个绑定实际await状态的UtenBusyOverlay，防连点、保存中防pop，成功/失败/卸载/owner变化撤下等待，保留选择与未知结果。未知回包使用共享isDefiniteRejection分类，先刷新权威状态再允许下一写。原服务端权限/CAS不变。

最终11/11测试通过，3文件分析0 issue：原Panel行为、单卡/单语义播报、重复点击、未知结果读回、卸载后迟到结果、完整UtenApp/MainShell/520 drawer的3/5项真实mouse与平台TextInputAction.done控制。WidgetTester平台提交不冒称真实IAB Return。

真实Web pointer仅关闭不回填仍未关闭。VM与headless Chrome新鲜完整App mouse3/5均成功、roles读2次/写0，仅作阴性控制，不能替代真实Web。没有为凑通过修改Dropdown保护。

早期fixture缺confirmed SessionSnapshot；全App settle又被底层UtenAppBarActionProgress等待drawer Future的持续动画阻挡。原失败保留，最终改等具体面板/选项及呈现完成。旧键盘单Tab/硬键Enter没有正确模拟目标焦点/平台done的driver红亦保留，不称键盘产品缺陷。

独立只读审查：合法_select同步close→onChanged，无await；current false本身不主动close。必须通过外部close首caller和原生focus事件归因，不能削弱权限或blur。

纯合成Dart2js诊断页已交Root独占浏览器：`http://127.0.0.1:28636/#/basicinfo/payment-style`。真实生产binding/App/MainShell/Panel；深色1280×900、drawer520、菜单约480、长合成标签两行；账户5项带搜索/负债3项无搜索。无业务HTTP后端（api返回404 synthetic-only），保存只改RAM，F5恢复样例。未接Root账号/DB。

诊断副本记录Dropdown首关闭caller、ViewFocus/AppLifecycle/availability、DOM pointer目标tag/role/document focus/activeTag，未读label/input/token。临时instrumentation仅在独立诊断树，不在产品。Root需对照立即native click与选项自身Tooltip明确可见后native click、Keyboard/Return；截图和最新运行日志一起判定。

诊断构建187s exit0、SDK未改；host analyzer报legacy dart:js_util URI、Wasm dry-run不支持原样保留，不冒analyze0/Wasm或正式包通过。Node仅127.0.0.1:28636静态目录，PID33980/tool session12428；C未操作浏览器。后台Start-Process命令曾被自动审批拒绝（blocked by policy），改为明确只读Node工具会话成功。诊断不替最终同SHA真实Web验收。

未改main、推送、部署、正式打包或Root七用途配置；Win7 WPF未迁移的该财务入口仍未迁移。C最终验收runner保持文件保全检查点，未获freeze、未执行Maven/Java/PG。

收口时新增真实证据：Root在纯合成Native页也复现pointer失败，原UI下载日志已复制为native/native-pointer-original.log（23667 bytes，SHA256 11e47b4b4ca9c4a1a5785279a7df3e89610471cdaecf8142e2f2f58c09cf40e8）。13:11:30.738 view0 unfocused→availability view=false（owner/routes/ticker=true、app=resumed）→lifecycle首关；document有焦点且未隐藏，43ms后pointerdown才落到底下field，未到select-guard。近因已证，但BODY/null间隙的真正DOM归属仍需target/relatedTarget/connected/closest view及原生调用栈核实，不能仅凭document.hasFocus忽略失焦。

用户收口后未继续写focus修复、ownership新探针、build或验收。只停止自己Node：核对node命令及28636归属PID33980后停止，PID及端口均已不存在。Root浏览器未由C操作；Tab4由Root收口。诊断源码/产物仍保留，未完成项见HANDOFF.md。
