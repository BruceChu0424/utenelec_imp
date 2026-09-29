/**
 * 销售「识别客户文件」(ADR-134, SPEC §5): 报价单/订货单上传客户的报价单、形式发票或订单, 自动认出客户、表头信息与货品明细。
 *
 * <h2>组成</h2>
 * <ul>
 *   <li>{@link com.uten.imp.features.sales.intake.SalesDocumentIntakeJobHandler}: 公共 AI 任务框架的处理器(种类
 *       {@code SALES_DOCUMENT_INTAKE}), 负责权限、输入校验与按价格权限过滤结果;</li>
 *   <li>{@code SalesIntakePipeline}: 流水线 读取 → 版式 → 抽取 → 不看客户匹配货品 → 找客户 → 按客户重打分 → 定价;</li>
 *   <li>{@code IntakeLayoutDetector} / {@code IntakeLineExtractor} / {@code IntakeHeaderRules}: 固定规则(先规则, AI 只补规则做不到的);</li>
 *   <li>{@code GoodsCandidateRetriever} + {@code GoodsMatcher}: 候选召回与加法证据打分(移植参考实现 sim2);</li>
 *   <li>{@code ClientMatcher}: 客户线索与「篮子重合度」;</li>
 *   <li>{@code IntakePricing}: 按文件单价反推折扣(舍入只经 MoneyPolicy), <b>从不改价</b>;</li>
 *   <li>{@code IntakePrompts} / {@code IntakeAi}: 提示词(纯函数)与调用封装; 客户内容一律作为不可信文本;</li>
 *   <li>{@code SalesIntakeStore} + {@code SalesIntakeLayoutLearner}: 本模块自有表 sales_intake_layouts 的读写,
 *       单据保存提交后按服务端识别结果学习版式。</li>
 * </ul>
 *
 * <h2>约定</h2>
 * <ul>
 *   <li>读主档只经 {@link com.uten.imp.application.port.MasterIntakeLookupPort}(提交人的数据范围, 销售只看得到自己的客户);
 *       调 AI 只经任务上下文(计入次数、检查 ai:use); 流水线没有数据库事务, 从不在事务里调用 AI;</li>
 *   <li>没有 ai:use 或 AI 不可用时只走规则(常见格式的 Excel 仍能识别), PDF/图片需要 AI, 图片/扫描件还需要支持图片的模型;</li>
 *   <li>发给 AI 前最小化: 银行信息块(关键字行及紧跟的银行名称/地址/账号行)与抬头区的我司信息去掉, 货品描述里的我司名称、
 *       邮箱/电话/税号换成占位符(服务端换回), 表头模式从不发送单价金额; AI 抽出的行要能在原文里找到、数字在合理范围内;</li>
 *   <li>自动对应(MATCHED)只在证据确切且没有冲突时给出; 文件有单价却算不出折扣、或只凭推测(未确认)客户的历史才对得上的行,
 *       一律待核对, 由销售在识别面板里选;</li>
 *   <li>结果结构见 SPEC §5.9({@code schemaVersion = 2}); 行键 {@code S<工作表序号>R<行号>} 在同一任务内稳定, 保存时作为
 *       intakeLineKey 回传, 主档学习按它对行(学习只信服务端保存的结果, 不信请求体)。</li>
 * </ul>
 */
package com.uten.imp.features.sales.intake;
