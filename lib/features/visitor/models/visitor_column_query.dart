import '../../../shared/search/table_column_query.dart';

typedef VisitorColumnQuery = TableColumnQuery;

Map<String, dynamic> visitorColumnParameters(
  Map<String, String?> searches,
  String? sort,
  bool ascending,
) => tableColumnParameters(searches, sort, ascending);
