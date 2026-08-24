import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../core/api_client.dart';
import '../../../core/permissions.dart';
import '../../../core/session.dart';
import '../../../core/theme/app_tokens.dart';
import '../../../core/util/app_format.dart';
import '../../../core/widgets/app_button.dart';
import '../../../core/widgets/app_card.dart';
import '../../../core/widgets/empty_state.dart';
import '../../../core/widgets/error_state.dart';
import '../../../core/widgets/loading_state.dart';
import '../../../core/widgets/status_badge.dart';
import '../../catalog/data/catalog_api.dart';
import '../../catalog/data/catalog_models.dart';
import '../../inventory/data/inventory_api.dart';
import '../../inventory/data/inventory_models.dart';
import '../data/ai_api.dart';
import '../data/ai_models.dart';
import '../data/mock_scan_image.dart';
import 'barcode_scan_screen.dart';
import 'camera_capture_screen.dart';
import 'unknown_product_screen.dart';

enum _AiWizardStep { operation, zone, shelf, image }

/// AI scan wizard: operation → (count: zone → shelf) → image → create →
/// process → review → explicit confirm.
///
/// The server is authoritative for every transition. This screen only asserts
/// inventory changed after the explicit confirmation response. Each UI surface
/// is gated by the matching `ai.*` permission; a missing permission hides the
/// action rather than hard-coding admin/owner assumptions.
class AiCountScreen extends StatefulWidget {
  const AiCountScreen({
    super.key,
    required this.aiApi,
    required this.inventoryApi,
    required this.catalogApi,
    required this.session,
    this.imageSource,
    this.initialOperation,
  });

  final AiApi aiApi;
  final InventoryApi inventoryApi;
  final CatalogApi catalogApi;
  final SessionController session;

  /// Deterministic M4-A test-image source; M4-B swaps in a camera source.
  final ScanImageSource? imageSource;

  /// Pre-select an operation (Sale / Receive / Count).  When non-null the
  /// wizard skips the operation step and jumps straight to image capture.
  final AiScanOperation? initialOperation;

  @override
  State<AiCountScreen> createState() => _AiCountScreenState();
}

class _AiCountScreenState extends State<AiCountScreen> {
  AiScanUiState _state = AiScanUiState.idle;
  _AiWizardStep _wizard = _AiWizardStep.operation;
  AiScanOperation _operation = AiScanOperation.count;

  static const List<(AiScanOperation, String, String, IconData)> _operations = [
    (
      AiScanOperation.count,
      'Count',
      'Replace stock quantities with what the camera detects '
          '(COUNT movements).',
      Icons.qr_code_scanner,
    ),
    (
      AiScanOperation.receive,
      'Receive',
      'Add received stock detected by the camera (PURCHASE movements).',
      Icons.inventory_2_outlined,
    ),
    (
      AiScanOperation.sale,
      'Sale',
      'Subtract sold stock detected by the camera (SALE movements).',
      Icons.shopping_cart_outlined,
    ),
  ];

  List<Zone>? _zones;
  List<Shelf>? _shelves;
  List<ScanImageOption>? _images;
  bool _zonesLoading = false;
  bool _shelvesLoading = false;
  bool _imagesLoading = false;
  String? _zonesError;
  String? _shelvesError;
  String? _imagesError;

  Zone? _zone;
  Shelf? _shelf;
  ScanImageOption? _lastImage;

  ScanSession? _session;
  List<ScanDetection> _detections = const [];
  List<ScanReconciliation> _reconciliations = const [];
  String? _error;

  /// Reconciliation rows the reviewer overrode via the quantity editor. Used
  /// only for display (an "Overridden" marker) — the server persists the actual
  /// review decision.
  final Set<String> _overriddenReconciliationIds = {};

  bool get _canScan => widget.session.hasPermission(Permissions.aiScan);
  bool get _canView => widget.session.hasPermission(Permissions.aiView);
  bool get _canReconcile =>
      widget.session.hasPermission(Permissions.aiReconcile);
  bool get _canConfirm => widget.session.hasPermission(Permissions.aiConfirm);

  @override
  void initState() {
    super.initState();
    final op = widget.initialOperation;
    if (op != null) {
      _operation = op;
      // Skip the operation chooser — start directly at the image step.
      _wizard = _AiWizardStep.image;
      // Kick off image loading since we skipped _selectOperation.
      _loadImages();
    }
  }

  // ── Operation / zone / shelf / image selection ─────────────────────────

  Future<void> _loadZones() async {
    final store = widget.session.selectedStore;
    if (store == null) return;
    setState(() {
      _zonesLoading = true;
      _zonesError = null;
    });
    try {
      final zones = await widget.inventoryApi.listZones(store: store);
      if (!mounted) return;
      setState(() {
        _zones = zones;
        _zonesLoading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _zonesLoading = false;
        _zonesError = e is ApiException
            ? e.message
            : 'Cannot reach the server. Check your connection.';
      });
    }
  }

  Future<void> _loadShelves() async {
    final store = widget.session.selectedStore;
    final zone = _zone;
    if (store == null || zone == null) return;
    setState(() {
      _shelvesLoading = true;
      _shelvesError = null;
    });
    try {
      final shelves = await widget.inventoryApi.listShelves(
        store: store,
        zoneId: zone.id,
      );
      if (!mounted) return;
      setState(() {
        _shelves = shelves;
        _shelvesLoading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _shelvesLoading = false;
        _shelvesError = e is ApiException
            ? e.message
            : 'Cannot reach the server. Check your connection.';
      });
    }
  }

  Future<void> _loadImages() async {
    final store = widget.session.selectedStore;
    if (store == null) return;
    setState(() {
      _imagesLoading = true;
      _imagesError = null;
    });
    try {
      final source =
          widget.imageSource ?? MockScanImageSource(widget.inventoryApi);
      final images = await source.listOptions(store: store);
      if (!mounted) return;
      setState(() {
        _images = images;
        _imagesLoading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _imagesLoading = false;
        _imagesError = e is ApiException
            ? e.message
            : 'Cannot reach the server. Check your connection.';
      });
    }
  }

