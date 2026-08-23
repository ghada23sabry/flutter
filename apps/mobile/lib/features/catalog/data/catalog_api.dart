import '../../../core/api_client.dart';
import '../../../core/cache.dart';
import '../../../core/models/auth_models.dart';
import 'catalog_models.dart';

/// Catalog endpoints, matching `app/routers/{products,suppliers,categories}.py`.
///
/// Products/categories are store-scoped (`store_id` query param, validated
/// server-side against the token's accessible stores). Suppliers are
/// tenant-scoped (no `store_id`).
class CatalogApi {
  CatalogApi(this._client);

  final ApiClient _client;

  static const Duration _categoryCacheTtl = Duration(minutes: 5);

  // ── Products (store-scoped) ─────────────────────────────────────────────

  Future<Page<Product>> listProducts({
    required StoreInfo store,
    String? q,
    String? categoryId,
    String? status,
    int page = 1,
    int pageSize = 30,
  }) async {
    final json = await _client.get(
      '/products',
      query: {
        'store_id': store.id,
        'page': page,
        'page_size': pageSize,
        if (q != null && q.isNotEmpty) 'q': q,
        if (categoryId != null && categoryId.isNotEmpty)
          'category_id': categoryId,
        'status': ?status,
      },
    );
    return Page<Product>.fromJson(json, Product.fromJson);
  }

  Future<Product> getProduct({
    required StoreInfo store,
    required String id,
  }) async {
    final json = await _client.get(
      '/products/$id',
      query: {'store_id': store.id},
    );
    return Product.fromJson(json);
  }

  Future<Product> createProduct({
    required StoreInfo store,
    required ProductInput input,
  }) async {
    final json = await _client.post(
      '/products',
      query: {'store_id': store.id},
      body: input.toJson(),
    );
    return Product.fromJson(json);
  }

  Future<Product> updateProduct({
    required StoreInfo store,
    required String id,
    required ProductUpdate update,
  }) async {
    final json = await _client.patch(
      '/products/$id',
      query: {'store_id': store.id},
      body: update.toJson(),
    );
    return Product.fromJson(json);
  }

  /// Resolve a product by SKU (exact match server-side).
  Future<Product?> lookupBySku({
    required StoreInfo store,
    required String sku,
  }) async {
    final trimmed = sku.trim();
    if (trimmed.isEmpty) return null;
    try {
      final json = await _client.get(
        '/products/lookup/sku/$trimmed',
        query: {'store_id': store.id},
      );
      return Product.fromJson(json);
    } on ApiException catch (e) {
      if (e.isNotFound) return null;
      rethrow;
    }
  }

  /// Resolve a product by barcode (normalized server-side).
  Future<Product?> lookupByBarcode({
    required StoreInfo store,
    required String barcode,
  }) async {
    final normalized = barcode.trim();
    if (normalized.isEmpty) return null;
    try {
      final json = await _client.get(
        '/products/lookup/barcode/$normalized',
        query: {'store_id': store.id},
      );
      return Product.fromJson(json);
    } on ApiException catch (e) {
      if (e.isNotFound) return null;
      rethrow;
    }
  }

  /// Look up external product data for an unknown barcode via Open Food Facts.
  Future<BarcodeEnrichment?> enrichBarcode({
    required StoreInfo store,
    required String barcode,
  }) async {
    final normalized = barcode.trim();
    if (normalized.isEmpty) return null;
    try {
      final json = await _client.get(
        '/products/enrich/barcode/$normalized',
        query: {'store_id': store.id},
      );
      return BarcodeEnrichment.fromJson(json);
    } on ApiException catch (_) {
      return null;
    }
  }

  /// Suppliers linked to a product (`GET /products/{id}/suppliers`).
  Future<List<SupplierProductLink>> getProductSuppliers({
    required StoreInfo store,
    required String productId,
  }) async {
    final items = await _client.getList(
      '/products/$productId/suppliers',
      query: {'store_id': store.id},
    );
    return [
      for (final item in items)
        SupplierProductLink.fromJson(item as Map<String, dynamic>),
    ];
  }

  // ── Categories (store-scoped) ───────────────────────────────────────────

