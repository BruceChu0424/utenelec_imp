import 'package:flutter/widgets.dart';
import 'platform_table_registry.dart';
import 'shared/platform_tables/platform_table_binding.dart';
import 'shared/platform_tables/table_column_projection.dart';

/// One application composition point for all screen/preview/export table schemas.
class PlatformTablesHost extends StatefulWidget {
  const PlatformTablesHost({super.key, required this.child});
  final Widget child;
  @override
  State<PlatformTablesHost> createState() => _PlatformTablesHostState();
}

class _PlatformTablesHostState extends State<PlatformTablesHost> {
  final _projection = TableColumnProjectionController();
  @override
  void dispose() {
    _projection.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => TableColumnProjectionScope(
    controller: _projection,
    child: PlatformTableCatalogScope(
      resolver: resolvePlatformTable,
      child: widget.child,
    ),
  );
}
