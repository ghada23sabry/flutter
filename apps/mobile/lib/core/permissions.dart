/// Backend permission codes (mirrors `app/routers/*` constants).
abstract final class Permissions {
  static const String productsView = 'products.view';
  static const String productsManage = 'products.manage';
  static const String suppliersView = 'suppliers.view';
  static const String suppliersManage = 'suppliers.manage';
  static const String categoriesView = 'categories.view';
  static const String categoriesManage = 'categories.manage';
  static const String devicesView = 'devices.view';
  static const String devicesManage = 'devices.manage';
  static const String inventoryView = 'inventory.view';
  static const String inventoryAdjust = 'inventory.adjust';
  static const String inventoryLayout = 'inventory.manage_layout';
  static const String inventoryMovements = 'inventory.view_movements';
  static const String inventoryExpiry = 'inventory.manage_expiry';
  static const String aiScan = 'ai.scan';
  static const String aiView = 'ai.view';
  static const String aiReconcile = 'ai.reconcile';
  static const String aiConfirm = 'ai.confirm';
}
