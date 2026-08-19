import 'package:flutter/material.dart';

import '../../../core/api_client.dart';
import '../../../core/models/auth_models.dart';
import '../../../core/permissions.dart';
import '../../../core/session.dart';
import '../../../core/theme/app_tokens.dart';
import '../../../core/util/app_format.dart';
import '../../../core/widgets/app_card.dart';
import '../../../core/widgets/empty_state.dart';
import '../../../core/widgets/error_state.dart';
import '../../../core/widgets/loading_state.dart';
import '../../../core/widgets/status_badge.dart';
import '../data/catalog_api.dart';
import '../data/catalog_models.dart';
import 'product_detail_screen.dart';
import 'supplier_edit_screen.dart';
import 'supplier_link_dialog.dart';

/// Supplier profile plus the products they supply. Pops `true` when mutated.
class SupplierDetailScreen extends StatefulWidget {
  const SupplierDetailScreen({
    super.key,
    required this.api,
    required this.session,
    required this.supplierId,
  });

  final CatalogApi api;
  final SessionController session;
  final String supplierId;

  @override
  State<SupplierDetailScreen> createState() => _SupplierDetailScreenState();
}

class _SupplierDetailScreenState extends State<SupplierDetailScreen> {
  Supplier? _supplier;
  bool _loading = true;
  String? _error;

  List<SupplierProductLink> _products = const [];
  bool _productsLoading = true;

  StoreInfo get _store => widget.session.selectedStore!;

  bool get _canManage =>
      widget.session.hasPermission(Permissions.suppliersManage);

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
      final supplier = await widget.api.getSupplier(id: widget.supplierId);
      if (!mounted) return;
      setState(() {
        _supplier = supplier;
        _loading = false;
      });
      await _loadProducts();
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

  Future<void> _loadProducts() async {
    setState(() => _productsLoading = true);
    try {
      final products = await widget.api.getSupplierProducts(
        supplierId: widget.supplierId,
      );
      if (mounted) setState(() => _products = products);
    } catch (_) {
      // Product list degrades to empty on failure; supplier data stays visible.
    } finally {
      if (mounted) setState(() => _productsLoading = false);
    }
  }

  Future<void> _edit() async {
    final updated = await Navigator.of(context).push<Supplier>(
      MaterialPageRoute(
        builder: (_) => SupplierEditScreen(
          api: widget.api,
          session: widget.session,
          existing: _supplier,
        ),
      ),
    );
    if (updated != null && mounted) {
      setState(() => _supplier = updated);
      Navigator.of(context).pop(true);
    }
  }

