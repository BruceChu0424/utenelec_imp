import 'master_edit_dialog.dart';
import 'master_inline_edit.dart';

/// Creation reuses the established form definitions. UUID choices load when a
/// draft cell opens, so a failed lookup can be retried without losing input.
List<MasterFieldDef> masterInlineCreateFields(
  List<MasterFieldDef> fields, {
  Map<String, Future<List<MasterSelectOption>> Function()> options = const {},
  Set<String> excluded = const {},
}) => [
  for (final field in fields)
    if (!excluded.contains(field.key))
      if (options[field.key] case final load?)
        MasterFieldDef(
          key: field.key,
          label: field.label,
          required: field.required,
          readOnly: field.readOnly,
          type: MasterFieldType.custom,
          group: field.group,
          hint: field.hint,
          customBuilder: (context) =>
              MasterInlineOptionsCell(field: context, load: load),
        )
      else
        field,
];