  void _selectOperation(AiScanOperation operation) {
    setState(() {
      _operation = operation;
      _zone = null;
      _shelf = null;
      _wizard = operation == AiScanOperation.count
          ? _AiWizardStep.zone
          : _AiWizardStep.image;
    });
    if (operation == AiScanOperation.count) {
      _loadZones();
    } else {
      _loadImages();
    }
  }

  void _selectZone(Zone zone) {
    setState(() {
      _zone = zone;
      _wizard = _AiWizardStep.shelf;
    });
    _loadShelves();
  }

  void _selectShelf(Shelf shelf) {
    setState(() {
      _shelf = shelf;
      _wizard = _AiWizardStep.image;
    });
    _loadImages();
  }

  void _stepBack() {
    switch (_wizard) {
      case _AiWizardStep.operation:
        Navigator.of(context).pop();
      case _AiWizardStep.zone:
        setState(() {
          _wizard = _AiWizardStep.operation;
          _zone = null;
        });
      case _AiWizardStep.shelf:
        setState(() {
          _wizard = _AiWizardStep.zone;
          _shelf = null;
        });
      case _AiWizardStep.image:
        if (widget.initialOperation != null) {
          Navigator.of(context).pop();
        } else {
          setState(() {
            _wizard = _operation == AiScanOperation.count
                ? _AiWizardStep.shelf
                : _AiWizardStep.operation;
            _shelf = null;
          });
        }
    }
  }

  // ── Create → process → load results ─────────────────────────────────────

  Future<void> _startScan(ScanImageOption option) async {
    final store = widget.session.selectedStore;
    if (store == null) return;
    _lastImage = option;
    _overriddenReconciliationIds.clear();
    setState(() {
      _state = AiScanUiState.creating;
      _error = null;
    });
    try {
      final session = await widget.aiApi.createScan(
        store: store,
        operation: _operation,
        shelfId: _operation == AiScanOperation.count ? _shelf?.id : null,
      );
      if (!mounted) return;
      setState(() {
        _session = session;
        _state = AiScanUiState.processing;
      });

      final processed = await widget.aiApi.processScan(
        store: store,
        sessionId: session.id,
        imageBytes: option.bytes,
      );
      if (!mounted) return;
      if (processed.isFailed) {
        setState(() {
          _session = processed;
          _state = AiScanUiState.failed;
          _error = 'The scan could not be processed.';
        });
        return;
      }
      // Keep showing the processing spinner while we fetch detections and
      // reconciliations. Without this, the results view renders with empty
      // lists for the ~1-3 s it takes _loadResults to complete.
      setState(() => _session = processed);
      await _loadResults();
    } on ApiException catch (e) {
      _fail(kDebugMode ? '[${e.statusCode}] ${e.message}' : e.message);
    } catch (_) {
      _fail('Cannot reach the server. Check your connection.');
    }
  }

  Future<void> _loadResults() async {
    final store = widget.session.selectedStore;
    final session = _session;
    if (store == null || session == null) return;

    try {
      if (_canView) {
        final detections = await widget.aiApi.getDetections(
          store: store,
          sessionId: session.id,
        );
        if (!mounted) return;
        setState(() => _detections = detections);
      }
      // Reconciliation rows are readable with ai.view; mutating them needs
      // ai.reconcile (enforced server-side on the PATCH).
      if (_canReconcile || _canView) {
        final reconciliations = await widget.aiApi.getReconciliations(
          store: store,
          sessionId: session.id,
        );
        if (!mounted) return;
        setState(() => _reconciliations = reconciliations);
      }
      if (!mounted) return;
      // Don't overwrite a terminal state (confirmed/failed/cancelled) —
      // _loadResults may be called after confirm to refresh reconciliation
      // data, but the UI state is already settled.
      if (_state != AiScanUiState.confirmed &&
          _state != AiScanUiState.failed) {
        setState(
          () => _state = session.isNeedsReview
              ? AiScanUiState.needsReview
              : AiScanUiState.readyToConfirm,
        );
      }
    } on ApiException catch (e) {
      _fail(kDebugMode ? '[${e.statusCode}] ${e.message}' : e.message);
    } catch (_) {
      _fail('Cannot reach the server. Check your connection.');
    }
  }

  void _fail(String message) {
    if (!mounted) return;
    setState(() {
      _state = AiScanUiState.failed;
      _error = message;
    });
  }

  void _retry() {
    final session = _session;
    if (session == null) {
      setState(() {
        _state = AiScanUiState.idle;
        _wizard = _AiWizardStep.image;
        _error = null;
      });
      _loadImages();
      return;
    }
    if (session.isProcessing) {
      final option = _lastImage;
      if (option != null) {
        _startScan(option);
      }
      return;
    }
    if (session.isCompleted || session.isNeedsReview) {
      _loadResults();
      return;
    }
    // Server-side failed / cancelled / confirmed: start over.
    _overriddenReconciliationIds.clear();
    setState(() {
      _state = AiScanUiState.idle;
      _wizard = _AiWizardStep.operation;
      _session = null;
      _detections = const [];
      _reconciliations = const [];
      _error = null;
    });
  }

