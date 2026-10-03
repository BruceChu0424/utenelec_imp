import 'package:flutter/widgets.dart';

String financeAssetEntryText(
  BuildContext context,
  String key, {
  String? period,
}) {
  final language = Localizations.maybeLocaleOf(context)?.languageCode ?? 'zh';
  final labels = switch (language) {
    'en' => _en,
    'ko' => _ko,
    _ => _zh,
  };
  return (labels[key] ?? _zh[key] ?? key).replaceAll('{period}', period ?? '');
}

const _zh = {
  'additionalDetails': '补充资料(选填)',
  'sourceDetails': '来源单据(提交前补齐)',
  'generatedCode': '编号保存后自动生成',
  'depreciationPending': '启折期间：待填写可使用日期(从次月开始，自动计算)',
  'depreciationPeriod': '启折期间：{period}(从次月开始，自动计算)',
  'amortizationPending': '摊销计划：待填写受益期',
  'amortizationPeriod': '摊销计划：自 {period} 起，按受益期和政策月份生成',
  'attachmentsAfterSave': '保存草稿后，可在详情补充原始凭证；提交前请补齐来源单据及行号。',
};

const _en = {
  'additionalDetails': 'Additional details (optional)',
  'sourceDetails': 'Sources (before submission)',
  'generatedCode': 'The number is generated after saving.',
  'depreciationPending':
      'Depreciation starts: enter the ready-for-use date (calculated from the following month).',
  'depreciationPeriod':
      'Depreciation starts: {period} (calculated from the following month).',
  'amortizationPending': 'Amortization plan: enter the benefit period.',
  'amortizationPeriod':
      'Amortization plan: from {period}, based on the benefit period and policy duration.',
  'attachmentsAfterSave':
      'After saving the draft, add original supporting files in the details. Complete the source document and line references before submission.',
};

const _ko = {
  'additionalDetails': '추가 정보(선택)',
  'sourceDetails': '원본 문서(제출 전 입력)',
  'generatedCode': '번호는 저장 후 자동 생성됩니다.',
  'depreciationPending': '감가상각 시작월: 사용 가능일 입력 대기(다음 달부터 자동 계산)',
  'depreciationPeriod': '감가상각 시작월: {period}(다음 달부터 자동 계산)',
  'amortizationPending': '상각 계획: 수혜 기간 입력 대기',
  'amortizationPeriod': '상각 계획: {period}부터 수혜 기간과 정책 개월 수에 따라 생성',
  'attachmentsAfterSave':
      '초안 저장 후 상세 화면에서 증빙 원본을 추가할 수 있습니다. 제출 전 원본 문서와 행 번호를 입력하세요.',
};
