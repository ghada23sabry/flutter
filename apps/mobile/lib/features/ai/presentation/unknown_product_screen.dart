/// Flow D — Unknown product review and creation.
///
/// Shown when barcode lookup and AI visual/name matching both fail to resolve
/// a detected product.  The user can review the detected information and
/// create a new product in the catalog.
///
/// Enhanced with:
/// - Multi-source external product discovery (provider-based architecture)
/// - Candidate selection with source attribution and match reasons
/// - Category intelligence: match existing or suggest new with inline creation
/// - Supplier picker with inline creation (no leaving the flow)
/// - Discovery confidence with overall score
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
  late final TextEditingController _brandCtrl;
  late final TextEditingController _variantCtrl;
  late final TextEditingController _descCtrl;
  late final TextEditingController _unitCtrl;
  late final TextEditingController _priceCtrl;
  late final TextEditingController _sizeCtrl;
  late final TextEditingController _weightCtrl;
  late final TextEditingController _volumeCtrl;

  // Inline category creation
  late final TextEditingController _newCategoryCtrl;
  bool _showNewCategory = false;

  // Inline supplier creation
  late final TextEditingController _newSupplierNameCtrl;
  late final TextEditingController _newSupplierContactCtrl;
  late final TextEditingController _newSupplierPhoneCtrl;
  bool _showNewSupplier = false;

  bool _saving = false;
  bool _discovering = false;
  String? _error;

  List<ProductCandidate> _candidates = [];
  String? _selectedCategoryId;
  String? _selectedSupplierId;
  DiscoveryResult? _discoveryResult;

  List<Category> _categories = [];
  bool _categoriesLoading = false;
  List<Supplier> _suppliers = [];
  bool _suppliersLoading = false;

  // Category suggestion from backend
  CategorySuggestion? _categorySuggestion;
  bool _showCategorySuggestion = false;

  @override
  void initState() {
    super.initState();
    final d = widget.detected;
    _nameCtrl = TextEditingController(text: d.name);
    _barcodeCtrl = TextEditingController(text: d.barcode ?? '');
    _skuCtrl = TextEditingController(text: d.sku ?? '');
    _brandCtrl = TextEditingController(text: d.brand ?? '');
    _variantCtrl = TextEditingController(text: d.variant ?? '');
    _descCtrl = TextEditingController(text: d.description ?? '');
    _unitCtrl = TextEditingController(text: 'pcs');
    _priceCtrl = TextEditingController(text: d.sellingPrice ?? '0.00');
    _sizeCtrl = TextEditingController(text: d.size ?? '');
    _weightCtrl = TextEditingController(text: d.weight ?? '');
    _volumeCtrl = TextEditingController(text: d.volume ?? '');

    _newCategoryCtrl = TextEditingController();
    _newSupplierNameCtrl = TextEditingController();
    _newSupplierContactCtrl = TextEditingController();
    _newSupplierPhoneCtrl = TextEditingController();

    _loadCategories();
    _loadSuppliers();
    _discoverProducts();
  }

  Future<void> _loadCategories() async {
    setState(() => _categoriesLoading = true);
    try {
      final cats = await widget.catalogApi.listCategories(
        store: widget.store,
        status: 'active',
      );
      if (!mounted) return;
      setState(() {
        _categories = cats;
        _categoriesLoading = false;
      });
    } catch (_) {
      if (mounted) setState(() => _categoriesLoading = false);
    }
  }

  Future<void> _loadSuppliers() async {
    setState(() => _suppliersLoading = true);
    try {
      final page = await widget.catalogApi.listSuppliers(status: 'active');
      if (!mounted) return;
      setState(() {
        _suppliers = page.items;
        _suppliersLoading = false;
      });
    } catch (_) {
      if (mounted) setState(() => _suppliersLoading = false);
    }
  }

  Future<void> _discoverProducts() async {
    final d = widget.detected;
    final hasInfo = (d.name.isNotEmpty) ||
        (d.brand != null && d.brand!.isNotEmpty) ||
        (d.barcode != null && d.barcode!.isNotEmpty);
    if (!hasInfo) return;

    setState(() => _discovering = true);
    try {
      final result = await widget.catalogApi.discoverProducts(
        store: widget.store,
        query: [d.brand, d.name].where((e) => e != null && e.isNotEmpty).join(' '),
        barcode: d.barcode,
        brand: d.brand,
        category: d.category,
        ocrText: null,
        variant: d.variant,
        modelName: d.modelName,
      );
      if (!mounted) return;
      setState(() {
        _discoveryResult = result;
        _candidates = result.candidates;
        _categorySuggestion = result.categorySuggestion;
        _discovering = false;
      });
      // Auto-apply category suggestion if no existing category is selected
      if (_categorySuggestion != null &&
          _categorySuggestion!.source == 'existing' &&
          _selectedCategoryId == null) {
        _applyCategorySuggestion(_categorySuggestion!);
      }
      // Show suggestion banner if it's a new category
      if (_categorySuggestion != null &&
          _categorySuggestion!.source == 'suggested') {
        setState(() => _showCategorySuggestion = true);
      }
    } catch (_) {
      if (mounted) setState(() => _discovering = false);
    }
  }

  void _applyCandidate(ProductCandidate c) {
    setState(() {
      if (c.name.isNotEmpty) _nameCtrl.text = c.name;
      if (c.brand != null && c.brand!.isNotEmpty) _brandCtrl.text = c.brand!;
      if (c.barcode != null && c.barcode!.isNotEmpty) {
        _barcodeCtrl.text = c.barcode!;
      }
      if (c.description != null && c.description!.isNotEmpty) {
        _descCtrl.text = c.description!;
      }
      if (c.size != null && c.size!.isNotEmpty) _sizeCtrl.text = c.size!;
      if (c.weight != null && c.weight!.isNotEmpty) {
        _weightCtrl.text = c.weight!;
      }
      if (c.volume != null && c.volume!.isNotEmpty) {
        _volumeCtrl.text = c.volume!;
      }
      if (c.variant != null && c.variant!.isNotEmpty) {
        _variantCtrl.text = c.variant!;
      }
      if (c.category != null && c.category!.isNotEmpty) {
        _matchCategory(c.category!);
      }
      _candidates = [];
    });
  }

  void _matchCategory(String categoryName) {
    final lower = categoryName.toLowerCase();
    for (final cat in _categories) {
      if (cat.name.toLowerCase().contains(lower) ||
          lower.contains(cat.name.toLowerCase())) {
        _selectedCategoryId = cat.id;
        return;
      }
    }
  }

  void _applyCategorySuggestion(CategorySuggestion suggestion) {
    for (final cat in _categories) {
      if (cat.name.toLowerCase() == suggestion.name.toLowerCase()) {
        _selectedCategoryId = cat.id;
        return;
      }
    }
  }

  Future<void> _createInlineCategory() async {
    final name = _newCategoryCtrl.text.trim();
    if (name.isEmpty) return;

    setState(() => _error = null);
    try {
      final category = await widget.catalogApi.createCategory(
        store: widget.store,
        input: CategoryInput(name: name),
      );
      if (!mounted) return;
      await _loadCategories();
      if (!mounted) return;
      setState(() {
        _selectedCategoryId = category.id;
        _showNewCategory = false;
        _newCategoryCtrl.clear();
      });
    } catch (e) {
      if (mounted) {
        setState(() => _error = 'Failed to create category: $e');
      }
    }
  }

  Future<void> _createInlineSupplier() async {
    final name = _newSupplierNameCtrl.text.trim();
    if (name.isEmpty) return;

    setState(() => _error = null);
    try {
      final supplier = await widget.catalogApi.createSupplier(
        input: SupplierInput(
          name: name,
          contactName: _newSupplierContactCtrl.text.trim().isNotEmpty
              ? _newSupplierContactCtrl.text.trim()
              : null,
          phone: _newSupplierPhoneCtrl.text.trim().isNotEmpty
              ? _newSupplierPhoneCtrl.text.trim()
              : null,
        ),
      );
      if (!mounted) return;
      await _loadSuppliers();
      if (!mounted) return;
      setState(() {
        _selectedSupplierId = supplier.id;
        _showNewSupplier = false;
        _newSupplierNameCtrl.clear();
        _newSupplierContactCtrl.clear();
        _newSupplierPhoneCtrl.clear();
      });
    } catch (e) {
      if (mounted) {
        setState(() => _error = 'Failed to create supplier: $e');
      }
    }
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    _barcodeCtrl.dispose();
    _skuCtrl.dispose();
    _brandCtrl.dispose();
    _variantCtrl.dispose();
    _descCtrl.dispose();
    _unitCtrl.dispose();
    _priceCtrl.dispose();
    _sizeCtrl.dispose();
    _weightCtrl.dispose();
    _volumeCtrl.dispose();
    _newCategoryCtrl.dispose();
    _newSupplierNameCtrl.dispose();
    _newSupplierContactCtrl.dispose();
    _newSupplierPhoneCtrl.dispose();
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
          categoryId: _selectedCategoryId,
          size: size.isNotEmpty ? size : null,
          weight: weight.isNotEmpty ? weight : null,
          volume: volume.isNotEmpty ? volume : null,
          sellingPrice: price,
          description: _descCtrl.text.trim().isNotEmpty
              ? _descCtrl.text.trim()
              : null,
        ),
      );

      if (_selectedSupplierId != null && mounted) {
        try {
          await widget.catalogApi.linkProductToSupplier(
            store: widget.store,
            supplierId: _selectedSupplierId!,
            productId: product.id,
          );
        } catch (_) {
          // Supplier linking is best-effort.
        }
      }

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
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: const Text('Unknown Product')),
      body: ListView(
        padding: const EdgeInsets.all(AppSpacing.lg),
        children: [
          _buildStatusBanner(scheme),
          if (_showCategorySuggestion && _categorySuggestion != null) ...[
            const SizedBox(height: AppSpacing.lg),
            _buildCategorySuggestionBanner(scheme),
          ],
          if (_candidates.isNotEmpty) ...[
            const SizedBox(height: AppSpacing.lg),
            _buildDiscoverySection(scheme),
          ],
          if (_discovering && _candidates.isEmpty) ...[
            const SizedBox(height: AppSpacing.lg),
            _buildDiscoveringIndicator(scheme),
          ],
          const SizedBox(height: AppSpacing.lg),
          _buildField(_nameCtrl, 'Product Name *', Icons.label_outline),
          _buildField(_barcodeCtrl, 'Barcode', Icons.qr_code_scanner),
          _buildField(_skuCtrl, 'SKU (auto-generated if empty)', Icons.inventory_2_outlined),
          _buildField(_brandCtrl, 'Brand', Icons.branding_watermark_outlined),
          _buildField(_variantCtrl, 'Variant', Icons.tune),
          _buildCategoryPicker(scheme),
          _buildSupplierPicker(scheme),
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
                child: _buildField(_sizeCtrl, 'Size', Icons.aspect_ratio),
              ),
              const SizedBox(width: AppSpacing.md),
              Expanded(
                child: _buildField(_weightCtrl, 'Weight', Icons.scale),
              ),
            ],
          ),
          _buildField(_volumeCtrl, 'Volume', Icons.water_drop_outlined),
          _buildField(_descCtrl, 'Description', Icons.description_outlined, maxLines: 3),
          if (_error != null) ...[
            const SizedBox(height: AppSpacing.md),
            Text(
              _error!,
              style: TextStyle(
                color: scheme.error,
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
                  onPressed: _saving ? null : () => Navigator.of(context).pop(),
                ),
              ),
              const SizedBox(width: AppSpacing.md),
              Expanded(
                child: AppButton(
                  label: _saving ? 'Creating\u2026' : 'Create Product',
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

  Widget _buildStatusBanner(ColorScheme scheme) {
    final hasCandidates = _candidates.isNotEmpty;
    final isDiscovering = _discovering;
    return AppCard(
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.lg),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  isDiscovering
                      ? Icons.sync
                      : hasCandidates
                          ? Icons.auto_awesome
                          : Icons.help_outline,
                  color: isDiscovering
                      ? Colors.blue
                      : hasCandidates
                          ? scheme.primary
                          : Colors.orange,
                ),
                const SizedBox(width: AppSpacing.sm),
                Expanded(
                  child: Text(
                    isDiscovering
                        ? 'Searching product databases\u2026'
                        : hasCandidates
                            ? (_discoveryResult?.hasConfidentMatch ?? false)
                                ? 'Found a confident match. Tap to pre-fill, or choose another below.'
                                : 'Found ${_candidates.length} possible match(es). Review and tap one to pre-fill, or fill manually.'
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
    );
  }

  Widget _buildCategorySuggestionBanner(ColorScheme scheme) {
    final suggestion = _categorySuggestion!;
    return AppCard(
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.md),
        child: Row(
          children: [
            Icon(Icons.lightbulb_outline, color: Colors.amber[700], size: 20),
            const SizedBox(width: AppSpacing.sm),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Suggested category: ${suggestion.name}',
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                          fontWeight: FontWeight.w600,
                        ),
                  ),
                  Text(
                    'Tap to create this category, or choose an existing one below.',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: scheme.onSurfaceVariant,
                        ),
                  ),
                ],
              ),
            ),
            TextButton(
              onPressed: () async {
                await _createInlineCategoryWithName(suggestion.name);
                if (mounted) setState(() => _showCategorySuggestion = false);
              },
              child: const Text('Create'),
            ),
            IconButton(
              icon: const Icon(Icons.close, size: 18),
              onPressed: () => setState(() => _showCategorySuggestion = false),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _createInlineCategoryWithName(String name) async {
    setState(() => _error = null);
    try {
      final category = await widget.catalogApi.createCategory(
        store: widget.store,
        input: CategoryInput(name: name),
      );
      if (!mounted) return;
      await _loadCategories();
      if (!mounted) return;
      setState(() => _selectedCategoryId = category.id);
    } catch (e) {
      if (mounted) {
        setState(() => _error = 'Failed to create category: $e');
      }
    }
  }

  Widget _buildDiscoveringIndicator(ColorScheme scheme) {
    return AppCard(
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.md),
        child: Row(
          children: [
            SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(strokeWidth: 2, color: scheme.primary),
            ),
            const SizedBox(width: AppSpacing.md),
            Text(
              'Searching product databases\u2026',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildDiscoverySection(ColorScheme scheme) {
    final result = _discoveryResult;
    final hasConfident = result?.hasConfidentMatch ?? false;
    final bestMatch = _candidates.isNotEmpty ? _candidates.first : null;
    final otherMatches = _candidates.length > 1 ? _candidates.sublist(1) : <ProductCandidate>[];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (hasConfident && bestMatch != null) ...[
          Text(
            'Best Match',
            style: Theme.of(context).textTheme.titleSmall?.copyWith(
                  color: scheme.primary,
                  fontWeight: FontWeight.w600,
                ),
          ),
          const SizedBox(height: AppSpacing.sm),
          _buildCandidateCard(scheme, bestMatch, isBest: true),
        ],
        if (!hasConfident && _candidates.isNotEmpty) ...[
          Container(
            padding: const EdgeInsets.all(AppSpacing.sm),
            decoration: BoxDecoration(
              color: scheme.errorContainer.withValues(alpha: 0.3),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Row(
              children: [
                Icon(Icons.warning_amber_rounded, size: 16, color: scheme.error),
                const SizedBox(width: AppSpacing.xs),
                Expanded(
                  child: Text(
                    'No confident match found. Please review and select the best option below.',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(color: scheme.error),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: AppSpacing.sm),
          Text(
            'Possible Matches',
            style: Theme.of(context).textTheme.titleSmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
          ),
          const SizedBox(height: AppSpacing.sm),
          for (final c in _candidates)
            Padding(
              padding: const EdgeInsets.only(bottom: AppSpacing.sm),
              child: _buildCandidateCard(scheme, c),
            ),
        ],
        if (hasConfident && otherMatches.isNotEmpty) ...[
          const SizedBox(height: AppSpacing.md),
          Text(
            'Other Matches',
            style: Theme.of(context).textTheme.titleSmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
          ),
          const SizedBox(height: AppSpacing.sm),
          for (final c in otherMatches)
            Padding(
              padding: const EdgeInsets.only(bottom: AppSpacing.sm),
              child: _buildCandidateCard(scheme, c),
            ),
        ],
      ],
    );
  }

  Widget _buildCandidateCard(ColorScheme scheme, ProductCandidate c, {bool isBest = false}) {
    return AppCard(
      onTap: () => _applyCandidate(c),
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.md),
        child: Row(
          children: [
            if (c.imageUrl != null)
              ClipRRect(
                borderRadius: BorderRadius.circular(6),
                child: Image.network(
                  c.imageUrl!,
                  width: isBest ? 56 : 40,
                  height: isBest ? 56 : 40,
                  fit: BoxFit.cover,
                  errorBuilder: (_, __, ___) => Icon(
                    Icons.image_not_supported_outlined,
                    size: isBest ? 56 : 40,
                  ),
                ),
              )
            else
              Icon(Icons.inventory_2_outlined, color: scheme.primary, size: isBest ? 28 : 20),
            const SizedBox(width: AppSpacing.md),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          c.name,
                          style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                                fontWeight: isBest ? FontWeight.w600 : null,
                              ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      if (c.sources.isNotEmpty)
                        Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            for (final s in c.sources.take(3))
                              Padding(
                                padding: const EdgeInsets.only(left: 4),
                                child: _SourceBadge(source: s),
                              ),
                          ],
                        ),
                    ],
                  ),
                  if (c.brand != null)
                    Text(
                      c.brand!,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                            color: scheme.onSurfaceVariant,
                          ),
                    ),
                  if (c.modelName != null && c.modelName!.isNotEmpty)
                    Text(
                      'Model: ${c.modelName}',
                      style: Theme.of(context).textTheme.labelSmall?.copyWith(
                            color: scheme.onSurfaceVariant,
                            fontFamily: 'monospace',
                          ),
                    ),
                  if (c.category != null)
                    Text(
                      c.category!,
                      style: Theme.of(context).textTheme.labelSmall?.copyWith(
                            color: scheme.onSurfaceVariant,
                          ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  if (c.matchReason.isNotEmpty)
                    Text(
                      c.matchReason,
                      style: Theme.of(context).textTheme.labelSmall?.copyWith(
                            color: scheme.primary,
                            fontStyle: FontStyle.italic,
                          ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                ],
              ),
            ),
            const SizedBox(width: AppSpacing.sm),
            Column(
              children: [
                Icon(
                  isBest ? Icons.star : Icons.arrow_forward_ios,
                  size: isBest ? 18 : 14,
                  color: scheme.primary,
                ),
                Text(
                  '${(c.confidence * 100).round()}%',
                  style: Theme.of(context).textTheme.labelSmall?.copyWith(
                        color: scheme.primary,
                        fontWeight: isBest ? FontWeight.w700 : null,
                      ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildCategoryPicker(ColorScheme scheme) {
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.md),
      child: Column(
        children: [
          DropdownButtonFormField<String>(
            initialValue: _selectedCategoryId,
            isExpanded: true,
            decoration: InputDecoration(
              labelText: 'Category',
              prefixIcon: const Icon(Icons.category_outlined, size: 20),
              border: const OutlineInputBorder(),
              isDense: true,
              suffixIcon: _categoriesLoading
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: Padding(
                        padding: EdgeInsets.all(12),
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                    )
                  : null,
            ),
            items: [
              for (final cat in _categories)
                DropdownMenuItem(value: cat.id, child: Text(cat.name)),
            ],
            onChanged: (value) => setState(() => _selectedCategoryId = value),
          ),
          if (_showNewCategory) ...[
            const SizedBox(height: AppSpacing.sm),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _newCategoryCtrl,
                    decoration: const InputDecoration(
                      hintText: 'New category name',
                      border: OutlineInputBorder(),
                      isDense: true,
                      prefixIcon: Icon(Icons.add, size: 20),
                    ),
                    autofocus: true,
                    onSubmitted: (_) => _createInlineCategory(),
                  ),
                ),
                const SizedBox(width: AppSpacing.sm),
                IconButton(
                  icon: const Icon(Icons.check, size: 20),
                  onPressed: _createInlineCategory,
                  color: scheme.primary,
                ),
                IconButton(
                  icon: const Icon(Icons.close, size: 20),
                  onPressed: () => setState(() {
                    _showNewCategory = false;
                    _newCategoryCtrl.clear();
                  }),
                ),
              ],
            ),
          ] else
            TextButton.icon(
              onPressed: () => setState(() => _showNewCategory = true),
              icon: const Icon(Icons.add, size: 16),
              label: const Text('New category'),
            ),
        ],
      ),
    );
  }

  Widget _buildSupplierPicker(ColorScheme scheme) {
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.md),
      child: Column(
        children: [
          DropdownButtonFormField<String>(
            initialValue: _selectedSupplierId,
            isExpanded: true,
            decoration: InputDecoration(
              labelText: 'Supplier (optional)',
              prefixIcon: const Icon(Icons.local_shipping_outlined, size: 20),
              border: const OutlineInputBorder(),
              isDense: true,
              suffixIcon: _suppliersLoading
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: Padding(
                        padding: EdgeInsets.all(12),
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                    )
                  : null,
            ),
            items: [
              for (final s in _suppliers)
                DropdownMenuItem(value: s.id, child: Text(s.name)),
            ],
            onChanged: (value) => setState(() => _selectedSupplierId = value),
          ),
          if (_showNewSupplier) ...[
            const SizedBox(height: AppSpacing.sm),
            _buildField(_newSupplierNameCtrl, 'Supplier Name *', Icons.business, key: const Key('new_supplier_name')),
            Row(
              children: [
                Expanded(
                  child: _buildField(_newSupplierContactCtrl, 'Contact', Icons.person, key: const Key('new_supplier_contact')),
                ),
                const SizedBox(width: AppSpacing.md),
                Expanded(
                  child: _buildField(_newSupplierPhoneCtrl, 'Phone', Icons.phone, key: const Key('new_supplier_phone')),
                ),
              ],
            ),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                TextButton(
                  onPressed: _createInlineSupplier,
                  child: const Text('Create Supplier'),
                ),
                TextButton(
                  onPressed: () => setState(() {
                    _showNewSupplier = false;
                    _newSupplierNameCtrl.clear();
                    _newSupplierContactCtrl.clear();
                    _newSupplierPhoneCtrl.clear();
                  }),
                  child: const Text('Cancel'),
                ),
              ],
            ),
          ] else
            TextButton.icon(
              onPressed: () => setState(() => _showNewSupplier = true),
              icon: const Icon(Icons.add, size: 16),
              label: const Text('New supplier'),
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
    Key? key,
  }) {
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.md),
      child: TextField(
        key: key,
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

/// Small badge showing the data source of a discovery candidate.
class _SourceBadge extends StatelessWidget {
  const _SourceBadge({required this.source});

  final String source;

  @override
  Widget build(BuildContext context) {
    final label = _sourceLabel(source);
    final color = _sourceColor(source);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(3),
        border: Border.all(color: color.withValues(alpha: 0.3)),
      ),
      child: Text(
        label,
        style: Theme.of(context).textTheme.labelSmall?.copyWith(
              color: color,
              fontWeight: FontWeight.w600,
              fontSize: 8,
            ),
      ),
    );
  }

  String _sourceLabel(String source) {
    switch (source) {
      case 'open_food_facts':
        return 'OFF';
      case 'open_beauty_facts':
        return 'OBF';
      case 'general_product':
        return 'WIKI';
      case 'ai_detected':
        return 'AI';
      case 'user_entered':
        return 'Manual';
      default:
        return source.length > 6 ? source.substring(0, 6) : source;
    }
  }

  Color _sourceColor(String source) {
    switch (source) {
      case 'open_food_facts':
        return Colors.green;
      case 'open_beauty_facts':
        return Colors.purple;
      case 'general_product':
        return Colors.blue;
      case 'ai_detected':
        return Colors.teal;
      case 'user_entered':
        return Colors.orange;
      default:
        return Colors.grey;
    }
  }
}
