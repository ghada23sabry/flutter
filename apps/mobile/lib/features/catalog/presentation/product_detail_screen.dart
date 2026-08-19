import 'package:flutter/material.dart';

import '../../../core/api_client.dart';
import '../../../core/models/auth_models.dart';
import '../../../core/permissions.dart';
import '../../../core/session.dart';
import '../../../core/theme/app_tokens.dart';
import '../../../core/util/app_format.dart';
import '../../../core/widgets/app_card.dart';
import '../../../core/widgets/error_state.dart';
import '../../../core/widgets/loading_state.dart';
import '../../../core/widgets/status_badge.dart';
import '../data/catalog_api.dart';
import '../data/catalog_models.dart';
import 'product_edit_screen.dart';
import 'supplier_link_dialog.dart';

/// Full product view with edit + supplier link management.
/// Pops `true` when the product or its links changed.
class ProductDetailScreen extends StatefulWidget {
  const ProductDetailScreen({
    super.key,
    required this.api,
    required this.session,
    required this.productId,
  });

  final CatalogApi api;
  final SessionController session;
  final String productId;

  @override
  State<ProductDetailScreen> createState() => _ProductDetailScreenState();
}

class _ProductDetailScreenState extends State<ProductDetailScreen> {
  Product? _product;
  bool _loading = true;
  String? _error;

  List<SupplierProductLink> _suppliers = const [];
  bool _suppliersLoading = true;

  StoreInfo get _store => widget.session.selectedStore!;

