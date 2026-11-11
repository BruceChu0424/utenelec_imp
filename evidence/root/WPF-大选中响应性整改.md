# WPF 大选中回执核对的后续响应性修正

这是实施期修复证据，不能替代下一份统一候选的最终重建。7b912287全新原驱动结果保留在 ../../wpf-export-final-7b912-native-export-1/result.json：两架构编译/原完整契约通过，但大选择窗口在1001之后50001超原Pump时限，两份large日志退出1，未覆盖或延长时限。

控制传输的真实UnitExportWindow会把2MB以上原选择与创建证明交给共同校验。ReadJob在SameSubmit之前额外调用一次SubmitObject，SameSubmit又验证左右两份对象，原请求中的大selectedIds被重复解析。快速已完成的传输也可能让这些纯校验和journal准备继续在dispatcher执行，异步方法名不能保证界面响应。

修正仅去掉外层重复验证，SameSubmit仍严格验证双方；单位导出窗口的原提交/原票据核对完整Core协议移到Task.Run，保持同一MutationRequest、owner、原ID、取消令牌与事后Current栅栏，不增加重发。普通业务写入、字节/文件/原票据预算不改。实际UI增加最大心跳间隙≤1000ms，原每步Pump10秒不改。

| 实施验证（原始log在logs/） | 结果 |
|---|---|
| wpf-responsive-contracts-1 / x64 | 大原选择、真实DPAPI中断、原GET、边界、两实际窗口全过；50001最大dispatcher间隙163ms，总动作12417ms（分阶段Pump10秒仍不变） |
| wpf-responsive-contracts-2-x86 | 同原组全过；50001最大间隙110ms，总动作10602ms |
| wpf-responsive-full-1-x64 / full-2-x86 | 两架构原完整本机契约退出0；不是Win7目标设备，也不是50001真数据库文件 |

诊断辅助NativeDiagnostic只调用原编译7b组件并保留first-chance错误，未改变产品或关闭断言；单独UI8项有一轮可过，不能据此抹去完整原驱动的超时。该辅助资源初始化/编译错误亦保留在本地native/wpf-diagnostic-1，未计入产品验证。

最终统一提交须重新运行tool/company_feedback_wpf_export/run.py的新run-tag，sourceHead/End必须准确，不能把以上dirty实施编译写成最终提交构建。真实50001行/额外未选项/权限/精确XLSX由Java真库单列。
