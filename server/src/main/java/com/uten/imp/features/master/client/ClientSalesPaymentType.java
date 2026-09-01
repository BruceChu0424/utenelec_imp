package com.uten.imp.features.master.client;

/**
 * 客户销售货款分类标签。
 *
 * <p>该标签只帮助销售、财务识别人工审核场景，不代表款项已经到账，
 * 也不能绕过出货财务审核。定金到账仍以 CUSTOMER_PREPAYMENT 资金事实为准。
 */
public enum ClientSalesPaymentType {
    MONTHLY,
    CASH,
    DEPOSIT
}