  Future<void> _linkProduct() async {
    if (!widget.session.hasPermission(Permissions.productsView)) return;
    List<Product> products;
    try {
      final page = await widget.api.listProducts(
        store: _store,
        status: 'active',
        pageSize: 100,
      );
      products = page.items;
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

    final product = await showModalBottomSheet<Product>(
      context: context,
      showDragHandle: true,
      builder: (_) => _ProductPicker(products: products),
    );
    if (product == null || !mounted) return;
    if (_products.any((p) => p.productId == product.id)) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('This product is already linked to the supplier.'),
          ),
        );
      }
      return;
    }

    final values = await showDialog<SupplierLinkValues>(
      context: context,
      builder: (_) => SupplierLinkDialog(title: 'Link ${product.name}'),
    );
    if (values == null || !mounted) return;
    try {
      final link = await widget.api.linkProductToSupplier(
        store: _store,
        supplierId: widget.supplierId,
        productId: product.id,
        supplierSku: values.supplierSku,
        supplierCost: values.supplierCost,
        leadTimeDays: values.leadTimeDays,
        isPreferred: values.isPreferred,
      );
      if (mounted) {
        setState(() => _products = [..._products, link]);
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
    final values = await showDialog<SupplierLinkValues>(
      context: context,
      builder: (_) => SupplierLinkDialog(
        title: 'Edit ${link.productName ?? 'link'}',
        initial: link,
      ),
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
          () => _products = [
            for (final p in _products)
              if (p.supplierId == updated.supplierId &&
                  p.productId == updated.productId)
                updated
              else
                p,
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
        title: const Text('Remove product?'),
        content: Text(
          'Unlink ${link.productName ?? 'this product'} from ${_supplier!.name}?',
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
          () => _products = _products
              .where(
                (p) =>
                    !(p.supplierId == link.supplierId &&
                        p.productId == link.productId),
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

  Future<void> _openProduct(SupplierProductLink link) async {
    await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) => ProductDetailScreen(
          api: widget.api,
          session: widget.session,
          productId: link.productId,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(_supplier?.name ?? 'Supplier'),
        actions: [
          if (_supplier != null && _canManage)
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
    if (_loading) return const LoadingState(message: 'Loading supplier…');
    if (_error != null) return ErrorState(message: _error!, onRetry: _load);
    final supplier = _supplier!;
    final scheme = Theme.of(context).colorScheme;
    final currency = _store.currency;

    return ListView(
      padding: const EdgeInsets.all(AppSpacing.lg),
      children: [
        AppCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Text(
                    'Contact',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  const Spacer(),
                  if (!supplier.isActive)
                    const StatusBadge(
                      label: 'Inactive',
                      status: AppStatus.neutral,
                    ),
                ],
              ),
              const SizedBox(height: AppSpacing.lg),
              _contactRow(Icons.person_outline, supplier.contactName ?? '—'),
              const SizedBox(height: AppSpacing.md),
              _contactRow(Icons.mail_outline, supplier.email ?? '—'),
              const SizedBox(height: AppSpacing.md),
              _contactRow(Icons.phone_outlined, supplier.phone ?? '—'),
              const SizedBox(height: AppSpacing.md),
              _contactRow(Icons.place_outlined, supplier.address ?? '—'),
              if (supplier.notes != null && supplier.notes!.isNotEmpty) ...[
                const SizedBox(height: AppSpacing.md),
                const Divider(),
                const SizedBox(height: AppSpacing.md),
                Text(
                  supplier.notes!,
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ],
            ],
          ),
        ),
        const SizedBox(height: AppSpacing.xl),
        Row(
          children: [
            Text(
              'Products supplied',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const Spacer(),
            if (_canManage &&
                widget.session.hasPermission(Permissions.productsView))
              TextButton.icon(
                onPressed: _linkProduct,
                icon: const Icon(Icons.add_link, size: 18),
                label: const Text('Link'),
              ),
          ],
        ),
        const SizedBox(height: AppSpacing.lg),
        if (_productsLoading)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: AppSpacing.xl),
            child: LoadingState(message: 'Loading products…', expand: false),
          )
        else if (_products.isEmpty)
          const EmptyState(
            icon: Icons.inventory_2_outlined,
            title: 'No products yet',
            message: 'Link products this supplier provides.',
          )
        else
          ..._products.map(
            (link) => Padding(
              padding: const EdgeInsets.only(bottom: AppSpacing.sm),
              child: _ProductLinkTile(
                link: link,
                currency: currency,
                canManage: _canManage,
                onTap: () => _openProduct(link),
                onEdit: _canManage ? () => _editLink(link) : null,
                onRemove: _canManage ? () => _unlink(link) : null,
              ),
            ),
          ),
        const SizedBox(height: AppSpacing.xl),
      ],
    );
  }

  Widget _contactRow(IconData icon, String value) => Row(
    children: [
      Icon(
        icon,
        size: 18,
        color: Theme.of(context).colorScheme.onSurfaceVariant,
      ),
      const SizedBox(width: AppSpacing.md),
      Expanded(
        child: Text(value, style: Theme.of(context).textTheme.bodyLarge),
      ),
    ],
  );
}

class _ProductPicker extends StatelessWidget {
  const _ProductPicker({required this.products});

  final List<Product> products;

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
              'Link product',
              style: Theme.of(context).textTheme.titleLarge,
            ),
          ),
          if (products.isEmpty)
            const Padding(
              padding: EdgeInsets.all(AppSpacing.xl),
              child: Center(
                child: Text('No active products in this store. Add one first.'),
              ),
            )
          else
            Flexible(
              child: ListView(
                shrinkWrap: true,
                children: [
                  for (final product in products)
                    ListTile(
                      leading: const Icon(Icons.inventory_2_outlined),
                      title: Text(product.name),
                      subtitle: Text(product.sku),
                      trailing: Text(
                        AppFormat.money(product.sellingPrice),
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                      onTap: () => Navigator.of(context).pop(product),
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

class _ProductLinkTile extends StatelessWidget {
  const _ProductLinkTile({
    required this.link,
    required this.currency,
    required this.canManage,
    this.onTap,
    this.onEdit,
    this.onRemove,
  });

  final SupplierProductLink link;
  final String currency;
  final bool canManage;
  final VoidCallback? onTap;
  final VoidCallback? onEdit;
  final VoidCallback? onRemove;

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
                        link.productName ?? 'Product',
                        style: Theme.of(context).textTheme.bodyLarge,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
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
                    if (link.productSku != null) link.productSku!,
                    if (link.supplierCost != null)
                      AppFormat.money(link.supplierCost!, currency: currency),
                    if (link.leadTimeDays != null) '${link.leadTimeDays}d lead',
                  ].join(' · '),
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
          if (canManage && onEdit != null)
            IconButton(
              tooltip: 'Edit link',
              icon: const Icon(Icons.edit_outlined),
              onPressed: onEdit,
            ),
          if (canManage && onRemove != null)
            IconButton(
              tooltip: 'Remove link',
              icon: const Icon(Icons.link_off),
              onPressed: onRemove,
            ),
        ],
      ),
    );
  }
}