  bool get _canManage =>
      widget.session.hasPermission(Permissions.productsManage);

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final product = await widget.api.getProduct(
        store: _store,
        id: widget.productId,
      );
      if (!mounted) return;
      setState(() {
        _product = product;
        _loading = false;
      });
      await _loadSuppliers();
    } catch (e) {
      if (mounted) {
        setState(() {
          _loading = false;
          _error = e is ApiException
              ? e.message
              : 'Cannot reach the server. Check your connection.';
        });
      }
    }
  }

  Future<void> _loadSuppliers() async {
    setState(() => _suppliersLoading = true);
    try {
      final suppliers = await widget.api.getProductSuppliers(
        store: _store,
        productId: widget.productId,
      );
      if (mounted) setState(() => _suppliers = suppliers);
    } catch (_) {
      // Suppliers section degrades to empty on failure.
    } finally {
      if (mounted) setState(() => _suppliersLoading = false);
    }
  }

  Future<void> _edit() async {
    final updated = await Navigator.of(context).push<Product>(
      MaterialPageRoute(
        builder: (_) => ProductEditScreen(
          api: widget.api,
          session: widget.session,
          existing: _product,
        ),
      ),
    );
    if (updated != null && mounted) {
      setState(() => _product = updated);
      Navigator.of(context).pop(true);
    }
  }

  Future<void> _linkSupplier() async {
    if (!widget.session.hasPermission(Permissions.suppliersView)) return;
    List<Supplier> suppliers;
    try {
      final page = await widget.api.listSuppliers(
        status: 'active',
        pageSize: 100,
      );
      suppliers = page.items;
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              e is ApiException
                  ? e.message
                  : 'Cannot reach the server. Check your connection.',
            ),
          ),
        );
      }
      return;
    }
    if (!mounted) return;
    final supplier = await showModalBottomSheet<Supplier>(
      context: context,
      showDragHandle: true,
      builder: (_) => _SupplierPicker(suppliers: suppliers),
    );
    if (supplier == null || !mounted) return;

    final values = await _promptLinkValues(title: 'Link ${supplier.name}');
    if (values == null || !mounted) return;
    try {
      final link = await widget.api.linkProductToSupplier(
        store: _store,
        supplierId: supplier.id,
        productId: widget.productId,
        supplierSku: values.supplierSku,
        supplierCost: values.supplierCost,
        leadTimeDays: values.leadTimeDays,
        isPreferred: values.isPreferred,
      );
      if (mounted) {
        setState(() => _suppliers = [..._suppliers, link]);
        Navigator.of(context).pop(true);
      }
    } on ApiException catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(e.message)));
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Cannot reach the server. Check your connection.'),
          ),
        );
      }
    }
  }

  Future<void> _editLink(SupplierProductLink link) async {
    final values = await _promptLinkValues(
      title: 'Edit ${link.supplierName ?? 'link'}',
      initial: link,
    );
    if (values == null || !mounted) return;
    try {
      final updated = await widget.api.updateSupplierProductLink(
        store: _store,
        supplierId: link.supplierId,
        productId: link.productId,
        supplierSku: values.supplierSku,
        supplierCost: values.supplierCost,
        leadTimeDays: values.leadTimeDays,
        isPreferred: values.isPreferred,
      );
      if (mounted) {
        setState(
          () => _suppliers = [
            for (final s in _suppliers)
              if (s.supplierId == updated.supplierId &&
                  s.productId == updated.productId)
                updated
              else
                s,
          ],
        );
        Navigator.of(context).pop(true);
      }
    } on ApiException catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(e.message)));
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Cannot reach the server. Check your connection.'),
          ),
        );
      }
    }
  }

  Future<void> _unlink(SupplierProductLink link) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Remove supplier?'),
        content: Text(
          'Unlink ${link.supplierName ?? 'this supplier'} from ${_product!.name}?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.error,
            ),
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Remove'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    try {
      await widget.api.unlinkProduct(
        store: _store,
        supplierId: link.supplierId,
        productId: link.productId,
      );
      if (mounted) {
        setState(
          () => _suppliers = _suppliers
              .where(
                (s) =>
                    !(s.supplierId == link.supplierId &&
                        s.productId == link.productId),
              )
              .toList(),
        );
        Navigator.of(context).pop(true);
      }
    } on ApiException catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(e.message)));
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Cannot reach the server. Check your connection.'),
          ),
        );
      }
    }
  }

  Future<SupplierLinkValues?> _promptLinkValues({
    required String title,
    SupplierProductLink? initial,
  }) {
    return showDialog<SupplierLinkValues>(
      context: context,
      builder: (_) => SupplierLinkDialog(title: title, initial: initial),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(_product?.name ?? 'Product'),
        actions: [
          if (_product != null && _canManage)
            IconButton(
              tooltip: 'Edit',
              icon: const Icon(Icons.edit_outlined),
              onPressed: _edit,
            ),
        ],
      ),
      body: _buildBody(),
    );
  }

  Widget _buildBody() {
    if (_loading) return const LoadingState(message: 'Loading product…');
    if (_error != null) return ErrorState(message: _error!, onRetry: _load);
    final product = _product!;
    final scheme = Theme.of(context).colorScheme;
    final currency = _store.currency;

    return ListView(
      padding: const EdgeInsets.all(AppSpacing.lg),
      children: [
        _DetailCard(
          title: 'Status',
          child: Row(
            children: [
              if (product.isActive)
                const StatusBadge(label: 'Active', status: AppStatus.success)
              else
                const StatusBadge(label: 'Inactive', status: AppStatus.neutral),
            ],
          ),
        ),
        const SizedBox(height: AppSpacing.lg),
        _DetailCard(
          title: 'Pricing',
          child: Column(
            children: _rows([
              (
                'Cost price',
                AppFormat.money(product.costPrice, currency: currency),
              ),
              (
                'Selling price',
                AppFormat.money(product.sellingPrice, currency: currency),
              ),
              ('Margin', '${product.profitMargin.toStringAsFixed(1)}%'),
            ]),
          ),
        ),
        const SizedBox(height: AppSpacing.lg),
        _DetailCard(
          title: 'Reorder',
          child: Column(
            children: _rows([
              (
                'Reorder point',
                '${product.reorderPoint} ${product.unit}'.trim(),
              ),
              (
                'Reorder quantity',
                '${product.reorderQuantity} ${product.unit}'.trim(),
              ),
              ('Expiry tracking', product.expiryTrackingEnabled ? 'On' : 'Off'),
            ]),
          ),
        ),
        const SizedBox(height: AppSpacing.lg),
        _DetailCard(
          title: 'Identity',
          child: Column(
            children: _rows([
              ('SKU', product.sku),
              ('Barcode', product.barcode ?? '—'),
              ('Category', product.categoryName ?? '—'),
              ('Unit', product.unit),
              ('Created', AppFormat.relativeDate(product.createdAt)),
            ]),
          ),
        ),
        if (product.imageUrl != null && product.imageUrl!.isNotEmpty) ...[
          const SizedBox(height: AppSpacing.lg),
          _DetailCard(
            title: 'Image',
            child: ClipRRect(
              borderRadius: BorderRadius.circular(AppRadius.md),
              child: Image.network(
                product.imageUrl!,
                height: 180,
                fit: BoxFit.cover,
                errorBuilder: (_, _, _) => Container(
                  height: 180,
                  color: scheme.surfaceContainerHighest,
                  child: const Center(
                    child: Icon(Icons.broken_image_outlined, size: 32),
                  ),
                ),
                loadingBuilder: (_, child, progress) => progress == null
                    ? child
                    : const SizedBox(
                        height: 180,
                        child: Center(child: CircularProgressIndicator()),
                      ),
              ),
            ),
          ),
        ],
        if (product.description != null && product.description!.isNotEmpty) ...[
          const SizedBox(height: AppSpacing.lg),
          _DetailCard(
            title: 'Description',
            child: Text(
              product.description!,
              style: Theme.of(context).textTheme.bodyMedium,
            ),
          ),
        ],
        const SizedBox(height: AppSpacing.lg),
        _DetailCard(
          title: 'Suppliers',
          trailing:
              _canManage &&
                  widget.session.hasPermission(Permissions.suppliersView)
              ? TextButton.icon(
                  onPressed: _linkSupplier,
                  icon: const Icon(Icons.add_link, size: 18),
                  label: const Text('Link'),
                )
              : null,
          child: _buildSuppliers(),
        ),
        const SizedBox(height: AppSpacing.xl),
      ],
    );
  }

  Widget _buildSuppliers() {
    if (_suppliersLoading) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: AppSpacing.md),
        child: LoadingState(message: 'Loading suppliers…', expand: false),
      );
    }
    if (_suppliers.isEmpty) {
      return Text(
        'No suppliers linked to this product yet.',
        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
          color: Theme.of(context).colorScheme.onSurfaceVariant,
        ),
      );
    }
    return Column(
      children: [
        for (final link in _suppliers) ...[
          _SupplierLinkTile(
            link: link,
            canManage: _canManage,
            onTap: _canManage ? () => _editLink(link) : null,
            onRemove: _canManage ? () => _unlink(link) : null,
          ),
          if (link != _suppliers.last) const SizedBox(height: AppSpacing.sm),
        ],
      ],
    );
  }

  List<Widget> _rows(List<(String, String)> rows) => [
    for (var i = 0; i < rows.length; i++) ...[
      if (i > 0) const Divider(height: AppSpacing.xl),
      Row(
        children: [
          Expanded(
            child: Text(
              rows[i].$1,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          Text(rows[i].$2, style: Theme.of(context).textTheme.bodyLarge),
        ],
      ),
    ],
  ];
}

class _SupplierLinkTile extends StatelessWidget {
  const _SupplierLinkTile({
    required this.link,
    this.onTap,
    this.onRemove,
    required this.canManage,
  });

  final SupplierProductLink link;
  final VoidCallback? onTap;
  final VoidCallback? onRemove;
  final bool canManage;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return AppCard(
      onTap: onTap,
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.lg,
        vertical: AppSpacing.md,
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Flexible(
                      child: Text(
                        link.supplierName ?? 'Supplier',
                        style: Theme.of(context).textTheme.bodyLarge,
                      ),
                    ),
                    if (link.isPreferred) ...[
                      const SizedBox(width: AppSpacing.sm),
                      const StatusBadge(
                        label: 'Preferred',
                        status: AppStatus.info,
                      ),
                    ],
                  ],
                ),
                const SizedBox(height: AppSpacing.xs),
                Text(
                  [
                    if (link.supplierSku != null) 'sku ${link.supplierSku}',
                    if (link.supplierCost != null)
                      AppFormat.money(link.supplierCost!),
                    if (link.leadTimeDays != null) '${link.leadTimeDays}d lead',
                  ].join(' · '),
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
          if (canManage && onRemove != null)
            IconButton(
              tooltip: 'Remove supplier',
              icon: const Icon(Icons.link_off),
              onPressed: onRemove,
            ),
        ],
      ),
    );
  }
}

