import 'package:flutter/material.dart';

import '../../../core/api_client.dart';
import '../../../core/permissions.dart';
import '../../../core/session.dart';
import '../../../core/theme/app_tokens.dart';
import '../../../core/widgets/app_button.dart';
import '../../../core/widgets/app_card.dart';
import '../../../core/widgets/empty_state.dart';
import '../../../core/widgets/error_state.dart';
import '../../../core/widgets/loading_state.dart';
import '../../../core/widgets/status_badge.dart';
import '../../catalog/data/catalog_api.dart';
import '../../catalog/data/catalog_models.dart' show Product;
import '../data/inventory_api.dart';
import '../data/inventory_models.dart';
import 'product_picker_screen.dart';
import 'shelf_form_dialog.dart';

/// One shelf: location info plus the products mapped to it.
class ShelfDetailScreen extends StatefulWidget {
  const ShelfDetailScreen({
    super.key,
    required this.api,
    required this.session,
    required this.shelfId,
  });

  final InventoryApi api;
  final SessionController session;
  final String shelfId;

  @override
  State<ShelfDetailScreen> createState() => _ShelfDetailScreenState();
}

class _ShelfDetailScreenState extends State<ShelfDetailScreen> {
  Shelf? _shelf;
  List<ShelfProductMap>? _mappings;
  bool _loading = true;
  String? _error;

  bool get _canManage =>
      widget.session.hasPermission(Permissions.inventoryLayout);

  CatalogApi get _catalog => CatalogApi(widget.api.client);

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
      final results = await Future.wait<Object?>([
        widget.api.getShelf(
          store: widget.session.selectedStore!,
          shelfId: widget.shelfId,
        ),
        widget.api.listShelfProducts(
          store: widget.session.selectedStore!,
          shelfId: widget.shelfId,
        ),
      ]);
      if (!mounted) return;
      setState(() {
        _shelf = results[0] as Shelf;
        _mappings = results[1] as List<ShelfProductMap>;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = e is ApiException
            ? e.message
            : 'Cannot reach the server. Check your connection.';
      });
    }
  }

  Future<void> _openMap() async {
    final product = await Navigator.of(context).push<Product?>(
      MaterialPageRoute(
        builder: (_) =>
            ProductPickerScreen(api: _catalog, session: widget.session),
      ),
    );
    if (product == null || !mounted) return;
    try {
      await widget.api.mapProductToShelf(
        store: widget.session.selectedStore!,
        shelfId: widget.shelfId,
        productId: product.id,
        position: _mappings!.length,
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(const SnackBar(content: Text('Product added to shelf')));
      _load();
    } on ApiException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text(e.message)));
    }
  }

  Future<void> _unmap(ShelfProductMap mapping) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Remove from shelf?'),
        content: Text(
          '${mapping.productName ?? mapping.productId} will no longer be mapped to ${_shelf?.label}.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('Remove'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    try {
      await widget.api.unmapProductFromShelf(
        store: widget.session.selectedStore!,
        shelfId: widget.shelfId,
        productId: mapping.productId,
      );
      if (!mounted) return;
      _load();
    } on ApiException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text(e.message)));
    }
  }

  Future<void> _openEdit() async {
    final updated = await showShelfFormDialog(
      context: context,
      api: widget.api,
      session: widget.session,
      existing: _shelf,
    );
    if (updated != null && mounted) _load();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: Text(_shelf?.label ?? 'Shelf'),
        actions: [
          if (_canManage && _shelf != null)
            IconButton(
              tooltip: 'Edit shelf',
              icon: const Icon(Icons.edit_outlined),
              onPressed: _openEdit,
            ),
        ],
      ),
      body: _buildBody(scheme),
      floatingActionButton: _canManage
          ? FloatingActionButton.extended(
              onPressed: _openMap,
              icon: const Icon(Icons.add),
              label: const Text('Map product'),
            )
          : null,
    );
  }

  Widget _buildBody(ColorScheme scheme) {
    if (_loading) return const LoadingState(message: 'Loading shelf…');
    if (_error != null) return ErrorState(message: _error!, onRetry: _load);
    final shelf = _shelf!;
    final mappings = _mappings!;
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        padding: const EdgeInsets.all(AppSpacing.lg),
        children: [
          AppCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        shelf.label,
                        style: Theme.of(context).textTheme.titleLarge,
                      ),
                    ),
                    if (!shelf.isActive)
                      const StatusBadge(
                        label: 'Inactive',
                        status: AppStatus.neutral,
                      ),
                  ],
                ),
                const SizedBox(height: AppSpacing.xs),
                Text(
                  '${shelf.zoneName ?? 'Zone'} · position ${shelf.position}${shelf.code != null && shelf.code!.isNotEmpty ? ' · ${shelf.code}' : ''}',
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: AppSpacing.lg),
          Text(
            'Products (${mappings.length})',
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: AppSpacing.sm),
          if (mappings.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: AppSpacing.xxl),
              child: EmptyState(
                icon: Icons.storefront_outlined,
                title: 'No products mapped',
                message: 'Map products to this shelf so staff can locate them.',
                action: _canManage
                    ? AppButton(
                        label: 'Map product',
                        onPressed: _openMap,
                        expand: false,
                        icon: Icons.add,
                      )
                    : null,
              ),
            )
          else
            for (final mapping in mappings)
              Padding(
                padding: const EdgeInsets.only(bottom: AppSpacing.sm),
                child: AppCard(
                  padding: const EdgeInsets.symmetric(
                    horizontal: AppSpacing.lg,
                    vertical: AppSpacing.md,
                  ),
                  child: Row(
                    children: [
                      Icon(
                        Icons.inventory_2_outlined,
                        size: 20,
                        color: scheme.primary,
                      ),
                      const SizedBox(width: AppSpacing.md),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                Flexible(
                                  child: Text(
                                    mapping.productName ?? mapping.productId,
                                    style: Theme.of(
                                      context,
                                    ).textTheme.bodyLarge,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                                if (mapping.isPrimary) ...[
                                  const SizedBox(width: AppSpacing.sm),
                                  const StatusBadge(
                                    label: 'Primary',
                                    status: AppStatus.info,
                                  ),
                                ],
                              ],
                            ),
                            if (mapping.sku != null && mapping.sku!.isNotEmpty)
                              Text(
                                mapping.sku!,
                                style: Theme.of(context).textTheme.labelSmall
                                    ?.copyWith(color: scheme.onSurfaceVariant),
                              ),
                          ],
                        ),
                      ),
                      if (_canManage)
                        IconButton(
                          tooltip: 'Remove',
                          icon: const Icon(Icons.close, size: 18),
                          onPressed: () => _unmap(mapping),
                        ),
                    ],
                  ),
                ),
              ),
        ],
      ),
    );
  }
}
