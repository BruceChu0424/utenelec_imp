import '../../../core/network/api_exception.dart';
import '../models/subcontract_doc.dart';
import '../repositories/subcontract_repository.dart';

class SubcontractSaveOutcome {
  const SubcontractSaveOutcome({required this.detail, this.financeSubmitError});

  final SubcontractDocDetail detail;
  final String? financeSubmitError;
}

String? validateSubcontractOrderPrice({
  required SubcontractDocType docType,
  required String goodsName,
  required String priceText,
}) {
  if (docType != SubcontractDocType.order) return null;
  final price = double.tryParse(priceText.trim());
  if (price == null || !price.isFinite || price < 0) {
    return '\u8bf7\u586b\u5199$goodsName\u7684\u6709\u6548\u59d4\u5916\u5355\u4ef7';
  }
  return null;
}

/// 委外商业税率由财务审批冻结，不能用 null 或越界值让后端猜测。
String? validateSubcontractTaxRate(String value, {required bool required}) {
  final text = value.trim();
  if (text.isEmpty) return required ? '请明确填写税率；免税或零税率请填 0' : null;
  final parsed = double.tryParse(text);
  if (parsed == null) return '税率格式不正确，请填写 0 到 100 之间的数字';
  if (!parsed.isFinite || parsed < 0 || parsed > 100) {
    return '税率必须在 0 到 100 之间';
  }
  return null;
}

/// Saves one subcontract document and, for orders only, immediately submits
/// the saved draft to the configured finance reviewer.
///
/// A finance submission failure is returned with the already-saved draft so
/// the UI can route to detail and let the owner retry without re-entering data.
Future<SubcontractSaveOutcome> saveSubcontractDocument({
  required SubcontractRepository repository,
  required SubcontractDocType docType,
  required Map<String, dynamic> body,
  String? id,
  bool submitFinance = true,
}) async {
  final saved = id == null
      ? await repository.create(body)
      : await repository.update(id, body);
  if (docType != SubcontractDocType.order || !submitFinance) {
    return SubcontractSaveOutcome(detail: saved);
  }

  try {
    final submitted = await repository.submitFinance(saved.id);
    return SubcontractSaveOutcome(detail: submitted);
  } on ApiException catch (error) {
    return SubcontractSaveOutcome(
      detail: saved,
      financeSubmitError: error.message,
    );
  } catch (_) {
    return SubcontractSaveOutcome(detail: saved, financeSubmitError: '服务暂不可用');
  }
}