  Future<List<Category>> listCategories({
    required StoreInfo store,
    String? status,
    bool forceRefresh = false,
  }) async {
    final cacheKey = 'categories:${store.id}:${status ?? 'all'}';
    if (forceRefresh) {
      AppCache.instance.invalidate(cacheKey);
    }
    return AppCache.instance.get<List<Category>>(
      cacheKey,
      _categoryCacheTtl,
      () async {
        final items = await _client.getList(
          '/categories',
          query: {'store_id': store.id, 'status': ?status},
        );
        return [
          for (final item in items)
            Category.fromJson(item as Map<String, dynamic>),
        ];
      },
    );
  }

  Future<Category> getCategory({
    required StoreInfo store,
    required String id,
  }) async {
    final json = await _client.get(
      '/categories/$id',
      query: {'store_id': store.id},
    );
    return Category.fromJson(json);
  }

  Future<Category> createCategory({
    required StoreInfo store,
    required CategoryInput input,
  }) async {
    final json = await _client.post(
      '/categories',
      query: {'store_id': store.id},
      body: input.toJson(),
    );
    AppCache.instance.invalidatePrefix('categories:${store.id}');
    return Category.fromJson(json);
  }

  Future<Category> updateCategory({
    required StoreInfo store,
    required String id,
    required CategoryUpdate update,
  }) async {
    final json = await _client.patch(
      '/categories/$id',
      query: {'store_id': store.id},
      body: update.toJson(),
    );
    AppCache.instance.invalidatePrefix('categories:${store.id}');
    return Category.fromJson(json);
  }

  // ── Suppliers (tenant-scoped) ───────────────────────────────────────────

  Future<Page<Supplier>> listSuppliers({
    String? q,
    String? status,
    int page = 1,
    int pageSize = 30,
  }) async {
    final json = await _client.get(
      '/suppliers',
      query: {
        'page': page,
        'page_size': pageSize,
        if (q != null && q.isNotEmpty) 'q': q,
        'status': ?status,
      },
    );
    return Page<Supplier>.fromJson(json, Supplier.fromJson);
  }

  Future<Supplier> getSupplier({required String id}) async {
    final json = await _client.get('/suppliers/$id');
    return Supplier.fromJson(json);
  }

  Future<Supplier> createSupplier({required SupplierInput input}) async {
    final json = await _client.post('/suppliers', body: input.toJson());
    return Supplier.fromJson(json);
  }

  Future<Supplier> updateSupplier({
    required String id,
    required SupplierUpdate update,
  }) async {
    final json = await _client.patch('/suppliers/$id', body: update.toJson());
    return Supplier.fromJson(json);
  }

  /// Products linked to a supplier (`GET /suppliers/{id}/products`).
  Future<List<SupplierProductLink>> getSupplierProducts({
    required String supplierId,
  }) async {
    final items = await _client.getList('/suppliers/$supplierId/products');
    return [
      for (final item in items)
        SupplierProductLink.fromJson(item as Map<String, dynamic>),
    ];
  }

  Future<SupplierProductLink> linkProductToSupplier({
    required StoreInfo store,
    required String supplierId,
    required String productId,
    String? supplierSku,
    double? supplierCost,
    int? leadTimeDays,
    bool isPreferred = false,
  }) async {
    final json = await _client.post(
      '/suppliers/$supplierId/products',
      query: {'store_id': store.id},
      body: {
        'product_id': productId,
        'supplier_sku': ?supplierSku,
        'supplier_cost': ?supplierCost,
        'lead_time_days': ?leadTimeDays,
        'is_preferred': isPreferred,
      },
    );
    return SupplierProductLink.fromJson(json);
  }

  Future<SupplierProductLink> updateSupplierProductLink({
    required StoreInfo store,
    required String supplierId,
    required String productId,
    String? supplierSku,
    double? supplierCost,
    int? leadTimeDays,
    bool? isPreferred,
  }) async {
    final json = await _client.patch(
      '/suppliers/$supplierId/products/$productId',
      query: {'store_id': store.id},
      body: {
        'supplier_sku': ?supplierSku,
        'supplier_cost': ?supplierCost,
        'lead_time_days': ?leadTimeDays,
        'is_preferred': ?isPreferred,
      },
    );
    return SupplierProductLink.fromJson(json);
  }

  Future<void> unlinkProduct({
    required StoreInfo store,
    required String supplierId,
    required String productId,
  }) async {
    await _client.delete(
      '/suppliers/$supplierId/products/$productId',
      query: {'store_id': store.id},
    );
  }
}
