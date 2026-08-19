import '../../../core/api_client.dart';
import '../../../core/models/auth_models.dart';
import '../../catalog/data/catalog_models.dart';
import 'inventory_models.dart';

/// Inventory endpoints, matching `app/routers/inventory.py`.
///
/// Everything is store-scoped via `store_id` (validated server-side against
/// the token's accessible stores). Layout/expiry/adjust endpoints are
/// additionally gated by permissions; missing permission surfaces as 403.
class InventoryApi {
  const InventoryApi(this.client);

  final ApiClient client;

  String _date(DateTime d) =>
      '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

  double _quantize(double value) => (value * 1000).roundToDouble() / 1000;

  // ── Stock overview ──────────────────────────────────────────────────────

  Future<Page<StockItem>> listStock({
    required StoreInfo store,
    String? q,
    String? categoryId,
    String? stockStatus,
    int page = 1,
    int pageSize = 30,
  }) async {
    final json = await client.get(
      '/inventory/stock',
      query: {
        'store_id': store.id,
        'page': page,
        'page_size': pageSize,
        if (q != null && q.isNotEmpty) 'q': q,
        if (categoryId != null && categoryId.isNotEmpty)
          'category_id': categoryId,
        'stock_status': ?stockStatus,
      },
    );
    return Page<StockItem>.fromJson(json, StockItem.fromJson);
  }

  Future<StockSummary> getStockSummary({required StoreInfo store}) async {
    final json = await client.get(
      '/inventory/stock/summary',
      query: {'store_id': store.id},
    );
    return StockSummary.fromJson(json);
  }

  Future<ProductStock> getStockDetail({
    required StoreInfo store,
    required String productId,
  }) async {
    final json = await client.get(
      '/inventory/stock/$productId',
      query: {'store_id': store.id},
    );
    return ProductStock.fromJson(json);
  }

  Future<ProductStock> setOpeningStock({
    required StoreInfo store,
    required String productId,
    required double quantity,
    String? batchCode,
    DateTime? expiryDate,
  }) async {
    final json = await client.post(
      '/inventory/stock/$productId/opening',
      query: {'store_id': store.id},
      body: {
        'quantity': _quantize(quantity),
        if (batchCode != null && batchCode.isNotEmpty) 'batch_code': batchCode,
        if (expiryDate != null) 'expiry_date': _date(expiryDate),
      },
    );
    return ProductStock.fromJson(json);
  }

  Future<ProductStock> adjustStock({
    required StoreInfo store,
    required String productId,
    double? newQuantity,
    double? delta,
    required String reason,
    String? expiryBatchId,
    String? movementType,
  }) async {
    final json = await client.patch(
      '/inventory/stock/$productId',
      query: {'store_id': store.id},
      body: {
        if (newQuantity != null) 'new_quantity': _quantize(newQuantity),
        if (delta != null) 'delta': _quantize(delta),
        'reason': reason,
        if (expiryBatchId != null && expiryBatchId.isNotEmpty)
          'expiry_batch_id': expiryBatchId,
        if (movementType != null) 'movement_type': movementType,
      },
    );
    return ProductStock.fromJson(json);
  }

  // ── Movements ───────────────────────────────────────────────────────────

  Future<Page<StockMovement>> listMovements({
    required StoreInfo store,
    String? productId,
    String? movementType,
    int page = 1,
    int pageSize = 30,
  }) async {
    final json = await client.get(
      '/inventory/movements',
      query: {
        'store_id': store.id,
        'page': page,
        'page_size': pageSize,
        if (productId != null && productId.isNotEmpty) 'product_id': productId,
        'movement_type': ?movementType,
      },
    );
    return Page<StockMovement>.fromJson(json, StockMovement.fromJson);
  }

  // ── Layout: zones ───────────────────────────────────────────────────────

  Future<List<Zone>> listZones({
    required StoreInfo store,
    String? status,
  }) async {
    final items = await client.getList(
      '/inventory/zones',
      query: {'store_id': store.id, 'status': ?status},
    );
    return [
      for (final item in items) Zone.fromJson(item as Map<String, dynamic>),
    ];
  }

  Future<Zone> getZone({
    required StoreInfo store,
    required String zoneId,
  }) async {
    final json = await client.get(
      '/inventory/zones/$zoneId',
      query: {'store_id': store.id},
    );
    return Zone.fromJson(json);
  }

  Future<Zone> createZone({
    required StoreInfo store,
    required String name,
    String? code,
  }) async {
    final json = await client.post(
      '/inventory/zones',
      query: {'store_id': store.id},
      body: {'name': name, if (code != null && code.isNotEmpty) 'code': code},
    );
    return Zone.fromJson(json);
  }

  Future<Zone> updateZone({
    required StoreInfo store,
    required String zoneId,
    String? name,
    String? code,
    String? status,
  }) async {
    final json = await client.patch(
      '/inventory/zones/$zoneId',
      query: {'store_id': store.id},
      body: {'name': ?name, 'code': ?code, 'status': ?status},
    );
    return Zone.fromJson(json);
  }

  // ── Layout: shelves ─────────────────────────────────────────────────────

