# 新增修复的限定独立复核

只读审查Root `e6fd716164e2c8f56f558cc683fa153e5a4f4391`，本页不签署最终验收，不把他人执行结果写成本轮独立运行。相关源码精确blob指纹见scope-review-e6fd-sources.json。原Tooltip反例仍红，由A负责修复；尚需新统一候选真实Web/Windows与合并main后的复核。

| 范围 | 已核对的具体不变量 | 本轮结论 |
|---|---|---|
| WPF ReadJob重复验证移除 | SameSubmit内部仍先SubmitObject(left/right)，严格比较jobId、原filter字符串、selectedIds字符串与列projection；ReadMetadata仍校验报告、格式、ID和有限状态。仅移除外部同一次SubmitObject重复调用。 | 未发现新增回执校验绕过。 |
| WPF大选择协议移出dispatcher | Task.Run捕获同一不可变request/owner/取消令牌；Core仍校验注册对象引用、只尝试一次、权限/owner、durable Sending及dispatch前permit；已派发失败仍Unknown。窗口owner变化通过Dispatcher退休，busy关闭延后，返回后Current栅栏仍在。 | 未发现新跨owner发布或自动重发路径。取消前尚未启动的后台工作不会绕过Core发送写入；不能据此把旧未知结果改成未写。 |
| 输出预算 | 新响应permit限固定单job GET或真正owns的单位输出mutation；普通读取/写入和最近50条metadata预算仍独立。 | 未发现扩大普通业务写入或以recent元数据证明创建的改动。 |
| 仓库分解查询 | 原LATERAL按同一(w,g,c)物理reservation集合求和，原查询本就不按unit拆分reservation；新ownQuantities仍保留全部tracked/beneficiary active/owner CASE，预筛域正是原维度/仓集合，再按原键left join。vStock新增goodsIds谓词已由原dimensions条件蕴含。 | 静态关系等价成立，未发现额外输出范围或精度合并；运行证据需引用实际51-scope/42例原SHA，不冒称本审查重跑。 |
| 导入安全版本3与回执顺序 | 五类服务从数据库保留预览读取版本，不信客户端版本字段；note/chart/aux/accounting已完成回执先返回，owner过滤/身份约束仍先执行。旧pending的版本验证仍处于新业务写入之前。成本apply先核身份/货品scope，再检查保留预览版本，不伪造历史版本。 | 未发现新版本客户端绕过或本次修改导致旧回执跨owner泄露；不把成本重新匹配计算接口说成其不存在的幂等成功回执。 |

这些结论是指定文件的源码复核，既不是全安全审计，也不是正式CI、公司原单、Win7真机或完整UI通过。最终候选仍须按真实执行SHA与输入/编译来源核对。