class _SupplierPicker extends StatelessWidget {
  const _SupplierPicker({required this.suppliers});

  final List<Supplier> suppliers;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(
              AppSpacing.xl,
              0,
              AppSpacing.xl,
              AppSpacing.md,
            ),
            child: Text(
              'Link supplier',
              style: Theme.of(context).textTheme.titleLarge,
            ),
          ),
          if (suppliers.isEmpty)
            const Padding(
              padding: EdgeInsets.all(AppSpacing.xl),
              child: Center(child: Text('No active suppliers. Add one first.')),
            )
          else
            Flexible(
              child: ListView(
                shrinkWrap: true,
                children: [
                  for (final supplier in suppliers)
                    ListTile(
                      leading: const Icon(Icons.local_shipping_outlined),
                      title: Text(supplier.name),
                      subtitle: Text(
                        supplier.contactName ?? supplier.email ?? '',
                      ),
                      onTap: () => Navigator.of(context).pop(supplier),
                    ),
                ],
              ),
            ),
          const SizedBox(height: AppSpacing.sm),
        ],
      ),
    );
  }
}

class _DetailCard extends StatelessWidget {
  const _DetailCard({required this.title, required this.child, this.trailing});

  final String title;
  final Widget child;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    return AppCard(
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
          child,
        ],
      ),
    );
  }
}