  Future<List<Shelf>> listShelves({
    required StoreInfo store,
    String? zoneId,
    String? status,
  }) async {
    final items = await client.getList(
      '/inventory/shelves',
      query: {
        'store_id': store.id,
        if (zoneId != null && zoneId.isNotEmpty) 'zone_id': zoneId,
        'status': ?status,
      },
    );
    return [
      for (final item in items) Shelf.fromJson(item as Map<String, dynamic>),
    ];
  }

  Future<Shelf> getShelf({
    required StoreInfo store,
    required String shelfId,
  }) async {
    final json = await client.get(
      '/inventory/shelves/$shelfId',
      query: {'store_id': store.id},
    );
    return Shelf.fromJson(json);
  }

  Future<Shelf> createShelf({
    required StoreInfo store,
    required String zoneId,
    required String label,
    String? code,
    int position = 0,
  }) async {
    final json = await client.post(
      '/inventory/shelves',
      query: {'store_id': store.id},
      body: {
        'zone_id': zoneId,
        'label': label,
        if (code != null && code.isNotEmpty) 'code': code,
        'position': position,
      },
    );
    return Shelf.fromJson(json);
  }

  Future<Shelf> updateShelf({
    required StoreInfo store,
    required String shelfId,
    String? zoneId,
    String? label,
    String? code,
    int? position,
    String? status,
  }) async {
    final json = await client.patch(
      '/inventory/shelves/$shelfId',
      query: {'store_id': store.id},
      body: {
        if (zoneId != null && zoneId.isNotEmpty) 'zone_id': zoneId,
        'label': ?label,
        'code': ?code,
        'position': ?position,
        'status': ?status,
      },
    );
    return Shelf.fromJson(json);
  }

  // ── Layout: shelf↔product mapping ───────────────────────────────────────

  Future<List<ShelfProductMap>> listShelfProducts({
    required StoreInfo store,
    required String shelfId,
  }) async {
    final items = await client.getList(
      '/inventory/shelves/$shelfId/products',
      query: {'store_id': store.id},
    );
    return [
      for (final item in items)
        ShelfProductMap.fromJson(item as Map<String, dynamic>),
    ];
  }

  Future<ShelfProductMap> mapProductToShelf({
    required StoreInfo store,
    required String shelfId,
    required String productId,
    int position = 0,
    bool isPrimary = false,
  }) async {
    final json = await client.post(
      '/inventory/shelves/$shelfId/products',
      query: {'store_id': store.id},
      body: {
        'product_id': productId,
        'position': position,
        'is_primary': isPrimary,
      },
    );
    return ShelfProductMap.fromJson(json);
  }

  Future<void> unmapProductFromShelf({
    required StoreInfo store,
    required String shelfId,
    required String productId,
  }) async {
    await client.delete(
      '/inventory/shelves/$shelfId/products/$productId',
      query: {'store_id': store.id},
    );
  }

  // ── Expiry ──────────────────────────────────────────────────────────────

  Future<List<ExpiryBatch>> listExpiryBatches({
    required StoreInfo store,
    String? productId,
    String? status,
  }) async {
    final items = await client.getList(
      '/inventory/expiry',
      query: {
        'store_id': store.id,
        if (productId != null && productId.isNotEmpty) 'product_id': productId,
        'status': ?status,
      },
    );
    return [
      for (final item in items)
        ExpiryBatch.fromJson(item as Map<String, dynamic>),
    ];
  }

  Future<ExpiryBatch> createExpiryBatch({
    required StoreInfo store,
    required String productId,
    required double quantity,
    required DateTime expiryDate,
    String? batchCode,
  }) async {
    final json = await client.post(
      '/inventory/expiry',
      query: {'store_id': store.id},
      body: {
        'product_id': productId,
        'quantity': _quantize(quantity),
        'expiry_date': _date(expiryDate),
        if (batchCode != null && batchCode.isNotEmpty) 'batch_code': batchCode,
      },
    );
    return ExpiryBatch.fromJson(json);
  }

  Future<ExpiryBatch> getExpiryBatch({
    required StoreInfo store,
    required String batchId,
  }) async {
    final json = await client.get(
      '/inventory/expiry/$batchId',
      query: {'store_id': store.id},
    );
    return ExpiryBatch.fromJson(json);
  }

  Future<ExpiryBatch> updateExpiryBatch({
    required StoreInfo store,
    required String batchId,
    String? batchCode,
    DateTime? expiryDate,
  }) async {
    final json = await client.patch(
      '/inventory/expiry/$batchId',
      query: {'store_id': store.id},
      body: {
        'batch_code': ?batchCode,
        if (expiryDate != null) 'expiry_date': _date(expiryDate),
      },
    );
    return ExpiryBatch.fromJson(json);
  }

  Future<void> deleteExpiryBatch({
    required StoreInfo store,
    required String batchId,
  }) async {
    await client.delete(
      '/inventory/expiry/$batchId',
      query: {'store_id': store.id},
    );
  }

  Future<ExpiryBatch> writeOffExpiryBatch({
    required StoreInfo store,
    required String batchId,
    required double quantity,
    required String reason,
  }) async {
    final json = await client.post(
      '/inventory/expiry/$batchId/write-off',
      query: {'store_id': store.id},
      body: {'quantity': _quantize(quantity), 'reason': reason},
    );
    return ExpiryBatch.fromJson(json);
  }
}
