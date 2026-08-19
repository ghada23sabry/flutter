import 'package:flutter/material.dart';

import '../../../core/api_client.dart';
import '../../../core/session.dart';
import '../../../core/theme/app_tokens.dart';
import '../../../core/widgets/app_card.dart';
import '../../../core/widgets/empty_state.dart';
import '../../../core/widgets/error_state.dart';
import '../../../core/widgets/loading_state.dart';
import '../../catalog/data/catalog_api.dart';
import '../../catalog/data/catalog_models.dart';

/// Searchable picker of active products. Pops with the selected [Product].
class ProductPickerScreen extends StatefulWidget {
  const ProductPickerScreen({
    super.key,
    required this.api,
    required this.session,
  });

  final CatalogApi api;
  final SessionController session;

  @override
  State<ProductPickerScreen> createState() => _ProductPickerScreenState();
}

class _ProductPickerScreenState extends State<ProductPickerScreen> {
  final _searchController = TextEditingController();
  List<Product>? _products;
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final page = await widget.api.listProducts(
        store: widget.session.selectedStore!,
        q: _searchController.text.trim(),
        status: 'active',
        pageSize: 50,
      );
      if (!mounted) return;
      setState(() {
        _products = page.items;
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

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: const Text('Select product')),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(
              AppSpacing.lg,
              AppSpacing.md,
              AppSpacing.lg,
              0,
            ),
            child: TextField(
              controller: _searchController,
              onChanged: (_) => _load(),
              decoration: const InputDecoration(
                hintText: 'Search by name, SKU or barcode',
                prefixIcon: Icon(Icons.search),
              ),
            ),
          ),
          const Divider(height: AppSpacing.md),
          Expanded(child: _buildBody(scheme)),
        ],
      ),
    );
  }

  Widget _buildBody(ColorScheme scheme) {
    if (_loading) return const LoadingState(message: 'Loading products…');
    if (_error != null) return ErrorState(message: _error!, onRetry: _load);
    final products = _products!;
    if (products.isEmpty) {
      return EmptyState(
        icon: Icons.inventory_2_outlined,
        title: 'No products found',
        message: _searchController.text.trim().isNotEmpty
            ? 'No products match that search.'
            : 'There are no active products in this store.',
      );
    }
    return ListView.separated(
      padding: const EdgeInsets.all(AppSpacing.lg),
      itemCount: products.length,
      separatorBuilder: (_, _) => const SizedBox(height: AppSpacing.sm),
      itemBuilder: (context, index) {
        final product = products[index];
        return AppCard(
          onTap: () => Navigator.of(context).pop(product),
          padding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.lg,
            vertical: AppSpacing.md,
          ),
          child: Row(
            children: [
              Icon(Icons.inventory_2_outlined, size: 22, color: scheme.primary),
              const SizedBox(width: AppSpacing.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      product.name,
                      style: Theme.of(context).textTheme.bodyLarge,
                    ),
                    Text(
                      product.sku,
                      style: Theme.of(context).textTheme.labelSmall?.copyWith(
                        color: scheme.onSurfaceVariant,
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
}
