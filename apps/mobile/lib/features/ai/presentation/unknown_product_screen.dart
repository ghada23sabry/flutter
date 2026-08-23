/// Flow D — Unknown product review and creation.
///
/// Shown when barcode lookup and AI visual/name matching both fail to resolve
/// a detected product.  The user can review the detected information and
/// create a new product from it.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../core/models/auth_models.dart';
import '../../../core/theme/app_tokens.dart';
import '../../../core/widgets/app_button.dart';
import '../../../core/widgets/app_card.dart';
import '../../catalog/data/catalog_api.dart';
import '../../catalog/data/catalog_models.dart';

/// Pre-filled fields detected by the AI vision model (or barcode scan).
class UnknownProductData {
  const UnknownProductData({
    this.name = '',
    this.barcode,
    this.sku,
    this.category,
    this.brand,
    this.variant,
    this.modelName,
    this.description,
    this.size,
    this.weight,
    this.volume,
    this.sellingPrice,
    this.detectedQuantity,
  });

  final String name;
  final String? barcode;
  final String? sku;
  final String? category;
  final String? brand;
  final String? variant;
  final String? modelName;
  final String? description;
  final String? size;
  final String? weight;
  final String? volume;
  final String? sellingPrice;
  final double? detectedQuantity;
}

/// Result returned when the user creates a product.
class UnknownProductCreated {
  const UnknownProductCreated({required this.product});

  final Product product;
}

/// Screen that displays detected-but-unresolved product information and
/// lets the user review, complete, and create the product in the catalog.
class UnknownProductScreen extends StatefulWidget {
  const UnknownProductScreen({
    super.key,
    required this.catalogApi,
    required this.store,
    required this.detected,
  });

  final CatalogApi catalogApi;
  final StoreInfo store;
  final UnknownProductData detected;

  @override
  State<UnknownProductScreen> createState() => _UnknownProductScreenState();
}

class _UnknownProductScreenState extends State<UnknownProductScreen> {
  late final TextEditingController _nameCtrl;
  late final TextEditingController _barcodeCtrl;
  late final TextEditingController _skuCtrl;
  late final TextEditingController _categoryCtrl;
  late final TextEditingController _brandCtrl;
  late final TextEditingController _variantCtrl;
  late final TextEditingController _descCtrl;
  late final TextEditingController _unitCtrl;
  late final TextEditingController _priceCtrl;
  late final TextEditingController _sizeCtrl;
  late final TextEditingController _weightCtrl;
  late final TextEditingController _volumeCtrl;

