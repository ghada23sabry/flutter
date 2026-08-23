/// AI count endpoints, matching `app/routers/ai.py`.
///
/// Everything is store-scoped via `store_id` (validated server-side against
/// the token's accessible stores). Each endpoint is permission-gated:
///   POST /ai/scans                  → ai.scan
///   POST /ai/scans/{id}/process     → ai.scan
///   GET  /ai/scans/{id}             → ai.view
///   GET  /ai/scans/{id}/detections  → ai.view
///   GET  /ai/scans/{id}/reconciliations → ai.view
///   PATCH /ai/scans/{id}/reconciliations/{rid} → ai.reconcile
///   POST /ai/scans/{id}/confirm     → ai.confirm
///
/// Missing permission surfaces as a typed 403 [ApiException]; the server is
/// authoritative. This client never mutates stock — the only inventory-write
/// path in the whole flow is an explicit `confirmScan`. Review decisions
/// (apply / ignore / override) are persisted server-side via the PATCH and
/// only change what confirmation will (or will not) apply.
library;

import '../../../core/api_client.dart';
import '../../../core/models/auth_models.dart';
import 'ai_models.dart';

class AiApi {
  const AiApi(this.client);

  final ApiClient client;

  Future<ScanSession> createScan({
    required StoreInfo store,
    required AiScanOperation operation,
    String? shelfId,
    String? note,
  }) async {
    final json = await client.post(
      '/ai/scans',
      query: {'store_id': store.id},
      body: {'operation': operation.wire, 'shelf_id': ?shelfId, 'note': ?note},
    );
    return ScanSession.fromJson(json);
  }

  /// Send raw image bytes to the mock/vision adapter. Never persists images.
  Future<ScanSession> processScan({
    required StoreInfo store,
    required String sessionId,
    required List<int> imageBytes,
  }) async {
    final json = await client.postBytes(
      '/ai/scans/$sessionId/process',
      bytes: imageBytes,
      query: {'store_id': store.id},
    );
    return ScanSession.fromJson(json);
  }

  Future<ScanSession> getScan({
    required StoreInfo store,
    required String sessionId,
  }) async {
    final json = await client.get(
      '/ai/scans/$sessionId',
      query: {'store_id': store.id},
    );
    return ScanSession.fromJson(json);
  }

  Future<List<ScanDetection>> getDetections({
    required StoreInfo store,
    required String sessionId,
  }) async {
    final items = await client.getList(
      '/ai/scans/$sessionId/detections',
      query: {'store_id': store.id},
    );
    return [
      for (final item in items)
        ScanDetection.fromJson(item as Map<String, dynamic>),
    ];
  }

  Future<List<ScanReconciliation>> getReconciliations({
    required StoreInfo store,
    required String sessionId,
  }) async {
    final items = await client.getList(
      '/ai/scans/$sessionId/reconciliations',
      query: {'store_id': store.id},
    );
    return [
      for (final item in items)
        ScanReconciliation.fromJson(item as Map<String, dynamic>),
    ];
  }

  /// Record a human review decision for one reconciliation row. Mutates review
  /// state only — inventory is never touched here; `confirmScan` remains the
  /// single stock-write path.
  Future<ScanReconciliation> updateReconciliation({
    required StoreInfo store,
    required String sessionId,
    required String reconciliationId,
    required String resolution,
    double? detectedQuantity,
  }) async {
    final json = await client.patch(
      '/ai/scans/$sessionId/reconciliations/$reconciliationId',
      query: {'store_id': store.id},
      body: {'resolution': resolution, 'detected_quantity': ?detectedQuantity},
    );
    return ScanReconciliation.fromJson(json);
  }

  /// The only stock-write path. What confirmation applies depends on the
  /// session's operation (server-side): count replaces quantities (COUNT
  /// movements), receive adds (PURCHASE), sale subtracts (SALE).
  Future<ScanSession> confirmScan({
    required StoreInfo store,
    required String sessionId,
  }) async {
    final json = await client.post(
      '/ai/scans/$sessionId/confirm',
      query: {'store_id': store.id},
    );
    return ScanSession.fromJson(json);
  }

  /// Link an unmatched detection to a newly created product.  After linking,
  /// the server rebuilds the reconciliation row for that product within the
  /// active scan session.  The caller should re-fetch detections and
  /// reconciliations to reflect the updated state.
  Future<void> linkDetection({
    required StoreInfo store,
    required String sessionId,
    required String detectionId,
    required String productId,
  }) async {
    await client.post(
      '/ai/scans/$sessionId/detections/$detectionId/link',
      query: {'store_id': store.id},
      body: {'product_id': productId},
    );
  }
}