  /// Navigate to the product creation screen with data pre-filled from an
  /// AI detection's metadata.  After the user creates the product, the
  /// detection is linked to it server-side and the session state is refreshed
  /// so the newly created product participates in reconciliation and
  /// confirmation.
  Future<void> _createProductFromDetection(ScanDetection detection) async {
    final store = widget.session.selectedStore;
    if (store == null) return;
    final data = UnknownProductData(
      name: detection.metaName ?? '',
      barcode: detection.detectedBarcode,
      sku: detection.detectedSku,
      category: detection.metaCategory,
      brand: detection.metaBrand,
      variant: detection.metaVariant,
      modelName: detection.metaModelName,
      description: detection.metaDescription,
      size: detection.metaSize,
      weight: detection.metaWeight,
      volume: detection.metaVolume,
      sellingPrice: detection.metaSellingPrice,
      detectedQuantity: detection.quantityDetected,
    );
    final result = await Navigator.of(context).push<UnknownProductCreated>(
      MaterialPageRoute(
        builder: (_) => UnknownProductScreen(
          catalogApi: widget.catalogApi,
          store: store,
          detected: data,
        ),
      ),
    );
    if (result == null || !mounted) return;

    // Product created — now link the detection to it server-side.
    final session = _session;
    if (session == null) return;

    setState(() {
      _state = AiScanUiState.processing;
      _error = null;
    });

    try {
      await widget.aiApi.linkDetection(
        store: store,
        sessionId: session.id,
        detectionId: detection.id,
        productId: result.product.id,
      );
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() => _state = AiScanUiState.needsReview);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Product created but could not link to scan: ${e.message}. '
            'You can retry or continue reviewing other detections.',
          ),
        ),
      );
      return;
    } catch (_) {
      if (!mounted) return;
      setState(() => _state = AiScanUiState.needsReview);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Product created but could not link to scan. '
            'Check your connection and retry.',
          ),
        ),
      );
      return;
    }

    // Link succeeded — refresh detections and reconciliations.
    if (!mounted) return;
    await _loadResults();
  }

  /// Open the real camera and route a captured frame through the normal
  /// create → process → review → confirm pipeline.
  Future<void> _capturePhoto() async {
    final result = await Navigator.of(context).push<CameraCaptureResult>(
      MaterialPageRoute(builder: (_) => const CameraCaptureScreen()),
    );
    if (result == null || !mounted) return;
    final desc = result.barcodeValue != null
        ? 'Barcode ${result.barcodeValue}'
        : 'Camera capture';
    await _startScan(
      ScanImageOption(
        id: 'camera-${DateTime.now().millisecondsSinceEpoch}',
        label: 'Camera frame',
        description: desc,
        bytes: result.imageBytes,
      ),
    );
  }

  /// Scan a barcode, look up the product, and present a quantity-adjustment
  /// dialog for the selected operation (COUNT / RECEIVE / SALE).
  Future<void> _scanBarcode() async {
    final scanResult = await Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => const BarcodeScanScreen()),
    );
    if (scanResult == null || !mounted) return;

    final store = widget.session.selectedStore;
    if (store == null) return;

    // Look up the product by barcode (tenant/store scoped).
    final catalogApi = CatalogApi(widget.session.apiClient);
    final product = await catalogApi.lookupByBarcode(
      store: store,
      barcode: scanResult.barcode,
    );

    if (!mounted) return;

    if (product == null) {
      // Flow D — unknown product: let the user review and create it.
      final created = await Navigator.of(context).push<UnknownProductCreated>(
        MaterialPageRoute(
          builder: (_) => UnknownProductScreen(
            catalogApi: catalogApi,
            store: store,
            detected: UnknownProductData(
              barcode: scanResult.barcode,
            ),
          ),
        ),
      );
      if (created != null && mounted) {
        // Product created — continue directly to the operation dialog
        // so the user doesn't need to re-scan the barcode.
        await _showBarcodeOperationDialog(created.product);
      }
      return;
    }

    // Product found — show quantity dialog for the current operation.
    if (!mounted) return;
    await _showBarcodeOperationDialog(product);
  }

  /// Show a dialog to enter quantity for a barcode-resolved product.
  /// Applies the stock adjustment directly (COUNT / RECEIVE / SALE).
  Future<void> _showBarcodeOperationDialog(Product product) async {
    final store = widget.session.selectedStore;
    if (store == null) return;

    final qtyCtrl = TextEditingController(text: '1');
    String? error;

    final confirmed = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          title: Text(_operationLabel),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                product.name,
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const SizedBox(height: AppSpacing.xs),
              Text(
                'SKU: ${product.sku}'
                '${product.barcode != null ? '  ·  Barcode: ${product.barcode}' : ''}',
                style: Theme.of(context).textTheme.bodySmall,
              ),
              const SizedBox(height: AppSpacing.lg),
              TextField(
                controller: qtyCtrl,
                keyboardType: TextInputType.number,
                inputFormatters: [
                  FilteringTextInputFormatter.digitsOnly,
                ],
                autofocus: true,
                decoration: InputDecoration(
                  labelText: 'Quantity',
                  errorText: error,
                  border: const OutlineInputBorder(),
                  isDense: true,
                ),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () {
                final qty = int.tryParse(qtyCtrl.text);
                if (qty == null || qty <= 0) {
                  setDialogState(() => error = 'Enter a valid quantity.');
                  return;
                }
                Navigator.of(ctx).pop(true);
              },
              child: Text(_operationLabel),
            ),
          ],
        ),
      ),
    );

    if (confirmed != true || !mounted) return;

    final qty = int.tryParse(qtyCtrl.text) ?? 0;
    if (qty <= 0) return;

    // Apply the stock adjustment via the inventory endpoint.
    try {
      final delta = switch (_operation) {
        AiScanOperation.count => qty.toDouble(),
        AiScanOperation.receive => qty.toDouble(),
        AiScanOperation.sale => -qty.toDouble(),
      };
      final reason = switch (_operation) {
        AiScanOperation.count => 'AI Count — barcode scan',
        AiScanOperation.receive => 'AI Receive — barcode scan',
        AiScanOperation.sale => 'AI Sale — barcode scan',
      };
      final movementType = switch (_operation) {
        AiScanOperation.count => 'ADJUSTMENT',
        AiScanOperation.receive => 'PURCHASE',
        AiScanOperation.sale => 'SALE',
      };
      await widget.inventoryApi.adjustStock(
        store: store,
        productId: product.id,
        delta: delta,
        reason: reason,
        movementType: movementType,
      );
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              '$_operationLabel: ${product.name} × $qty applied.',
            ),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Stock adjustment failed: $e')),
        );
      }
    }
  }

  // ── Review (override / ignore) ────────────────────────────────────────────

  Future<void> _overrideQuantity(ScanReconciliation reconciliation) async {
    if (!_canReconcile) return;
    final value = await showDialog<double>(
      context: context,
      builder: (_) =>
          _QuantityOverrideDialog(initial: reconciliation.detectedQuantity),
    );
    if (value == null || !mounted) return;
    await _submitReview(
      reconciliation,
      resolution: 'apply',
      detectedQuantity: value,
    );
  }

  Future<void> _ignoreReconciliation(ScanReconciliation reconciliation) async {
    if (!_canReconcile) return;
    await _submitReview(reconciliation, resolution: 'ignore');
  }

  Future<void> _submitReview(
    ScanReconciliation reconciliation, {
    required String resolution,
    double? detectedQuantity,
  }) async {
    final store = widget.session.selectedStore;
    final session = _session;
    if (store == null || session == null) return;
    try {
      final updated = await widget.aiApi.updateReconciliation(
        store: store,
        sessionId: session.id,
        reconciliationId: reconciliation.id,
        resolution: resolution,
        detectedQuantity: detectedQuantity,
      );
      if (!mounted) return;
      setState(() {
        _reconciliations = [
          for (final r in _reconciliations) r.id == updated.id ? updated : r,
        ];
        if (resolution == 'apply' && detectedQuantity != null) {
          _overriddenReconciliationIds.add(updated.id);
        }
      });
    } on ApiException catch (e) {
      _showSnack(e.message);
    } catch (_) {
      _showSnack('Cannot reach the server. Check your connection.');
    }
  }

  void _showSnack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  // ── Explicit confirmation ───────────────────────────────────────────────

  Future<void> _confirm() async {
    final store = widget.session.selectedStore;
    final session = _session;
    if (store == null || session == null) return;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Confirm scan?'),
        content: Text(_confirmDialogText),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('Confirm'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    setState(() => _state = AiScanUiState.confirming);
    try {
      final result = await widget.aiApi.confirmScan(
        store: store,
        sessionId: session.id,
      );
      if (!mounted) return;
      setState(() {
        _session = result;
        _state = AiScanUiState.confirmed;
      });
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(
        () => _state = _session!.isNeedsReview
            ? AiScanUiState.needsReview
            : AiScanUiState.readyToConfirm,
      );
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(e.message)));
    } catch (_) {
      if (!mounted) return;
      setState(
        () => _state = _session!.isNeedsReview
            ? AiScanUiState.needsReview
            : AiScanUiState.readyToConfirm,
      );
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Cannot reach the server. Check your connection.'),
        ),
      );
    }
  }

  // ── Build ───────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    if (!_canScan) {
      return Scaffold(
        appBar: AppBar(title: const Text('AI Scan')),
        body: EmptyState(
          icon: Icons.lock_outline,
          title: 'No AI scan access',
          message: 'You need the ai.scan permission to run an AI stock scan.',
        ),
      );
    }

    final canStepBack = _state == AiScanUiState.idle
        ? true
        : _state == AiScanUiState.creating || _state == AiScanUiState.processing
        ? false
        : true;

    return Scaffold(
      appBar: AppBar(
        automaticallyImplyLeading: false,
        leading: canStepBack
            ? IconButton(
                tooltip: 'Back',
                icon: const Icon(Icons.arrow_back),
                onPressed: () {
                  if (_state == AiScanUiState.idle) {
                    _stepBack();
                  } else {
                    Navigator.of(context).pop();
                  }
                },
              )
            : null,
        title: Text(
          _state == AiScanUiState.idle ? _wizardTitle : _operationTitle,
        ),
      ),
      body: _buildBody(),
    );
  }

  String get _wizardTitle => switch (_wizard) {
    _AiWizardStep.operation => 'AI Scan · Choose an operation',
    _AiWizardStep.zone => 'AI Count · Step 1 of 3',
    _AiWizardStep.shelf => 'AI Count · Step 2 of 3',
    _AiWizardStep.image => switch (_operation) {
      AiScanOperation.count => 'AI Count · Step 3 of 3',
      AiScanOperation.receive => 'AI Receive · Step 2 of 2',
      AiScanOperation.sale => 'AI Sale · Step 2 of 2',
    },
  };

  String get _operationTitle => switch (_operation) {
    AiScanOperation.count => 'AI Count',
    AiScanOperation.receive => 'AI Receive',
    AiScanOperation.sale => 'AI Sale',
  };

  String get _operationLabel => switch (_operation) {
    AiScanOperation.count => 'Count',
    AiScanOperation.receive => 'Receive',
    AiScanOperation.sale => 'Sale',
  };

  String get _confirmLabel => switch (_operation) {
    AiScanOperation.count => 'Confirm counts',
    AiScanOperation.receive => 'Confirm receiving',
    AiScanOperation.sale => 'Confirm sale',
  };

  String get _confirmDialogText => switch (_operation) {
    AiScanOperation.count =>
      'This applies the counted quantities as stock COUNT movements. '
          'Existing stock quantities will be replaced for the reviewed products. '
          'Ignored products are not changed. This cannot be undone.',
    AiScanOperation.receive =>
      'This adds the detected quantities as stock PURCHASE movements, '
          'increasing stock for the reviewed products. '
          'Ignored products are not changed. This cannot be undone.',
    AiScanOperation.sale =>
      'This subtracts the detected quantities as stock SALE movements, '
          'decreasing stock for the reviewed products. '
          'Ignored products are not changed. This cannot be undone.',
  };

  String get _successMessage => switch (_operation) {
    AiScanOperation.count => 'Counted quantities were applied to stock.',
    AiScanOperation.receive => 'Received quantities were added to stock.',
    AiScanOperation.sale => 'Sold quantities were subtracted from stock.',
  };

  Widget _buildBody() {
    switch (_state) {
      case AiScanUiState.creating:
        return const LoadingState(message: 'Creating scan session…');
      case AiScanUiState.processing:
        return const LoadingState(message: 'Processing image…');
      case AiScanUiState.failed:
        return ErrorState(
          title: 'Scan failed',
          message: _error ?? 'Something went wrong.',
          onRetry: _retry,
        );
      case AiScanUiState.confirmed:
        return _buildSuccess();
      case AiScanUiState.idle:
        return _buildWizard();
      case AiScanUiState.loaded:
      case AiScanUiState.needsReview:
      case AiScanUiState.readyToConfirm:
      case AiScanUiState.confirming:
        return _buildResults();
    }
  }

  // ── Wizard steps ────────────────────────────────────────────────────────

  Widget _buildWizard() {
    return switch (_wizard) {
      _AiWizardStep.operation => _buildOperationStep(),
      _AiWizardStep.zone => _buildZoneStep(),
      _AiWizardStep.shelf => _buildShelfStep(),
      _AiWizardStep.image => _buildImageStep(),
    };
  }

  Widget _buildOperationStep() {
    final scheme = Theme.of(context).colorScheme;
    return ListView(
      padding: const EdgeInsets.all(AppSpacing.lg),
      children: [
        Text(
          'What are you recording?',
          style: Theme.of(context).textTheme.titleMedium,
        ),
        const SizedBox(height: AppSpacing.xs),
        Text(
          'The operation decides how a confirmed scan changes stock: '
          'count replaces, receive adds, sale subtracts.',
          style: Theme.of(
            context,
          ).textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
        ),
        const SizedBox(height: AppSpacing.lg),
        for (final (operation, label, description, icon) in _operations)
          Padding(
            padding: const EdgeInsets.only(bottom: AppSpacing.sm),
            child: AppCard(
              key: ValueKey('operation-$label'),
              onTap: () => _selectOperation(operation),
              child: Row(
                children: [
                  Icon(icon, color: scheme.primary),
                  const SizedBox(width: AppSpacing.md),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          label,
                          style: Theme.of(context).textTheme.bodyLarge,
                        ),
                        if (description.isNotEmpty)
                          Text(
                            description,
                            style: Theme.of(context).textTheme.bodySmall
                                ?.copyWith(color: scheme.onSurfaceVariant),
                          ),
                      ],
                    ),
                  ),
                  const Icon(Icons.chevron_right, size: 20),
                ],
              ),
            ),
          ),
      ],
    );
  }

  Widget _buildZoneStep() {
    if (_zonesLoading && _zones == null) {
      return const LoadingState(message: 'Loading zones…');
    }
    if (_zonesError != null && _zones == null) {
      return ErrorState(message: _zonesError!, onRetry: _loadZones);
    }
    final zones = _zones ?? const [];
    if (zones.isEmpty) {
      return EmptyState(
        icon: Icons.grid_view_outlined,
        title: 'No zones yet',
        message:
            'Create a zone and a shelf in the Inventory layout first, then run an AI count.',
      );
    }
    return ListView.separated(
      padding: const EdgeInsets.all(AppSpacing.lg),
      itemCount: zones.length,
      separatorBuilder: (_, _) => const SizedBox(height: AppSpacing.sm),
      itemBuilder: (context, index) {
        final zone = zones[index];
        return AppCard(
          onTap: () => _selectZone(zone),
          child: Row(
            children: [
              Icon(
                Icons.grid_view_outlined,
                color: Theme.of(context).colorScheme.primary,
              ),
              const SizedBox(width: AppSpacing.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      zone.name,
                      style: Theme.of(context).textTheme.bodyLarge,
                    ),
                    if (zone.code != null && zone.code!.isNotEmpty)
                      Text(
                        zone.code!,
                        style: Theme.of(context).textTheme.labelSmall?.copyWith(
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                      ),
                  ],
                ),
              ),
              const Icon(Icons.chevron_right, size: 20),
            ],
          ),
        );
      },
    );
  }

  Widget _buildShelfStep() {
    if (_shelvesLoading && _shelves == null) {
      return const LoadingState(message: 'Loading shelves…');
    }
    if (_shelvesError != null && _shelves == null) {
      return ErrorState(message: _shelvesError!, onRetry: _loadShelves);
    }
    final shelves = _shelves ?? const [];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(
            AppSpacing.lg,
            AppSpacing.md,
            AppSpacing.lg,
            0,
          ),
          child: Wrap(
            spacing: AppSpacing.sm,
            runSpacing: AppSpacing.sm,
            children: [
              StatusBadge(label: _zone?.name ?? 'Zone', status: AppStatus.info),
            ],
          ),
        ),
        Expanded(
          child: shelves.isEmpty
              ? EmptyState(
                  icon: Icons.storefront_outlined,
                  title: 'No shelves in this zone',
                  message:
                      'Add a shelf to ${_zone?.name ?? 'this zone'} first.',
                )
              : ListView.separated(
                  padding: const EdgeInsets.all(AppSpacing.lg),
                  itemCount: shelves.length,
                  separatorBuilder: (_, _) =>
                      const SizedBox(height: AppSpacing.sm),
                  itemBuilder: (context, index) {
                    final shelf = shelves[index];
                    return AppCard(
                      onTap: () => _selectShelf(shelf),
                      child: Row(
                        children: [
                          Icon(
                            Icons.storefront_outlined,
                            color: Theme.of(context).colorScheme.primary,
                          ),
                          const SizedBox(width: AppSpacing.md),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  shelf.label,
                                  style: Theme.of(context).textTheme.bodyLarge,
                                ),
                                if (shelf.code != null &&
                                    shelf.code!.isNotEmpty)
                                  Text(
                                    shelf.code!,
                                    style: Theme.of(context)
                                        .textTheme
                                        .labelSmall
                                        ?.copyWith(
                                          color: Theme.of(
                                            context,
                                          ).colorScheme.onSurfaceVariant,
                                        ),
                                  ),
                              ],
                            ),
                          ),
                          const Icon(Icons.chevron_right, size: 20),
                        ],
                      ),
                    );
                  },
                ),
        ),
      ],
    );
  }

  Widget _buildImageStep() {
    final images = _images ?? const [];
    final showImagesLoading = _imagesLoading && _images == null;
    final showImagesError = _imagesError != null && _images == null;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(
            AppSpacing.lg,
            AppSpacing.md,
            AppSpacing.lg,
            0,
          ),
          child: Wrap(
            spacing: AppSpacing.sm,
            runSpacing: AppSpacing.sm,
            children: [
              if (_operation == AiScanOperation.count) ...[
                StatusBadge(
                  label: _zone?.name ?? 'Zone',
                  status: AppStatus.info,
                ),
                if (_shelf != null)
                  StatusBadge(label: _shelf!.label, status: AppStatus.neutral),
              ] else
                StatusBadge(label: _operationLabel, status: AppStatus.info),
            ],
          ),
        ),
        Expanded(
          child: ListView(
            padding: const EdgeInsets.all(AppSpacing.lg),
            children: [
              _buildBarcodeCard(),
              const SizedBox(height: AppSpacing.sm),
              _buildCameraCard(),
              if (showImagesLoading) ...[
                const SizedBox(height: AppSpacing.lg),
                const LoadingState(message: 'Preparing test images…'),
              ],
              if (showImagesError) ...[
                const SizedBox(height: AppSpacing.lg),
                ErrorState(message: _imagesError!, onRetry: _loadImages),
              ],
              if (images.isNotEmpty) ...[
                const SizedBox(height: AppSpacing.lg),
                Text(
                  'Test images',
                  style: Theme.of(context).textTheme.labelMedium?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: AppSpacing.sm),
                ...images.map(
                  (option) => Padding(
                    padding: const EdgeInsets.only(bottom: AppSpacing.sm),
                    child: _buildImageCard(option),
                  ),
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }

  /// Real-device photo capture via the camera plugin.
  Widget _buildCameraCard() {
    return AppCard(
      key: const ValueKey('camera-capture-card'),
      onTap: _capturePhoto,
      child: Row(
        children: [
          Icon(
            Icons.photo_camera_outlined,
            color: Theme.of(context).colorScheme.primary,
          ),
          const SizedBox(width: AppSpacing.md),
          const Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Take a photo'),
                Text(
                  'Capture a photo for AI product recognition. '
                  'No barcode required.',
                ),
              ],
            ),
          ),
          const Icon(Icons.chevron_right, size: 20),
        ],
      ),
    );
  }

  /// Barcode scan — identifies a product by barcode for quick operations.
  Widget _buildBarcodeCard() {
    return AppCard(
      key: const ValueKey('barcode-scan-card'),
      onTap: _scanBarcode,
      child: Row(
        children: [
          Icon(
            Icons.qr_code_scanner,
            color: Theme.of(context).colorScheme.primary,
          ),
          const SizedBox(width: AppSpacing.md),
          const Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Scan Barcode'),
                Text(
                  'Identify a product by its barcode for quick stock operation.',
                ),
              ],
            ),
          ),
          const Icon(Icons.chevron_right, size: 20),
        ],
      ),
    );
  }

  Widget _buildImageCard(ScanImageOption option) {
    return AppCard(
      onTap: () => _startScan(option),
      child: Row(
        children: [
          const Icon(Icons.photo_outlined),
          const SizedBox(width: AppSpacing.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  option.label,
                  style: Theme.of(context).textTheme.bodyLarge,
                ),
                if (option.description != null)
                  Text(
                    option.description!,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
              ],
            ),
          ),
          const Icon(Icons.play_circle_outline, size: 20),
        ],
      ),
    );
  }

  // ── Results + reconciliation + confirm ──────────────────────────────────

  Widget _buildResults() {
    final session = _session;
    if (session == null) {
      return ErrorState(message: 'No scan session.', onRetry: _retry);
    }
    final confirming = _state == AiScanUiState.confirming;

    return ListView(
      padding: const EdgeInsets.all(AppSpacing.lg),
      children: [
        _buildSessionHeader(session),
        const SizedBox(height: AppSpacing.lg),
        if (session.isNeedsReview) ...[
          Container(
            padding: const EdgeInsets.all(AppSpacing.md),
            decoration: BoxDecoration(
              color: AppColors.warningContainer,
              borderRadius: BorderRadius.circular(AppRadius.md),
            ),
            child: Row(
              children: [
                Icon(Icons.warning_amber_outlined, color: AppColors.warning),
                const SizedBox(width: AppSpacing.sm),
                Expanded(
                  child: Text(
                    'Some detections need review. Review the reconciliation below before confirming.',
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      color: AppColors.onWarningContainer,
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: AppSpacing.lg),
        ],
        if (_canView)
          _buildSection(
            title: 'Detections',
            icon: Icons.search,
            child: _detections.isEmpty
                ? Text(
                    'No detections recorded.',
                    style: Theme.of(context).textTheme.bodyMedium,
                  )
                : Column(
                    children: [
                      for (final detection in _detections)
                        Padding(
                          padding: const EdgeInsets.only(bottom: AppSpacing.sm),
                          child: _DetectionTile(
                            detection: detection,
                            onCreateProduct: detection.isUnmatched
                                ? () => _createProductFromDetection(detection)
                                : null,
                          ),
                        ),
                    ],
                  ),
          )
        else
          _permissionNote('Results require the ai.view permission.'),
        const SizedBox(height: AppSpacing.lg),
        if (_canReconcile || _canView)
          _buildSection(
            title: 'Reconciliation',
            icon: Icons.compare_arrows,
            child: _reconciliations.isEmpty
                ? Text(
                    'No reconciliation rows.',
                    style: Theme.of(context).textTheme.bodyMedium,
                  )
                : Column(
                    children: [
                      for (final reconciliation in _reconciliations)
                        Padding(
                          padding: const EdgeInsets.only(bottom: AppSpacing.sm),
                          child: _ReconciliationTile(
                            reconciliation: reconciliation,
                            overridden: _overriddenReconciliationIds.contains(
                              reconciliation.id,
                            ),
                            canReview:
                                _canReconcile &&
                                reconciliation.status ==
                                    ReconciliationStatus.needsReview &&
                                !reconciliation.isIgnored,
                            onOverride: () => _overrideQuantity(reconciliation),
                            onIgnore: () =>
                                _ignoreReconciliation(reconciliation),
                          ),
                        ),
                    ],
                  ),
          )
        else
          _permissionNote(
            'Reconciliation results require the ai.view permission.',
          ),
        if (!_canReconcile)
          _permissionNote(
            'Reviewing counts requires the ai.reconcile permission.',
          ),
        const SizedBox(height: AppSpacing.lg),
        if (_canConfirm && session.canConfirm) ...[
          _buildReviewSummary(),
          AppButton(
            key: const ValueKey('confirm-counts-button'),
            label: _confirmLabel,
            icon: Icons.check_circle_outline,
            loading: confirming,
            onPressed: confirming ? null : _confirm,
          ),
        ] else if (_canConfirm)
          _permissionNote(
            'This scan is ${ScanStatus.label(session.status).toLowerCase()} and cannot be confirmed.',
          )
        else
          _permissionNote(
            'Confirming counts requires the ai.confirm permission.',
          ),
        const SizedBox(height: AppSpacing.lg),
      ],
    );
  }

  /// Before confirmation, state what each reconciliation row will do at
  /// confirm time (applied / ignored / overridden).
  Widget _buildReviewSummary() {
    final toApply = _reconciliations
        .where((r) => !r.isIgnored && r.hasVariance)
        .length;
    final ignored = _reconciliations.where((r) => r.isIgnored).length;
    final overridden = _reconciliations
        .where((r) => _overriddenReconciliationIds.contains(r.id))
        .length;
    if (_reconciliations.isEmpty) return const SizedBox.shrink();

    final parts = <String>['$toApply product(s) to apply'];
    if (ignored > 0) parts.add('$ignored ignored');
    if (overridden > 0) parts.add('$overridden overridden');
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.sm),
      child: Text(
        parts.join(' · '),
        style: Theme.of(context).textTheme.bodySmall?.copyWith(
          color: Theme.of(context).colorScheme.onSurfaceVariant,
        ),
      ),
    );
  }

  Widget _buildSessionHeader(ScanSession session) {
    final scheme = Theme.of(context).colorScheme;
    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  'Scan ${ScanStatus.label(session.status)}',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
              ),
              StatusBadge(
                label: ScanStatus.label(session.status),
                status: _sessionStatusOf(session.status),
              ),
            ],
          ),
          if (session.note != null && session.note!.isNotEmpty) ...[
            const SizedBox(height: AppSpacing.sm),
            Text(
              session.note!,
              style: Theme.of(
                context,
              ).textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
            ),
          ],
          const SizedBox(height: AppSpacing.sm),
          Row(
            children: [
              Icon(
                Icons.photo_outlined,
                size: 14,
                color: scheme.onSurfaceVariant,
              ),
              const SizedBox(width: AppSpacing.xs),
              Text(
                '${session.imageCount} image(s) · Started ${AppFormat.relativeDate(session.createdAt)}',
                style: Theme.of(context).textTheme.labelSmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildSection({
    required String title,
    required IconData icon,
    required Widget child,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(icon, size: 18, color: Theme.of(context).colorScheme.primary),
            const SizedBox(width: AppSpacing.sm),
            Text(title, style: Theme.of(context).textTheme.titleSmall),
          ],
        ),
        const SizedBox(height: AppSpacing.sm),
        child,
      ],
    );
  }

  Widget _permissionNote(String message) {
    return AppCard(
      padding: const EdgeInsets.all(AppSpacing.md),
      child: Row(
        children: [
          Icon(
            Icons.lock_outline,
            size: 18,
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
          const SizedBox(width: AppSpacing.sm),
          Expanded(
            child: Text(
              message,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSuccess() {
    final session = _session;
    final scheme = Theme.of(context).colorScheme;

    // Prefer server-reported counts (from ConfirmScanResponse) for accuracy.
    final int affected;
    final String message;
    if (session != null && session.productsUpdated != null) {
      affected = session.productsUpdated!;
      final totalDet = session.totalDetections ?? 0;
      final unmatched = session.unmatchedDetections ?? 0;
      if (affected == 0 && totalDet > 0 && unmatched == totalDet) {
        message =
            '${session.imageCount} image(s) processed.\n'
            'No products were matched. Create products from detections first, then re-scan.';
      } else if (affected == 0 && totalDet > 0) {
        message =
            '${session.imageCount} image(s) processed.\n'
            'All matched products already had the correct quantity.';
      } else {
        message =
            '${session.imageCount} image(s) processed · $affected product(s) updated.';
      }
    } else {
      // Fallback to client-side count (legacy responses).
      affected = _reconciliations
          .where((r) => r.hasVariance && !r.isIgnored)
          .length;
      message =
          '${session?.imageCount ?? 0} image(s) processed · $affected product(s) updated.';
    }
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.xl),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.check_circle, size: 64, color: AppColors.success),
            const SizedBox(height: AppSpacing.lg),
            Text(
              'Scan confirmed',
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const SizedBox(height: AppSpacing.sm),
            Text(
              session == null ? _successMessage : message,
              textAlign: TextAlign.center,
              style: Theme.of(
                context,
              ).textTheme.bodyMedium?.copyWith(color: scheme.onSurfaceVariant),
            ),
            const SizedBox(height: AppSpacing.xl),
            AppButton(
              key: const ValueKey('done-button'),
              label: 'Done',
              icon: Icons.check,
              expand: false,
              onPressed: () => Navigator.of(context).pop(true),
            ),
          ],
        ),
      ),
    );
  }

  AppStatus _sessionStatusOf(String status) => switch (status) {
    ScanStatus.completed => AppStatus.success,
    ScanStatus.confirmed => AppStatus.success,
    ScanStatus.needsReview => AppStatus.warning,
    ScanStatus.processing => AppStatus.info,
    ScanStatus.cancelled => AppStatus.neutral,
    ScanStatus.failed => AppStatus.error,
    _ => AppStatus.neutral,
  };
}

class _DetectionTile extends StatelessWidget {
  const _DetectionTile({required this.detection, this.onCreateProduct});

  final ScanDetection detection;
  final VoidCallback? onCreateProduct;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final subtitle = _buildSubtitle();
    return AppCard(
      padding: const EdgeInsets.all(AppSpacing.md),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      detection.referenceLabel,
                      style: Theme.of(context).textTheme.bodyLarge,
                    ),
                    if (subtitle.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(top: AppSpacing.xs),
                        child: Text(
                          subtitle,
                          style: Theme.of(context).textTheme.labelSmall?.copyWith(
                            color: scheme.onSurfaceVariant,
                          ),
                        ),
                      ),
                  ],
                ),
              ),
              const SizedBox(width: AppSpacing.sm),
              StatusBadge(
                label: DetectionStatus.label(detection.status),
                status: detection.isAccepted
                    ? AppStatus.success
                    : AppStatus.warning,
              ),
            ],
          ),
          if (detection.isUnmatched && onCreateProduct != null) ...[
            const SizedBox(height: AppSpacing.sm),
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                key: ValueKey('create-product-${detection.id}'),
                onPressed: onCreateProduct,
                icon: const Icon(Icons.add_circle_outline, size: 18),
                label: const Text('Create Product from Detection'),
              ),
            ),
          ],
        ],
      ),
    );
  }

  String _buildSubtitle() {
    final parts = <String>[];
    parts.add(DetectionMethod.label(detection.method));
    parts.add('${AppFormat.qty(detection.quantityDetected)} unit(s)');
    if (detection.confidence != null) {
      parts.add('${(detection.confidence! * 100).round()}% conf.');
    }
    if (detection.metaBrand != null && detection.metaBrand!.isNotEmpty) {
      parts.add(detection.metaBrand!);
    }
    if (detection.metaCategory != null && detection.metaCategory!.isNotEmpty) {
      parts.add(detection.metaCategory!);
    }
    return parts.join(' · ');
  }
}

