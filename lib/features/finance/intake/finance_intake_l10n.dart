import 'package:flutter/widgets.dart';

String financeIntakeText(BuildContext context, String key) {
  final language = Localizations.localeOf(context).languageCode;
  final values = _texts[key];
  if (values == null) return key;
  return values[language == 'en'
      ? 1
      : language == 'ko'
      ? 2
      : 0];
}

String financeIntakeWarning(BuildContext context, String message) {
  if (Localizations.localeOf(context).languageCode == 'zh') return message;
  final key =
      _warningKeys[message] ??
      (message.endsWith('格式不明确，未带入，请按原件填写')
          ? 'invalidFields'
          : message.endsWith('有多个不同值，未带入，请按原件填写')
          ? 'conflictingFields'
          : 'unrecognized');
  return financeIntakeText(context, key);
}

const _texts = <String, List<String>>{
  'unsupportedType': [
    '当前仅支持新建收款单和付款单识别银行回单',
    'Bank documents can fill new receipts and payments only.',
    '은행 자료는 신규 수금 및 지급 전표에만 사용할 수 있습니다.',
  ],
  'unsupportedFile': [
    '请上传 Excel、CSV 或文字 PDF，图片和扫描件请手工核对',
    'Upload Excel, CSV or a text PDF. Check images and scans manually.',
    'Excel, CSV 또는 텍스트 PDF를 올려 주세요. 이미지와 스캔은 직접 확인해 주세요.',
  ],
  'size': [
    '请上传不超过 15 MB 的完整银行回单',
    'Upload a complete bank document up to 15 MB.',
    '15 MB 이하의 완전한 은행 자료를 올려 주세요.',
  ],
  'title': ['识别银行回单', 'Read bank document', '은행 자료 읽기'],
  'subtitle': [
    '在业务服务器本地读取，请核对原件后选择要带入的字段',
    'Read locally on the business server. Check the original and select fields to use.',
    '업무 서버에서 로컬로 읽습니다. 원본을 확인하고 입력할 항목을 선택하세요.',
  ],
  'upload': ['上传文件', 'Upload file', '파일 업로드'],
  'read': ['读取回单', 'Read document', '자료 읽기'],
  'check': ['检查金额与来源', 'Check amounts and source', '금액 및 출처 확인'],
  'expired': [
    '识别任务已失效，请重新识别',
    'This result has expired. Read the file again.',
    '읽기 결과가 만료되었습니다. 파일을 다시 읽어 주세요.',
  ],
  'sourceMismatch': [
    '识别结果与当前文件不一致，请重新识别',
    'The result does not match this file. Read it again.',
    '결과가 현재 파일과 다릅니다. 다시 읽어 주세요.',
  ],
  'changed': [
    '识别结果已变化，请重新核对',
    'The result has changed. Review it again.',
    '읽기 결과가 변경되었습니다. 다시 확인해 주세요.',
  ],
  'reviewTitle': ['核对银行回单', 'Review bank document', '은행 자료 확인'],
  'reviewHint': [
    '对照原件勾选要带入的字段；客户、供应商、账户和核销明细仍需在单据中选择。',
    'Select fields after checking the original. Choose the customer, supplier, account and settlement lines in the form.',
    '원본을 확인한 후 입력할 항목을 선택하세요. 고객, 공급업체, 계좌 및 정산 내역은 전표에서 선택해야 합니다.',
  ],
  'dateHint': [
    '交易日期只作参考，不改业务日期或具体入账时刻。',
    'The bank date is a reference only. It will not change the business date or booking time.',
    '은행 거래일은 참고용입니다. 업무 일자와 입금 시각은 변경하지 않습니다.',
  ],
  'currencyHint': [
    '回单币种不明确，金额只展示，请核对后在单据中手工填写。',
    'The currency is unclear. Check the amount and enter it manually.',
    '통화가 불명확합니다. 금액을 확인한 후 직접 입력하세요.',
  ],
  'receiptFeeHint': [
    '手续费只作参考，请在单据中核对费用币种、付款账户及扣费方式后填写。',
    'Fees are a reference only. Check the fee currency, paying account and deduction method before entering them.',
    '수수료는 참고용입니다. 수수료 통화, 지급 계좌 및 차감 방식을 확인한 후 입력하세요.',
  ],
  'bankReference': ['银行流水号', 'Bank reference', '은행 거래번호'],
  'transactionDate': ['交易日期', 'Bank transaction date', '은행 거래일'],
  'receiptAmount': ['账户实收金额', 'Amount received in account', '계좌 실수령액'],
  'paymentAmount': ['账户实付金额', 'Amount paid from account', '계좌 실제 지급액'],
  'currencyCode': ['回单币种', 'Document currency', '은행 자료 통화'],
  'bankFee': ['银行手续费', 'Bank fee', '은행 수수료'],
  'sourceHint': ['请对照原文件核对', 'Check the original file', '원본 파일을 확인하세요'],
  'current': ['当前值', 'Current value', '현재 값'],
  'suggestion': ['文件建议', 'File suggestion', '파일 제안'],
  'cancel': ['取消', 'Cancel', '취소'],
  'apply': ['带入 {count} 项', 'Use {count} fields', '{count}개 항목 입력'],
  'singleSheet': [
    '请每次上传一张只含一笔交易的工作表，多工作表文件请拆分后识别',
    'Upload one worksheet containing one transaction. Split multi-sheet files.',
    '거래 한 건이 담긴 워크시트 하나를 올려 주세요. 여러 시트는 나누어 주세요.',
  ],
  'incomplete': [
    '文件有隐藏行或内容未完整读取，请导出只有这笔交易的完整表格',
    'Hidden rows or incomplete content were found. Export a complete table for this transaction.',
    '숨겨진 행 또는 불완전한 내용이 있습니다. 해당 거래의 전체 표를 내보내 주세요.',
  ],
  'mixed': [
    '文件包含其他业务资料，请上传单独的银行回单',
    'The file includes other business documents. Upload the bank document separately.',
    '다른 업무 자료가 포함되어 있습니다. 은행 자료만 별도로 올려 주세요.',
  ],
  'singleRow': [
    '请只保留一笔银行交易及其表头后再识别',
    'Keep one bank transaction and its headers before reading.',
    '은행 거래 한 건과 표 머리글만 남긴 후 다시 읽어 주세요.',
  ],
  'multipleRows': [
    '文件含多笔交易或表尾内容，请拆分为单笔回单后识别',
    'Multiple transactions or footer content were found. Split the file into individual documents.',
    '여러 거래 또는 표 하단 내용이 있습니다. 거래별 자료로 나누어 주세요.',
  ],
  'unmatched': [
    '字段旁有无法对应的内容，请核对原件后手工填写',
    'Content beside a field is ambiguous. Check the original and enter it manually.',
    '항목 옆 내용을 대응할 수 없습니다. 원본 확인 후 직접 입력하세요.',
  ],
  'scan': [
    '这是扫描 PDF，当前银行回单识别只支持文字 PDF、Excel 或 CSV，请手工核对或重新导出',
    'Scanned PDFs are not supported here. Use a text PDF, Excel or CSV, or enter the values manually.',
    '스캔 PDF는 지원하지 않습니다. 텍스트 PDF, Excel, CSV를 사용하거나 직접 입력하세요.',
  ],
  'singlePage': [
    '请上传单页、单笔银行回单，不能把多页内容合成一笔金额',
    'Upload one page containing one transaction. Multiple pages cannot be combined into one amount.',
    '거래 한 건이 담긴 단일 페이지를 올려 주세요. 여러 페이지를 한 금액으로 합칠 수 없습니다.',
  ],
  'direction': [
    '文件出现与当前收付款方向不一致的金额，请核对用途后手工填写',
    'The document has an amount in the opposite direction. Check its purpose and enter it manually.',
    '현재 수금 또는 지급 방향과 다른 금액이 있습니다. 용도를 확인하고 직접 입력하세요.',
  ],
  'duplicates': [
    '文件出现多笔交易或重复金额、流水号，请拆分为单笔回单后识别',
    'Repeated amounts or references may indicate multiple transactions. Upload one transaction at a time.',
    '반복된 금액이나 거래번호는 여러 거래일 수 있습니다. 한 건씩 올려 주세요.',
  ],
  'gross': [
    '文件中的交易金额不能证明账户实际收支，未用它推算到账金额或手续费',
    'The transaction amount does not establish actual account movement. No net amount or fee was inferred.',
    '거래금액만으로 실제 계좌 입출금을 확인할 수 없습니다. 실수령액이나 수수료를 추정하지 않았습니다.',
  ],
  'missingReceipt': [
    '未找到明确的账户实收金额，请手工核对',
    'No explicit account receipt amount was found. Check it manually.',
    '명확한 계좌 실수령액이 없습니다. 직접 확인하세요.',
  ],
  'missingPayment': [
    '未找到明确的账户实付金额，请手工核对',
    'No explicit account payment amount was found. Check it manually.',
    '명확한 계좌 실제 지급액이 없습니다. 직접 확인하세요.',
  ],
  'unrecognized': [
    '没有可确认带入的字段，可继续按原件手工录入',
    'No fields can be confirmed for filling. Continue manually using the original.',
    '확인하여 입력할 항목이 없습니다. 원본을 보고 직접 입력하세요.',
  ],
  'invalidFields': [
    '字段格式不明确，未带入，请按原件填写',
    'Some field formats are unclear and were omitted. Refer to the original.',
    '형식이 불명확한 항목은 제외했습니다. 원본을 확인하세요.',
  ],
  'conflictingFields': [
    '字段有多个不同值，未带入，请按原件填写',
    'Conflicting field values were omitted. Refer to the original.',
    '서로 다른 값이 있는 항목은 제외했습니다. 원본을 확인하세요.',
  ],
  'separateFee': [
    '文件提到手续费不含在金额内或另扣，无法确认账户实际总扣款，请手工核对',
    'The document excludes fees or charges them separately. The total account debit is unclear; check it manually.',
    '수수료 제외 또는 별도 청구가 표시되어 있습니다. 계좌 총 출금액을 직접 확인하세요.',
  ],
  'amountCurrency': [
    '无法确认账户金额的币种，金额未带入，请核对原件后填写',
    'The currency of the account amount is unclear. The amount was omitted; check the original.',
    '계좌 금액의 통화를 확인할 수 없어 금액을 제외했습니다. 원본을 확인하세요.',
  ],
};

final _warningKeys = <String, String>{
  for (final key in [
    'singleSheet',
    'incomplete',
    'mixed',
    'singleRow',
    'multipleRows',
    'unmatched',
    'scan',
    'singlePage',
    'direction',
    'duplicates',
    'gross',
    'missingReceipt',
    'missingPayment',
    'unrecognized',
    'separateFee',
    'amountCurrency',
  ])
    _texts[key]![0]: key,
};
