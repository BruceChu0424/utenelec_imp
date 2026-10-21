-- V897：权限名称与当前业务动作一致，并把管理员需要理解的说明改为日常用语。
-- V896 已将 name/description 归为展示字段；本迁移只修改这两个字段。
-- 不改权限 code/id、动作分类、授权策略、基础包、默认授权、对象范围或任何既有授权。
-- 特别保留：报价取消不是单据反审；会计撤销仍保留原记录与对应的反向记录。
CREATE TEMP TABLE v897_permission_language (
    code text PRIMARY KEY,
    name text NOT NULL,
    description text NOT NULL
) ON COMMIT DROP;

INSERT INTO v897_permission_language(code,name,description) VALUES
    ('stock_doc:reverse','反审仓库单据','撤销仓库单据的审核结果；仍须满足库存、后续单据和车间内料仓的限制，保留原单及反向记录'),
    ('subcontract_material_issue:reverse','反审委外材料出仓单','撤销委外材料出仓单的审核结果；按原出仓记录恢复对应数量，仍受后续回厂及退料记录限制'),
    ('subcontract_waste:reverse','反审委外材料损耗单','撤销委外材料损耗单的审核结果，按原记录恢复数量并保留处理历史'),
    ('subcontract_material_return:reverse','反审委外材料退货单','撤销委外材料退货单的审核结果，按原记录恢复对应数量；仍受后续单据限制'),
    ('subcontract_order:reverse','反审委外订货单','撤销已完成财务审核的委外订货单；已领料、回厂或结算等后续记录仍须先按业务规则处理'),
    ('subcontract_inquiry:reverse','反审委外询价单','撤销委外询价单的审核结果，保留原询价及处理历史'),
    ('subcontract_receipt:reverse','反审委外进仓单','撤销委外进仓单的审核结果；库存、来料检验、材料耗用和应付记录仍须通过业务校验'),
    ('subcontract_return:reverse','反审委外退货单','撤销委外退货单的审核结果，按原记录恢复对应数量和账务；仍受后续处理限制'),
    ('production_daily_report:reverse','反审生产日报','撤销生产日报的审核结果；保留报工及反向记录，仍受成品入库、车间直送和用料结算限制'),
    ('production_plan:reverse','反审生产计划','撤销生产计划的审核结果；仍须先处理不能安全撤回的派工、报工和下游单据'),
    ('finance_expense:reverse','反审一般费用单','撤销一般费用单的审核结果并恢复对应账户和账务影响；保留原单与反向记录'),
    ('finance_other_income:reverse','反审其他收入单','撤销其他收入单的审核结果并恢复对应账户和账务影响；保留原单与反向记录'),
    ('finance_payment:reverse','反审采购付款单','撤销采购付款单的审核结果并恢复对应付款和应付记录；保留原单与反向记录'),
    ('finance_bank_transfer:reverse','反审银行存取单','撤销银行存取单的审核结果并恢复对应账户流水；保留原单与反向记录'),
    ('finance_receipt:reverse','反审销售收款单','撤销销售收款单的审核结果并恢复对应收款和应收记录；保留原单与反向记录'),
    ('purchase_receipt:reverse','反审采购收货单','撤销采购收货单的审核结果；库存、来料检验和应付记录仍须通过业务校验'),
    ('purchase_order:reverse','反审采购订货单','撤销已完成财务审核的采购订货单；已收货、付款或结算等后续记录仍须先按业务规则处理'),
    ('purchase_return:reverse','反审采购退货单','撤销采购退货单的审核结果，按原记录恢复对应数量和账务；仍受后续处理限制'),
    ('sales_other_shipment:reverse','反审历史其他出货单','用于历史其他出货单的反审校验；当前客户零星发货仍走财务审核和仓库交接流程，不因本权限而允许已出库货物直接回库'),
    ('sales_shipment:reverse','反审销售出货单','仅在业务校验允许且能够确认货物尚未出库时撤销原审核；已出库货物须走销售退货与收货检验流程'),
    ('sales_quote:reverse','取消销售报价单','取消尚未转成订货单的报价，须填写原因并保留报价与沟通历史；编辑报价权限也包含取消，本项用于单独授予取消能力'),
    ('sales_order:reverse','反审销售订货单','撤销销售订货单的审核结果并按业务规则释放相关占用；仍须先处理已发货、已排产等后续记录'),
    ('sales_return:reverse','反审销售退货单','撤销销售退货单的审核结果，按原记录恢复对应数量和账务；仍受检验、处置和后续单据限制'),
    ('purchase_order:cancel','取消采购订货单','采购员取消本人草稿或已提交财务审核的订货单；已完成审核的订货单须使用反审并通过后续业务校验'),
    ('warehouse_iqc_stock_in:view','查看来料检验合格待入库任务','查看采购或委外来料已检验合格、等待仓库确认入库的实物任务；不包含单价、金额或成本'),
    ('warehouse_iqc_stock_in:confirm','确认来料检验合格品入库','确认检验合格货物的实际仓库和库位，并登记可用库存；品质检验合格本身不等于仓库已收货'),
    ('warehouse_iqc_return:view','查看来料检验不合格退回任务','查看采购和委外来料中检验不合格货物的退回任务及凭证；不包含金额、退款折让或财务结案操作'),
    ('production_fqc_replenishment:view','查看成品质检补产物料待办','查看成品质检报废或退回后需要补产的组装用料、缺料、领料及放行情况'),
    ('production_fqc_replenishment:confirm','确认成品质检补产用料方案','确认本次补产使用的组装明细，生成所需材料、库存占用和领料单'),
    ('production_quality_inspection:view','查看生产成品待检任务','查看本人可处理或有权查阅的生产成品检验任务及历史检验结果'),
    ('production_quality_inspection:approve','登记生产成品质检结果','逐条登记生产成品合格、部分合格或不合格的结果；仍须具备该检验任务的处理资格'),
    ('procurement_iqc_rejection:view','查看来料不合格处理任务','查看本人有权负责的采购和委外来料不合格任务、退回情况及后续处理进度'),
    ('procurement_iqc_rejection:view:all','查看全部来料不合格处理任务','跨负责人查看全部采购和委外来料不合格处理任务；金额查看和处理操作仍须单独授权'),
    ('procurement_iqc_rejection:amount:view','查看来料不合格金额','查看不合格货物的原币、本币金额及供应商应退或应减金额'),
    ('procurement_iqc_rejection:record_return','登记不合格来料实物退回','从退回任务中登记检验不合格货物的实际退回数量和凭证；不代表已确认财务退款或折让'),
    ('procurement_iqc_rejection:confirm_credit','确认不合格来料的供应商应退金额','财务确认供应商应退或应减的金额，登记对应应付减少及允许的抵扣；不代替实物退回登记'),
    ('procurement_iqc_rejection:close_no_credit','确认零金额不合格任务并结案','财务确认该不合格任务金额为零、无需供应商退款或折让后结案'),
    ('procurement_iqc_rejection:reverse','撤销来料不合格处理结果','在会计期间和后续业务允许时，撤销原供应商应退金额、零金额结案或实物退回记录，并保留处理历史'),
    ('employee:compensation:view','查看员工薪酬资料','查看员工工资、社保、公积金和补贴等薪酬资料；编辑薪酬须另行授权'),
    ('employee:pii:view','查看员工证件和银行资料','查看员工证件和银行等受保护的个人资料；修改资料须另行授权'),
    ('employee:pii:edit','编辑员工证件、联系方式和银行资料','填写或修改员工证件、联系方式和银行资料；不包含工资、社保、公积金和补贴的修改权限'),
    ('employee:compensation:edit','编辑员工工资、社保公积金和补贴','填写或修改员工工资、社保、公积金和补贴；入职和修改已有员工仍须具备对应员工操作权限'),
    ('pii_key_rotation:manage','更换员工隐私资料加密密钥','仅超级管理员在本地明确启用并重新验证身份后，分批更新员工隐私资料的加密方式；旧密钥不能直接删除'),
    ('attachment:reconcile:view','查看未关联业务的附件','查看没有对应业务记录或关联异常的附件检查结果；不包含附件清理权限'),
    ('attachment:reconcile:approve_delete','批准清理未关联业务的附件','批准清理已经检查并确认不再关联有效业务的附件；保留清理审核记录'),
    ('finance_post:execute','确认总账入账','将符合条件的业务记录正式记入总账；仍受单据状态、会计期间和重复入账校验限制'),
    ('finance_asset:view','查看固定资产和长期待摊明细','查看固定资产、长期待摊费用、折旧摊销及相关入账明细'),
    ('finance_asset:edit','新增、编辑、提交和调拨资产与待摊','新增或修改资产与长期待摊草稿、提交审核和办理资产调拨；删除草稿、审核、启用、计提入账及处置均使用独立权限'),
    ('finance_asset:approve','审核资产、待摊、类别和计提批次','审核固定资产、长期待摊、相关类别和折旧摊销计提批次；不包含直接启用或正式入账'),
    ('finance_asset:post','启用资产并计提入账','启用已审核的资产或长期待摊，预览并提交折旧摊销计提并正式入账；撤销入账使用独立权限'),
    ('finance_asset:dispose','申请和审核资产处置或待摊终止','发起、退回或审核固定资产处置及长期待摊终止；批准还须具备「启用资产并计提入账」权限，审核人不能是申请人，仍受会计期间及后续账务限制'),
    ('finance_asset_period:manage','关闭或重新打开资产记账月份','关闭资产与长期待摊的记账月份，或按受控流程重新打开以便更正；须填写原因并保留记录'),
    ('supplier_settlement:reverse','撤销供应商月结对账批次','撤销错误的月结对账批次并保留原对账及操作历史；不改写来源应付记录'),
    ('supplier_open_item_offset:apply','用供应商应退金额抵应付','把已确认的采购退货或索赔应退金额逐笔抵扣同供应商、同币种及原记账汇率一致的应付；不包含使用供应商预付款'),
    ('supplier_open_item_offset:reverse','撤销供应商应退金额抵扣','按原抵扣批次恢复供应商应退金额和应付余额，并保留原抵扣及撤销记录'),
    ('subcontract_loss_claim:fulfill','登记委外超耗补偿结果','登记委外商通过现金、补料、补货、重作或退回废料完成补偿的数量、金额及凭证'),
    ('subcontract_loss_claim:reverse','撤销委外超耗责任决定','在后续业务允许时撤销原责任决定，并追加更正记录；不删除原决定及处理历史'),
    ('customer_prepayment:apply','用客户预收款抵应收','把客户已收预收款逐笔抵扣同客户、同币种销售单的正式应收'),
    ('customer_prepayment:reverse','撤销客户预收款抵扣','按原抵扣批次从最近一笔开始撤销客户预收款抵应收，并恢复对应余额、保留历史记录'),
    ('production_execution:assign','调整生产任务分工和日期','调整生产任务的车间、班组、负责人和计划日期；不代替正式下达或开工确认'),
    ('production_execution:release_defer','解除生产任务暂缓','解除人工设置的暂缓，并重新检查所需材料是否齐全'),
    ('production_execution:dispatch','派工生产任务','把材料已齐备的生产任务正式派给对应车间或班组'),
    ('production_material:settle','登记生产实际用料','登记生产实际耗用、允许损耗和仍在生产中占用的材料数量'),
    ('production_material:reverse','撤销生产用料登记','按原用料记录撤销登记错误的数量，并保留原登记及撤销历史'),
    ('production_material:close','关闭已核清用料的生产任务','在成品数量与材料用量全部核清后关闭生产任务'),
    ('production_planning_package:generate','正式下达生产任务和配套单据','一次生成执行任务、材料占用和适用的采购、委外等配套单据；全部成功后才生效'),
    ('production_planning_package:cancel','取消生产任务下达','取消仍可安全撤回的一次生产任务下达，同时按业务规则处理关联任务和配套单据'),
    ('production_planning_package:reverse','撤销生产任务下达及可退回的后续记录','按原下达记录撤销生产任务及允许退回的后续记录；已有实物、报工或结算等事实时仍须先通过业务校验'),
    ('sales_order:reallocate','调整紧缺库存的订单分配','库存不足时调整订单之间的库存优先分配；仍受订单、已发货和已占用库存的业务限制'),
    ('purchase_order:decompose','从采购申请生成采购订货单','按采购申请选择供应商并拆分生成采购订货草稿；不修改原采购申请'),
    ('subcontract_order:decompose','从委外申请生成委外订货单','按委外申请选择委外商并拆分生成委外订货草稿；不修改原委外申请'),
    ('account:balance:adjust','核对并调整账户余额','按核对后的目标余额登记调整流水；检查当前余额防止重复调整，并保留完整记录'),
    ('sales_other_shipment:view','查看客户零星发货及历史其他出货','查看客户零星发货和有权查阅的历史其他出货；商业金额仍须具备对应价格权限'),
    ('sales_shipment:approve','销售确认订单出货内容','确认本次订单出货的货品和数量并提交财务审核；不代替财务放行，也不直接扣减库存'),
    ('sales_shipment:reject','退回待出库的销售出货单','因备货异常退回尚未出库的销售出货单，并按原记录释放对应订单占用；财务已放行时须先反审'),
    ('sales_quote:edit','编辑、提交或取消销售报价','编辑报价草稿、提交或撤回核价、确认客户接受、取消报价或按业务规则重新打开报价；财务核价须另行授权'),
    ('sales_quote:convert','将销售报价转为销售订货','从财务已确认且客户已接受的有效报价生成销售订货草稿；仍须具备新增销售订货权限'),
    ('purchase_report:price:view','查看采购报表的单价和金额','在采购明细、汇总和催料报表中查看单价与金额；不扩大可查看的单据范围'),
    ('subcontract_report:price:view','查看委外报表的单价和金额','在委外明细、汇总和出入状况报表中查看单价与金额；不扩大可查看的单据范围'),
    ('sales_return_quality:view','查看销售退货待检与处理记录','查看销售退货待检货物、检验结果和暂不可用数量的处理记录'),
    ('sales_return_quality:dispose','确认销售退货质检处理结果','确认销售退货检验后的货物处理方式；仍须满足退货、库存和后续单据限制');

DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM v897_permission_language language
               LEFT JOIN permissions permission ON permission.code=language.code
               WHERE permission.id IS NULL) THEN
        RAISE EXCEPTION 'V897 permission language patch refers to an unknown permission';
    END IF;
END $$;

UPDATE permissions permission
SET name=language.name, description=language.description
FROM v897_permission_language language
WHERE permission.code=language.code;

DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM permissions WHERE name LIKE '%红冲%' OR description LIKE '%红冲%') THEN
        RAISE EXCEPTION 'V897 current permission catalog must use the current business action names';
    END IF;
    IF EXISTS (SELECT name FROM permissions GROUP BY name HAVING count(*)>1) THEN
        RAISE EXCEPTION 'V897 permission display names must remain distinguishable';
    END IF;
END $$;
