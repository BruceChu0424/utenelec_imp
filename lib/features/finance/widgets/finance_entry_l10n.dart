import 'package:flutter/widgets.dart';

String financeEntryText(BuildContext context, String key) {
  final locale = Localizations.localeOf(context).languageCode;
  final labels = switch (locale) {
    'en' => _en,
    'ko' => _ko,
    _ => _zh,
  };
  return labels[key] ?? _en[key] ?? key;
}

const _zh = {
  'receiptCnyTotal': '合计金额(人民币)',
  'bankReferenceColumn': '银行流水号',
  'convertedCnyColumn': '折算人民币',
  'convertedCnyHint': '本次收款原币 × 顶部本批汇率，自动精确折算，仅供核对，不代替银行实际到账。',
  'availableOriginalColumn': '本次可收(原币)',
  'remainingOriginalColumn': '收款后未收(原币)',
  'batchBankReference': '本批银行流水号',
  'batchBankReferenceHint': '整张收款单共用一个银行流水号，修改任一行会同步其它行；不同到账批次请分别新建收款单。',
  'settlementDetails': '到账核对与费用',
  'recognize': '识别银行回单',
  'changed': '表单或账号已变化，请重新识别。',
  'currencyMismatch': '回单币种与所选账户不一致，请核对账户后重新识别。',
  'selectAccount': '请先选择真实收付款账户，再识别回单。',
  'applied': '已带入确认的银行信息，请核对明细后保存。',
  'wait': '请先完成或取消回单识别。',
  'failed': '回单识别失败，请稍后重试。',
};
const _en = {
  'receiptCnyTotal': 'Total amount (CNY)',
  'bankReferenceColumn': 'Bank reference',
  'convertedCnyColumn': 'Converted CNY',
  'convertedCnyHint':
      'Original receipt amount × the batch rate above. Calculated exactly for reference; this is not the actual bank deposit.',
  'availableOriginalColumn': 'Available (original)',
  'remainingOriginalColumn': 'Remaining (original)',
  'batchBankReference': 'Bank reference for this receipt',
  'batchBankReferenceHint':
      'One bank reference applies to the entire receipt. Editing any row updates all rows. Create separate receipts for different bank transactions.',
  'wait': 'Complete or cancel receipt recognition first.',
  'failed': 'Could not read the receipt. Please try again.',
  'settlementDetails': 'Bank reconciliation and fees',
  'recognize': 'Read bank receipt',
  'changed': 'The form or account has changed. Please read the file again.',
  'currencyMismatch':
      'The receipt currency does not match the selected account. Check the account and try again.',
  'selectAccount': 'Select the actual bank account before reading the receipt.',
  'applied':
      'Confirmed bank information filled in. Check the lines before saving.',
};
const _ko = {
  'receiptCnyTotal': '합계 금액(위안화)',
  'bankReferenceColumn': '은행 거래번호',
  'convertedCnyColumn': '위안화 환산액',
  'convertedCnyHint':
      '이번 수금 원통화 금액 × 상단의 이번 환율로 정확히 계산한 참고 금액이며 실제 은행 입금액을 대신하지 않습니다.',
  'availableOriginalColumn': '수금 가능액(원통화)',
  'remainingOriginalColumn': '수금 후 미수액(원통화)',
  'batchBankReference': '이번 수금의 은행 거래번호',
  'batchBankReferenceHint':
      '수금 전표 전체에 하나의 은행 거래번호를 사용합니다. 어느 행에서 수정해도 모든 행에 반영됩니다. 다른 입금 건은 별도 전표로 작성하세요.',
  'wait': '영수증 인식을 완료하거나 취소하세요.',
  'failed': '영수증을 읽지 못했습니다. 다시 시도해 주세요.',
  'settlementDetails': '입금 대사 및 수수료',
  'recognize': '은행 영수증 읽기',
  'changed': '양식 또는 계정이 변경되었습니다. 파일을 다시 읽어 주세요.',
  'currencyMismatch': '영수증 통화가 선택한 계좌와 다릅니다. 계좌를 확인한 후 다시 시도하세요.',
  'selectAccount': '영수증을 읽기 전에 실제 은행 계좌를 선택하세요.',
  'applied': '확인한 은행 정보를 입력했습니다. 명세를 확인한 후 저장하세요.',
};
