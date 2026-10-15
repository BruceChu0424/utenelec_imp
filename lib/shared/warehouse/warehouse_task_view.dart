/// Query boundary shared by warehouse lists, totals and header facets.
/// History keeps completed physical facts without presenting them as pending work.
enum WarehouseTaskView {
  active,
  history;

  String get apiValue => name.toUpperCase();
}
