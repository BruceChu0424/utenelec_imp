import 'package:flutter/widgets.dart';

import '../../../core/l10n/gen/app_localizations.dart';
import '../../../core/l10n/gen/app_localizations_zh.dart';

final _fallback = AppLocalizationsZh();

/// 识别客户文件相关界面文案: 跟随应用语言; 没挂本地化代理的独立预览/测试回落中文
/// (与 workflowFieldText 同口径, 避免销售编辑页在未配置语言的宿主里崩溃)。
AppLocalizations salesIntakeL10n(BuildContext context) =>
    Localizations.of<AppLocalizations>(context, AppLocalizations) ?? _fallback;

String salesIntakeExtraText(BuildContext context, String key) {
  final language = Localizations.maybeLocaleOf(context)?.languageCode ?? 'zh';
  const text = {
    'title': ['文件中的额外信息', 'Additional file columns', '파일의 추가 정보'],
    'hint': [
      '勾选后添加到明细表，作为参考信息。费用如何计入金额，请在表格中选择计算方式。',
      'Selected columns are added as reference information. Choose a calculation in the table to include a fee in the amount.',
      '선택한 열을 참고 정보로 추가합니다. 비용을 금액에 반영하려면 표에서 계산 방식을 선택하세요.',
    ],
    'failed': [
      '额外列添加失败，请重试。现有明细尚未替换。',
      'Could not add the additional columns. Retry; existing lines have not been replaced.',
      '추가 열을 만들지 못했습니다. 기존 명세는 유지됩니다. 다시 시도하세요.',
    ],
    'limit': [
      '额外列超过 32 列，请减少选择后重试。',
      'At most 32 additional columns are allowed. Select fewer columns.',
      '추가 열은 최대 32개입니다. 선택한 열 수를 줄이세요.',
    ],
    'client': [
      '文件客户与当前单据不同，请为该客户另建单据或选择替换。',
      'This file belongs to a different customer. Create another document or replace the existing lines.',
      '파일의 고객이 다릅니다. 새 문서를 만들거나 기존 명세를 교체하세요.',
    ],
    'files': [
      '一个单据最多采用 20 份识别文件，请分开保存。',
      'A document can adopt up to 20 files. Save these in separate documents.',
      '문서당 최대 20개 파일을 적용할 수 있습니다. 문서를 나누어 저장하세요.',
    ],
    'currency': [
      '两份文件的单价币种不同，请分开建单，避免文件单价被标成另一种币种。',
      'The files use different price currencies. Use separate documents to preserve their currency labels.',
      '파일의 가격 통화가 다릅니다. 통화가 잘못 표시되지 않도록 문서를 나누어 주세요.',
    ],
  };
  final values = text[key]!;
  return values[language == 'en'
      ? 1
      : language == 'ko'
      ? 2
      : 0];
}
