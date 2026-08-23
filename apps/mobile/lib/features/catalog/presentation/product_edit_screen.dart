import 'package:flutter/material.dart';

import '../../../core/api_client.dart';
import '../../../core/barcode/barcode.dart';
import '../../../core/models/auth_models.dart';
import '../../../core/session.dart';
import '../../../core/theme/app_tokens.dart';
import '../../../core/widgets/app_button.dart';
import '../../../core/widgets/app_card.dart';
import '../../../core/widgets/app_input.dart';
import '../../inventory/data/inventory_api.dart';
import '../data/catalog_api.dart';
import '../data/catalog_models.dart';
import 'barcode_entry_sheet.dart';
import 'category_edit_screen.dart';

/// Create or edit a product. In edit mode [existing] is non-null.
class ProductEditScreen extends StatefulWidget {
  const ProductEditScreen({
    super.key,
    required this.api,
    required this.session,
    this.inventoryApi,
    this.existing,
    this.initialBarcode,
  });

  final CatalogApi api;
  final SessionController session;
  final InventoryApi? inventoryApi;
  final Product? existing;
  final String? initialBarcode;

  @override
  State<ProductEditScreen> createState() => _ProductEditScreenState();
}

class _ProductEditScreenState extends State<ProductEditScreen> {
  final _formKey = GlobalKey<FormState>();

  late final TextEditingController _name;
  late final TextEditingController _sku;
  late final TextEditingController _barcode;
  late final TextEditingController _description;
  late final TextEditingController _unit;
  late final TextEditingController _cost;
  late final TextEditingController _selling;
  late final TextEditingController _reorderPoint;
  late final TextEditingController _reorderQty;
  late final TextEditingController _imageUrl;
  late final TextEditingController _initialQty;
  late final TextEditingController _batchCode;
  late final TextEditingController _variant;
  late final TextEditingController _size;
  late final TextEditingController _weight;
  late final TextEditingController _volume;

  DateTime? _expiryDate;
  String? _categoryId;
  List<Category> _categories = [];
  bool _categoriesLoadFailed = false;
  bool _expiryTracking = false;
  bool _isActive = true;
  bool _submitting = false;
  String? _submitError;
  Product? _created;
  String? _stockError;

  bool get _isEditing => widget.existing != null;

  StoreInfo get _store => widget.session.selectedStore!;

  InventoryApi get _inventoryApi =>
      widget.inventoryApi ?? InventoryApi(widget.session.apiClient);

  @override
  void initState() {
    super.initState();
    final p = widget.existing;
    _name = TextEditingController(text: p?.name ?? '');
    _sku = TextEditingController(text: p?.sku ?? '');
    _barcode = TextEditingController(text: p?.barcode ?? '');
    _description = TextEditingController(text: p?.description ?? '');
    _unit = TextEditingController(text: p?.unit ?? '');
    _cost = TextEditingController(text: _moneyInput(p?.costPrice ?? 0));
    _selling = TextEditingController(text: _moneyInput(p?.sellingPrice ?? 0));
    _reorderPoint = TextEditingController(
      text: _decimalInput(p?.reorderPoint ?? 0),
    );
    _reorderQty = TextEditingController(
      text: _decimalInput(p?.reorderQuantity ?? 0),
    );
    _imageUrl = TextEditingController(text: p?.imageUrl ?? '');
    _initialQty = TextEditingController(text: '0');
    _batchCode = TextEditingController();
    _variant = TextEditingController(text: p?.variant ?? '');
    _size = TextEditingController(text: p?.size ?? '');
    _weight = TextEditingController(text: p?.weight ?? '');
    _volume = TextEditingController(text: p?.volume ?? '');
    _categoryId = p?.categoryId;
    _expiryTracking = p?.expiryTrackingEnabled ?? false;
    _isActive = p?.isActive ?? true;
    if (widget.initialBarcode != null) {
      _barcode.text = normalizeBarcode(widget.initialBarcode!);
    }
    _loadCategories();
  }

  @override
  void dispose() {
    _name.dispose();
    _sku.dispose();
    _barcode.dispose();
    _description.dispose();
    _unit.dispose();
    _cost.dispose();
    _selling.dispose();
    _reorderPoint.dispose();
    _reorderQty.dispose();
    _imageUrl.dispose();
    _initialQty.dispose();
    _batchCode.dispose();
    _variant.dispose();
    _size.dispose();
    _weight.dispose();
    _volume.dispose();
    super.dispose();
  }