  bool _saving = false;
  bool _enriching = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    final d = widget.detected;
    _nameCtrl = TextEditingController(text: d.name);
    _barcodeCtrl = TextEditingController(text: d.barcode ?? '');
    _skuCtrl = TextEditingController(text: d.sku ?? '');
    _categoryCtrl = TextEditingController(text: d.category ?? '');
    _brandCtrl = TextEditingController(text: d.brand ?? '');
    _variantCtrl = TextEditingController(text: d.variant ?? '');
    _descCtrl = TextEditingController(text: d.description ?? '');
    _unitCtrl = TextEditingController(text: 'pcs');
    _priceCtrl = TextEditingController(text: d.sellingPrice ?? '0.00');
    _sizeCtrl = TextEditingController(text: d.size ?? '');
    _weightCtrl = TextEditingController(text: d.weight ?? '');
    _volumeCtrl = TextEditingController(text: d.volume ?? '');
    if (d.barcode != null && d.barcode!.isNotEmpty && d.name.isEmpty) {
      _enrichBarcode(d.barcode!);
    }
  }

  Future<void> _enrichBarcode(String barcode) async {
    setState(() => _enriching = true);
    try {
      final enrichment = await widget.catalogApi.enrichBarcode(
        store: widget.store,
        barcode: barcode,
      );
      if (enrichment != null && !enrichment.isEmpty && mounted) {
        setState(() {
          if (_nameCtrl.text.isEmpty && enrichment.name != null) {
            _nameCtrl.text = enrichment.name!;
          }
          if (_brandCtrl.text.isEmpty && enrichment.brand != null) {
            _brandCtrl.text = enrichment.brand!;
          }
          if (_categoryCtrl.text.isEmpty && enrichment.category != null) {
            _categoryCtrl.text = enrichment.category!;
          }
          if (_descCtrl.text.isEmpty && enrichment.description != null) {
            _descCtrl.text = enrichment.description!;
          }
        });
      }
    } catch (_) {
      // Enrichment is best-effort — ignore failures.
    } finally {
      if (mounted) setState(() => _enriching = false);
    }
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    _barcodeCtrl.dispose();
    _skuCtrl.dispose();
    _categoryCtrl.dispose();
    _brandCtrl.dispose();
    _variantCtrl.dispose();
    _descCtrl.dispose();
    _unitCtrl.dispose();
    _priceCtrl.dispose();
    _sizeCtrl.dispose();
    _weightCtrl.dispose();
    _volumeCtrl.dispose();
    super.dispose();
  }

  Future<void> _createProduct() async {
    final name = _nameCtrl.text.trim();
    if (name.isEmpty) {
      setState(() => _error = 'Product name is required.');
      return;
    }
    final unit = _unitCtrl.text.trim();
    if (unit.isEmpty) {
      setState(() => _error = 'Unit is required.');
      return;
    }

    final priceText = _priceCtrl.text.trim();
    final price = double.tryParse(priceText) ?? 0.0;
    if (price <= 0) {
      setState(() => _error = 'Selling price must be greater than zero.');
      return;
    }

    setState(() {
      _saving = true;
      _error = null;
    });

    try {
      final barcode = _barcodeCtrl.text.trim();
      final sku = _skuCtrl.text.trim();
      final size = _sizeCtrl.text.trim();
      final weight = _weightCtrl.text.trim();
      final volume = _volumeCtrl.text.trim();
      final product = await widget.catalogApi.createProduct(
        store: widget.store,
        input: ProductInput(
          name: name,
          brand: _brandCtrl.text.trim().isNotEmpty
              ? _brandCtrl.text.trim()
              : null,
          variant: _variantCtrl.text.trim().isNotEmpty
              ? _variantCtrl.text.trim()
              : null,
          sku: sku.isNotEmpty ? sku : null,
          barcode: barcode.isNotEmpty ? barcode : null,
          unit: unit,
          size: size.isNotEmpty ? size : null,
          weight: weight.isNotEmpty ? weight : null,
          volume: volume.isNotEmpty ? volume : null,
          sellingPrice: price,
          description: _descCtrl.text.trim().isNotEmpty
              ? _descCtrl.text.trim()
              : null,
        ),
      );
      if (!mounted) return;
      Navigator.of(context).pop(UnknownProductCreated(product: product));
    } catch (e) {
      if (mounted) {
        setState(() {
          _saving = false;
          _error = e.toString().contains('already exists')
              ? 'A product with this SKU or barcode already exists in this store.'
              : 'Failed to create product: $e';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Unknown Product')),
      body: ListView(
        padding: const EdgeInsets.all(AppSpacing.lg),
        children: [
          AppCard(
            child: Padding(
              padding: const EdgeInsets.all(AppSpacing.lg),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(
                        _enriching ? Icons.sync : Icons.help_outline,
                        color: _enriching ? Colors.blue : Colors.orange,
                      ),
                      const SizedBox(width: AppSpacing.sm),
                      Expanded(
                        child: Text(
                          _enriching
                              ? 'Looking up product information…'
                              : 'This product was not found in your catalog. '
                                  'Review the detected information and create it.',
                          style: Theme.of(context).textTheme.bodyMedium,
                        ),
                      ),
                    ],
                  ),
                  if (widget.detected.detectedQuantity != null) ...[
                    const SizedBox(height: AppSpacing.md),
                    Text(
                      'Detected quantity: ${widget.detected.detectedQuantity!.toStringAsFixed(0)}',
                      style: Theme.of(context).textTheme.labelMedium,
                    ),
                  ],
                ],
              ),
            ),
          ),
          const SizedBox(height: AppSpacing.lg),
          _buildField(_nameCtrl, 'Product Name *', Icons.label_outline),
          _buildField(_barcodeCtrl, 'Barcode', Icons.qr_code_scanner),
          _buildField(_skuCtrl, 'SKU (auto-generated if empty)', Icons.inventory_2_outlined),
          _buildField(_brandCtrl, 'Brand', Icons.branding_watermark_outlined),
          _buildField(_variantCtrl, 'Variant', Icons.tune),
          _buildField(_categoryCtrl, 'Category', Icons.category_outlined),
          _buildField(_unitCtrl, 'Unit *', Icons.straighten),
          _buildField(
            _priceCtrl,
            'Selling Price *',
            Icons.attach_money,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
          ),
          Row(
            children: [
              Expanded(
                child: _buildField(
                  _sizeCtrl,
                  'Size',
                  Icons.aspect_ratio,
                ),
              ),
              const SizedBox(width: AppSpacing.md),
              Expanded(
                child: _buildField(
                  _weightCtrl,
                  'Weight',
                  Icons.scale,
                ),
              ),
            ],
          ),
          _buildField(_volumeCtrl, 'Volume', Icons.water_drop_outlined),
          _buildField(
            _descCtrl,
            'Description',
            Icons.description_outlined,
            maxLines: 3,
          ),
          if (_error != null) ...[
            const SizedBox(height: AppSpacing.md),
            Text(
              _error!,
              style: TextStyle(
                color: Theme.of(context).colorScheme.error,
                fontSize: 13,
              ),
            ),
          ],
          const SizedBox(height: AppSpacing.xl),
          Row(
            children: [
              Expanded(
                child: AppButton(
                  label: 'Cancel',
                  icon: Icons.close,
                  expand: false,
                  onPressed:
                      _saving ? null : () => Navigator.of(context).pop(),
                ),
              ),
              const SizedBox(width: AppSpacing.md),
              Expanded(
                child: AppButton(
                  label: _saving ? 'Creating…' : 'Create Product',
                  icon: Icons.add,
                  expand: false,
                  onPressed: _saving ? null : _createProduct,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildField(
    TextEditingController ctrl,
    String label,
    IconData icon, {
    int maxLines = 1,
    TextInputType? keyboardType,
  }) {
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.md),
      child: TextField(
        controller: ctrl,
        maxLines: maxLines,
        keyboardType: keyboardType,
        inputFormatters: keyboardType != null
            ? [FilteringTextInputFormatter.allow(RegExp(r'[\d.]'))]
            : null,
        decoration: InputDecoration(
          labelText: label,
          prefixIcon: Icon(icon, size: 20),
          border: const OutlineInputBorder(),
          isDense: true,
        ),
      ),
    );
  }
}