class _ReconciliationTile extends StatelessWidget {
  const _ReconciliationTile({
    required this.reconciliation,
    required this.overridden,
    required this.canReview,
    required this.onOverride,
    required this.onIgnore,
  });

  final ScanReconciliation reconciliation;
  final bool overridden;
  final bool canReview;
  final VoidCallback onOverride;
  final VoidCallback onIgnore;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final badge = switch (reconciliation.status) {
      ReconciliationStatus.applied => (
        ReconciliationStatus.label(reconciliation.status),
        AppStatus.success,
      ),
      ReconciliationStatus.needsReview => (
        reconciliation.isIgnored
            ? 'Ignored'
            : overridden
            ? 'Overridden'
            : ReconciliationStatus.label(reconciliation.status),
        reconciliation.isIgnored
            ? AppStatus.neutral
            : overridden
            ? AppStatus.info
            : AppStatus.warning,
      ),
      _ => (
        ReconciliationStatus.label(reconciliation.status),
        AppStatus.neutral,
      ),
    };
    return AppCard(
      padding: const EdgeInsets.all(AppSpacing.md),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      reconciliation.productName,
                      style: Theme.of(context).textTheme.bodyLarge,
                    ),
                    Text(
                      reconciliation.sku,
                      style: Theme.of(context).textTheme.labelSmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              StatusBadge(label: badge.$1, status: badge.$2),
            ],
          ),
          const SizedBox(height: AppSpacing.sm),
          Row(
            children: [
              Expanded(
                child: _Metric(
                  label: 'Detected',
                  value: AppFormat.qty(reconciliation.detectedQuantity),
                ),
              ),
              Expanded(
                child: _Metric(
                  label: 'System',
                  value: AppFormat.qty(reconciliation.systemQuantity),
                ),
              ),
              Expanded(
                child: _Metric(
                  label: 'Variance',
                  value: _signed(reconciliation.variance),
                  emphasized: reconciliation.hasVariance,
                ),
              ),
            ],
          ),
          if (canReview) ...[
            const SizedBox(height: AppSpacing.md),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    key: ValueKey('override-${reconciliation.id}'),
                    onPressed: onOverride,
                    icon: const Icon(Icons.edit_outlined, size: 18),
                    label: const Text('Override quantity'),
                  ),
                ),
                const SizedBox(width: AppSpacing.sm),
                Expanded(
                  child: OutlinedButton.icon(
                    key: ValueKey('ignore-${reconciliation.id}'),
                    onPressed: onIgnore,
                    icon: const Icon(Icons.block_outlined, size: 18),
                    label: const Text('Ignore'),
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  String _signed(double value) => value > 0
      ? '+${AppFormat.qty(value)}'
      : (value < 0 ? AppFormat.qty(value) : AppFormat.qty(0));
}

/// Small editor for the counted quantity of one reconciliation row. Client-side
/// validation is UX only — the server independently rejects negative /
/// malformed quantities.
class _QuantityOverrideDialog extends StatefulWidget {
  const _QuantityOverrideDialog({required this.initial});

  final double initial;

  @override
  State<_QuantityOverrideDialog> createState() =>
      _QuantityOverrideDialogState();
}

class _QuantityOverrideDialogState extends State<_QuantityOverrideDialog> {
  late final TextEditingController _controller;
  String? _error;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: AppFormat.qty(widget.initial));
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _save() {
    final text = _controller.text.trim();
    if (text.isEmpty) {
      setState(() => _error = 'Enter the counted quantity.');
      return;
    }
    final value = double.tryParse(text);
    if (value == null || value.isNaN || value.isInfinite) {
      setState(() => _error = 'Enter a valid number.');
      return;
    }
    if (value < 0) {
      setState(() => _error = 'Quantity cannot be negative.');
      return;
    }
    Navigator.of(context).pop(value);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return AlertDialog(
      title: const Text('Override quantity'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'System quantity is ${AppFormat.qty(widget.initial)}. Enter the quantity counted on the shelf.',
            style: Theme.of(
              context,
            ).textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
          ),
          const SizedBox(height: AppSpacing.md),
          TextField(
            key: const ValueKey('override-quantity-field'),
            controller: _controller,
            autofocus: true,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: InputDecoration(
              labelText: 'Counted quantity',
              errorText: _error,
              border: const OutlineInputBorder(),
            ),
            onSubmitted: (_) => _save(),
          ),
        ],
      ),
      actions: [
        TextButton(
          key: const ValueKey('override-cancel'),
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          key: const ValueKey('override-save'),
          onPressed: _save,
          child: const Text('Save'),
        ),
      ],
    );
  }
}

class _Metric extends StatelessWidget {
  const _Metric({
    required this.label,
    required this.value,
    this.emphasized = false,
  });

  final String label;
  final String value;
  final bool emphasized;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: Theme.of(context).textTheme.labelSmall?.copyWith(
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
        ),
        Text(
          value,
          style: emphasized
              ? Theme.of(
                  context,
                ).textTheme.titleSmall?.copyWith(color: AppColors.warning)
              : Theme.of(context).textTheme.titleSmall,
        ),
      ],
    );
  }
}