  String _moneyInput(double value) => value == value.roundToDouble()
      ? value.toStringAsFixed(0)
      : value.toString();

  String _decimalInput(double value) => value.toString();

  String? get _currentCategoryName {
    for (final c in _categories) {
      if (c.id == _categoryId) return c.name;
    }
    return widget.existing?.categoryName;
  }

  Future<void> _createCategoryInline() async {
    final created = await Navigator.of(context).push<Category>(
      MaterialPageRoute(
        fullscreenDialog: true,
        builder: (_) =>
            CategoryEditScreen(api: widget.api, session: widget.session),
      ),
    );
    if (created != null && mounted) {
      setState(() {
        if (!_categories.any((c) => c.id == created.id)) {
          _categories = [..._categories, created];
        }
        _categoryId = created.id;
      });
    }
  }

  Future<void> _loadCategories() async {
    try {
      final categories = await widget.api.listCategories(store: _store);
      if (mounted) {
        setState(() {
          _categories = categories;
          _categoriesLoadFailed = false;
        });
      }
    } catch (_) {
      // Category dropdown degrades to "none"; product save still works.
      if (mounted) setState(() => _categoriesLoadFailed = true);
    }
  }

  String? _required(String? value) {
    if (value == null || value.trim().isEmpty) return 'This field is required';
    return null;
  }

  String? _money(String? value) {
    final v = value?.trim().replaceAll(',', '');
    if (v == null || v.isEmpty) return 'This field is required';
    final parsed = double.tryParse(v);
    if (parsed == null) return 'Enter a valid amount';
    if (parsed < 0) return 'Must be zero or more';
    return null;
  }

  String? _decimal(String? value) {
    final v = value?.trim();
    if (v == null || v.isEmpty) return 'This field is required';
    final parsed = double.tryParse(v);
    if (parsed == null) return 'Enter a valid number';
    if (parsed < 0) return 'Must be zero or more';
    return null;
  }

  String? _initialQuantity(String? value) {
    final v = value?.trim().replaceAll(',', '');
    if (v == null || v.isEmpty) return null;
    final parsed = double.tryParse(v);
    if (parsed == null) return 'Enter a valid number';
    if (parsed < 0) return 'Must be zero or more';
    return null;
  }

  double _initialQtyValue() {
    final v = _initialQty.text.trim().replaceAll(',', '');
    if (v.isEmpty) return 0;
    return double.tryParse(v) ?? 0;
  }

  Future<void> _pickExpiry() async {
    final now = DateTime.now();
    final picked = await showDatePicker(
      context: context,
      initialDate: _expiryDate ?? now,
      firstDate: now,
      lastDate: now.add(const Duration(days: 1825)),
    );
    if (picked != null) setState(() => _expiryDate = picked);
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() {
      _submitting = true;
      _submitError = null;
      _stockError = null;
    });
    try {
      if (_isEditing) {
        final barcodeText = _barcode.text.trim();
        final update = ProductUpdate(
          categoryId: _categoryId,
          clearCategory:
              widget.existing!.categoryId != null && _categoryId == null,
          name: _name.text.trim(),
          sku: _sku.text.trim(),
          barcode: barcodeText.isEmpty ? null : barcodeText,
          clearBarcode: widget.existing!.barcode != null && barcodeText.isEmpty,
          description: _description.text.trim().isEmpty
              ? null
              : _description.text.trim(),
          unit: _unit.text.trim(),
          variant: _variant.text.trim().isEmpty ? null : _variant.text.trim(),
          size: _size.text.trim().isEmpty ? null : _size.text.trim(),
          weight: _weight.text.trim().isEmpty ? null : _weight.text.trim(),
          volume: _volume.text.trim().isEmpty ? null : _volume.text.trim(),
          costPrice: _parseMoney(_cost.text),
          sellingPrice: _parseMoney(_selling.text),
          reorderPoint: _parseMoney(_reorderPoint.text),
          reorderQuantity: _parseMoney(_reorderQty.text),
          expiryTrackingEnabled: _expiryTracking,
          imageUrl: _imageUrl.text.trim().isEmpty
              ? null
              : _imageUrl.text.trim(),
          status: _isActive ? 'active' : 'inactive',
        );
        final product = await widget.api.updateProduct(
          store: _store,
          id: widget.existing!.id,
          update: update,
        );
        if (mounted) Navigator.of(context).pop(product);
      } else {
        await _createWithOpening();
      }
    } on ApiException catch (e) {
      if (mounted) setState(() => _submitError = e.message);
    } catch (_) {
      if (mounted) {
        setState(
          () => _submitError =
              'Cannot reach the server. Check your connection and try again.',
        );
      }
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  ProductInput _productInput() => ProductInput(
    categoryId: _categoryId,
    name: _name.text.trim(),
    sku: _sku.text.trim().isEmpty ? null : _sku.text.trim(),
    barcode: _barcode.text.trim().isEmpty ? null : _barcode.text.trim(),
    description: _description.text.trim().isEmpty
        ? null
        : _description.text.trim(),
    unit: _unit.text.trim(),
    variant: _variant.text.trim().isEmpty ? null : _variant.text.trim(),
    size: _size.text.trim().isEmpty ? null : _size.text.trim(),
    weight: _weight.text.trim().isEmpty ? null : _weight.text.trim(),
    volume: _volume.text.trim().isEmpty ? null : _volume.text.trim(),
    costPrice: _parseMoney(_cost.text),
    sellingPrice: _parseMoney(_selling.text)!,
    reorderPoint: _parseMoney(_reorderPoint.text),
    reorderQuantity: _parseMoney(_reorderQty.text),
    expiryTrackingEnabled: _expiryTracking,
    imageUrl: _imageUrl.text.trim().isEmpty ? null : _imageUrl.text.trim(),
  );

  Future<void> _createWithOpening() async {
    final quantity = _initialQtyValue();
    // Reuses the product already created in this screen when the opening-stock
    // step failed earlier, so retrying never creates a duplicate product.
    final product =
        _created ??
        await widget.api.createProduct(store: _store, input: _productInput());
    if (quantity > 0) {
      try {
        await _inventoryApi.setOpeningStock(
          store: _store,
          productId: product.id,
          quantity: quantity,
          batchCode: _batchCode.text.trim().isEmpty
              ? null
              : _batchCode.text.trim(),
          expiryDate: _expiryDate,
        );
      } on ApiException catch (e) {
        if (mounted) {
          setState(() {
            _created = product;
            _stockError = e.message;
          });
        }
        return;
      } catch (_) {
        if (mounted) {
          setState(() {
            _created = product;
            _stockError =
                'Cannot reach the server. Check your connection and try again.';
          });
        }
        return;
      }
    }
    if (mounted) Navigator.of(context).pop(product);
  }

  double? _parseMoney(String value) {
    final trimmed = value.trim().replaceAll(',', '');
    if (trimmed.isEmpty) return null;
    return double.tryParse(trimmed);
  }

  Future<void> _openBarcodeEntry() async {
    final result = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      builder: (_) => const BarcodeEntrySheet(),
    );
    if (result != null && mounted) {
      _barcode.text = normalizeBarcode(result);
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: Text(_isEditing ? 'Edit Product' : 'New Product')),
      body: SafeArea(
        child: Form(
          key: _formKey,
          child: ListView(
            padding: const EdgeInsets.all(AppSpacing.lg),
            children: [
              _SectionCard(
                title: 'Basics',
                children: [
                  AppInput(
                    label: 'Name *',
                    hintText: 'e.g. Colombian Whole Bean Coffee',
                    controller: _name,
                    textInputAction: TextInputAction.next,
                    autofocus: !_isEditing,
                    validator: _required,
                  ),
                  const SizedBox(height: AppSpacing.md),
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(
                        child: AppInput(
                          label: 'SKU (auto if empty)',
                          hintText: 'Leave empty for auto-generate',
                          controller: _sku,
                          textInputAction: TextInputAction.next,
                        ),
                      ),
                      const SizedBox(width: AppSpacing.md),
                      Expanded(
                        child: AppInput(
                          label: 'Unit *',
                          hintText: 'e.g. bag, kg, box',
                          controller: _unit,
                          textInputAction: TextInputAction.next,
                          validator: _required,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: AppSpacing.md),
                  AppInput(
                    label: 'Variant',
                    hintText: 'e.g. Spicy, Family Pack',
                    controller: _variant,
                    textInputAction: TextInputAction.next,
                  ),
                  const SizedBox(height: AppSpacing.md),
                  DropdownButtonFormField<String>(
                    key: const Key('product-category-field'),
                    initialValue: _categoryId,
                    decoration: const InputDecoration(
                      labelText: 'Category',
                      hintText: 'None',
                    ),
                    isExpanded: true,
                    items: [
                      const DropdownMenuItem<String>(
                        value: null,
                        child: Text('None'),
                      ),
                      // Guarantee a matching item for the current selection even
                      // before categories finish loading (or when the assigned
                      // category is not in the fetched list), so the dropdown
                      // never asserts on a value without an item.
                      if (_categoryId != null &&
                          !_categories.any((c) => c.id == _categoryId))
                        DropdownMenuItem<String>(
                          value: _categoryId,
                          child: Text(_currentCategoryName ?? _categoryId!),
                        ),
                      for (final c in _categories)
                        if (c.isActive || c.id == _categoryId)
                          DropdownMenuItem<String>(
                            value: c.id,
                            child: Text(c.name),
                          ),
                    ],
                    onChanged: (v) => setState(() => _categoryId = v),
                  ),
                  if (_categoriesLoadFailed) ...[
                    const SizedBox(height: AppSpacing.xs),
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            'Could not load categories',
                            style: Theme.of(context).textTheme.bodySmall
                                ?.copyWith(color: scheme.error),
                          ),
                        ),
                        TextButton(
                          onPressed: _loadCategories,
                          child: const Text('Retry'),
                        ),
                      ],
                    ),
                  ],
                  const SizedBox(height: AppSpacing.xs),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: TextButton.icon(
                      onPressed: _createCategoryInline,
                      icon: const Icon(Icons.add, size: 18),
                      label: const Text('New Category'),
                    ),
                  ),
                  const SizedBox(height: AppSpacing.md),
                  AppInput(
                    label: 'Description',
                    hintText: 'Optional',
                    controller: _description,
                    maxLines: 3,
                    textInputAction: TextInputAction.newline,
                  ),
                ],
              ),
              const SizedBox(height: AppSpacing.lg),
              _SectionCard(
                title: 'Dimensions & Weight',
                children: [
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(
                        child: AppInput(
                          label: 'Size',
                          hintText: 'e.g. 500ml, Large',
                          controller: _size,
                          textInputAction: TextInputAction.next,
                        ),
                      ),
                      const SizedBox(width: AppSpacing.md),
                      Expanded(
                        child: AppInput(
                          label: 'Weight',
                          hintText: 'e.g. 250g, 1 lb',
                          controller: _weight,
                          textInputAction: TextInputAction.next,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: AppSpacing.md),
                  AppInput(
                    label: 'Volume',
                    hintText: 'e.g. 750ml, 1.5L',
                    controller: _volume,
                    textInputAction: TextInputAction.next,
                  ),
                ],
              ),
              const SizedBox(height: AppSpacing.lg),
              _SectionCard(
                title: 'Barcode',
                trailing: TextButton.icon(
                  onPressed: _openBarcodeEntry,
                  icon: const Icon(Icons.qr_code_scanner, size: 18),
                  label: const Text('Scan'),
                ),
                children: [
                  AppInput(
                    label: 'Barcode',
                    hintText: 'EAN / UPC / QR',
                    controller: _barcode,
                    icon: Icons.qr_code_2,
                    textInputAction: TextInputAction.done,
                  ),
                ],
              ),
              const SizedBox(height: AppSpacing.lg),
              _SectionCard(
                title: 'Pricing',
                children: [
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(
                        child: AppInput(
                          label: 'Cost price',
                          hintText: '0.00',
                          controller: _cost,
                          keyboardType: const TextInputType.numberWithOptions(
                            decimal: true,
                          ),
                          textInputAction: TextInputAction.next,
                          validator: _money,
                        ),
                      ),
                      const SizedBox(width: AppSpacing.md),
                      Expanded(
                        child: AppInput(
                          label: 'Selling price *',
                          hintText: '0.00',
                          controller: _selling,
                          keyboardType: const TextInputType.numberWithOptions(
                            decimal: true,
                          ),
                          textInputAction: TextInputAction.next,
                          validator: _money,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: AppSpacing.md),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('Expiry tracking'),
                    subtitle: Text(
                      'Track expiration for perishable items',
                      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                    value: _expiryTracking,
                    onChanged: (v) => setState(() => _expiryTracking = v),
                  ),
                ],
              ),
              const SizedBox(height: AppSpacing.lg),
              if (!_isEditing) ...[
                _SectionCard(
                  title: 'Stock',
                  children: [
                    AppInput(
                      label: 'Initial quantity',
                      hintText: '0',
                      controller: _initialQty,
                      keyboardType: const TextInputType.numberWithOptions(
                        decimal: true,
                      ),
                      textInputAction: TextInputAction.next,
                      validator: _initialQuantity,
                    ),
                    const SizedBox(height: AppSpacing.md),
                    AppInput(
                      label: 'Batch code (optional)',
                      hintText: 'e.g. LOT-2026-001',
                      controller: _batchCode,
                      textInputAction: TextInputAction.next,
                    ),
                    const SizedBox(height: AppSpacing.md),
                    Row(
                      children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                'Expiry date (optional)',
                                style: Theme.of(context).textTheme.bodyMedium,
                              ),
                              const SizedBox(height: AppSpacing.xxs),
                              Text(
                                _expiryDate == null
                                    ? 'None'
                                    : '${_expiryDate!.year}-${_expiryDate!.month.toString().padLeft(2, '0')}-${_expiryDate!.day.toString().padLeft(2, '0')}',
                                style: Theme.of(context).textTheme.titleMedium,
                              ),
                            ],
                          ),
                        ),
                        TextButton.icon(
                          onPressed: _pickExpiry,
                          icon: const Icon(
                            Icons.calendar_today_outlined,
                            size: 18,
                          ),
                          label: Text(
                            _expiryDate == null ? 'Pick date' : 'Change',
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: AppSpacing.md),
                    Text(
                      'Optional batch code and expiry date attach to the '
                      'initial stock batch and appear in Expiry tracking.',
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: AppSpacing.lg),
              ],
              _SectionCard(
                title: 'Reorder settings',
                children: [
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(
                        child: AppInput(
                          label: 'Reorder point',
                          hintText: '0',
                          controller: _reorderPoint,
                          keyboardType: const TextInputType.numberWithOptions(
                            decimal: true,
                          ),
                          textInputAction: TextInputAction.next,
                          validator: _decimal,
                        ),
                      ),
                      const SizedBox(width: AppSpacing.md),
                      Expanded(
                        child: AppInput(
                          label: 'Reorder quantity',
                          hintText: '0',
                          controller: _reorderQty,
                          keyboardType: const TextInputType.numberWithOptions(
                            decimal: true,
                          ),
                          textInputAction: TextInputAction.next,
                          validator: _decimal,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
              const SizedBox(height: AppSpacing.lg),
              _SectionCard(
                title: 'Media & status',
                children: [
                  AppInput(
                    label: 'Image URL',
                    hintText: 'https://…',
                    controller: _imageUrl,
                    keyboardType: TextInputType.url,
                    textInputAction: TextInputAction.done,
                  ),
                  const SizedBox(height: AppSpacing.md),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('Active'),
                    subtitle: Text(
                      _isActive
                          ? 'Visible in the catalog and POS'
                          : 'Hidden from sale',
                      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                    value: _isActive,
                    onChanged: (v) => setState(() => _isActive = v),
                  ),
                ],
              ),
              if (_submitError != null) ...[
                const SizedBox(height: AppSpacing.lg),
                Text(
                  _submitError!,
                  style: Theme.of(
                    context,
                  ).textTheme.bodyMedium?.copyWith(color: scheme.error),
                ),
              ],
              if (!_isEditing && _stockError != null) ...[
                const SizedBox(height: AppSpacing.lg),
                _SectionCard(
                  title: 'Stock not applied',
                  children: [
                    Text(
                      'The product was created, but its initial stock could not be applied '
                      '($_stockError). Retrying will not create a duplicate product.',
                      style: Theme.of(
                        context,
                      ).textTheme.bodyMedium?.copyWith(color: scheme.error),
                    ),
                    const SizedBox(height: AppSpacing.md),
                    AppButton(
                      label: 'Retry opening stock',
                      loading: _submitting,
                      onPressed: _submitting ? null : _submit,
                    ),
                  ],
                ),
              ],
              const SizedBox(height: AppSpacing.xl),
              AppButton(
                label: _isEditing ? 'Save changes' : 'Create product',
                size: AppButtonSize.large,
                loading: _submitting,
                onPressed: _submitting ? null : _submit,
              ),
              const SizedBox(height: AppSpacing.xl),
            ],
          ),
        ),
      ),
    );
  }
}

class _SectionCard extends StatelessWidget {
  const _SectionCard({
    required this.title,
    required this.children,
    this.trailing,
  });

  final String title;
  final List<Widget> children;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    return AppCard(
      padding: const EdgeInsets.all(AppSpacing.lg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  title,
                  style: Theme.of(context).textTheme.titleMedium,
                ),
              ),
              ?trailing,
            ],
          ),
          const SizedBox(height: AppSpacing.lg),
          ...children,
        ],
      ),
    );
  }
}
