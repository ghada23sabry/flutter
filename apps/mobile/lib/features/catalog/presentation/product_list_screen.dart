import 'dart:async';

import 'package:flutter/material.dart';

import '../../../core/api_client.dart';
import '../../../core/models/auth_models.dart';
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
import '../data/catalog_api.dart';
import '../data/catalog_models.dart';
import 'product_detail_screen.dart';
import 'product_edit_screen.dart';

/// Paginated, searchable product list for the selected store.
class ProductListScreen extends StatefulWidget {
  const ProductListScreen({super.key, required this.api, required this.session});

  final CatalogApi api;
  final SessionController session;

  @override
  State<ProductListScreen> createState() => _ProductListScreenState();
}

class _ProductListScreenState extends State<ProductListScreen> {
  static const int _pageSize = 30;

  final _searchController = TextEditingController();
  final _scrollController = ScrollController();

  final List<Product> _products = [];
  bool _loading = true;
  bool _loadingMore = false;
  String? _error;
  int _total = 0;
  int _page = 1;
  bool _showInactive = false;
  Timer? _searchDebounce;

  StoreInfo get _store => widget.session.selectedStore!;

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_onScroll);
    _load();
  }

  @override
  void dispose() {
    _searchController.dispose();
    _scrollController.dispose();
    _searchDebounce?.cancel();
    super.dispose();
  }

  void _onSearchChanged(String _) {
    _searchDebounce?.cancel();
    _searchDebounce = Timer(const Duration(milliseconds: 350), () => _load());
  }

  void _onScroll() {
    if (_scrollController.position.pixels >= _scrollController.position.maxScrollExtent - 200) {
      _loadMore();
    }
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final page = await widget.api.listProducts(
        store: _store,
        q: _searchController.text.trim(),
        status: _showInactive ? null : 'active',
        page: 1,
        pageSize: _pageSize,
      );
      if (!mounted) return;
      setState(() {
        _products
          ..clear()
          ..addAll(page.items);
        _total = page.total;
        _page = page.page;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = e is ApiException ? e.message : 'Cannot reach the server. Check your connection.';
      });
    }
  }

  Future<void> _loadMore() async {
    if (_loading || _loadingMore || !(_products.length < _total)) return;
    final nextPage = _page + 1;
    setState(() => _loadingMore = true);
    try {
      final page = await widget.api.listProducts(
        store: _store,
        q: _searchController.text.trim(),
        status: _showInactive ? null : 'active',
        page: nextPage,
        pageSize: _pageSize,
      );
      if (!mounted) return;
      setState(() {
        _products.addAll(page.items);
        _total = page.total;
        _page = page.page;
        _loadingMore = false;
      });
    } catch (_) {
      if (mounted) setState(() => _loadingMore = false);
    }
  }

  Future<void> _openAdd() async {
    final created = await Navigator.of(context).push<Product>(
      MaterialPageRoute(
        builder: (_) => ProductEditScreen(api: widget.api, session: widget.session),
      ),
    );
    if (created != null && mounted) {
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(const SnackBar(content: Text('Product created')));
      _load();
    }
  }

  Future<void> _openDetail(Product product) async {
    final changed = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) => ProductDetailScreen(
          api: widget.api,
          session: widget.session,
          productId: product.id,
        ),
      ),
    );
    if (changed == true && mounted) {
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(const SnackBar(content: Text('Product updated')));
      _load();
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(AppSpacing.lg, AppSpacing.md, AppSpacing.lg, 0),
            child: TextField(
              controller: _searchController,
              onChanged: _onSearchChanged,
              decoration: InputDecoration(
                hintText: 'Search by name, SKU or barcode',
                prefixIcon: const Icon(Icons.search),
                suffixIcon: _searchController.text.isEmpty
                    ? null
                    : IconButton(
                        tooltip: 'Clear',
                        icon: const Icon(Icons.clear),
                        onPressed: () {
                          _searchController.clear();
                          _load();
                        },
                      ),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg, vertical: AppSpacing.xs),
            child: Row(
              children: [
                TextButton.icon(
                  onPressed: () => setState(() {
                    _showInactive = !_showInactive;
                    _load();
                  }),
                  icon: Icon(
                    _showInactive ? Icons.check_box : Icons.check_box_outline_blank,
                    size: 18,
                  ),
                  label: const Text('Show inactive'),
                ),
                const Spacer(),
                Text(
                  _loading ? 'Updating…' : '$_total total',
                  style: Theme.of(context).textTheme.labelMedium?.copyWith(color: scheme.onSurfaceVariant),
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          Expanded(child: _buildBody()),
        ],
      ),
      floatingActionButton: widget.session.hasPermission(Permissions.productsManage)
          ? FloatingActionButton(
              tooltip: 'Add product',
              onPressed: _openAdd,
              child: const Icon(Icons.add),
            )
          : null,
    );
  }

  Widget _buildBody() {
    if (_loading) return const LoadingState(message: 'Loading products…');
    if (_error != null) {
      return ErrorState(message: _error!, onRetry: _load);
    }
    if (_products.isEmpty) {
      return EmptyState(
        icon: Icons.inventory_2_outlined,
        title: 'No products found',
        message: _searchController.text.trim().isNotEmpty
            ? 'No products match "${_searchController.text.trim()}".'
            : 'Add your first product to start stocking the store.',
        action: _searchController.text.trim().isNotEmpty
            ? null
            : (widget.session.hasPermission(Permissions.productsManage)
                ? AppButton(
                    label: 'Add product',
                    onPressed: _openAdd,
                    expand: false,
                    icon: Icons.add,
                  )
                : null),
      );
    }
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView.separated(
        controller: _scrollController,
        padding: const EdgeInsets.all(AppSpacing.lg),
        itemCount: _products.length + (_loadingMore ? 1 : 0),
        separatorBuilder: (_, _) => const SizedBox(height: AppSpacing.sm),
        itemBuilder: (context, index) {
          if (index >= _products.length) {
            return const Padding(
              padding: EdgeInsets.symmetric(vertical: AppSpacing.md),
              child: Center(child: SizedBox(width: 24, height: 24, child: CircularProgressIndicator(strokeWidth: 2))),
            );
          }
          return _ProductTile(product: _products[index], onTap: () => _openDetail(_products[index]));
        },
      ),
    );
  }
}

class _ProductTile extends StatelessWidget {
  const _ProductTile({required this.product, required this.onTap});

  final Product product;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return AppCard(
      onTap: onTap,
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg, vertical: AppSpacing.md),
      child: Row(
        children: [
          Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(
              color: scheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(AppRadius.md),
            ),
            child: Icon(
              product.imageUrl == null ? Icons.inventory_2_outlined : Icons.image_outlined,
              color: scheme.onSurfaceVariant,
              size: 22,
            ),
          ),
          const SizedBox(width: AppSpacing.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        product.name,
                        style: Theme.of(context).textTheme.bodyLarge,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    const SizedBox(width: AppSpacing.sm),
                    Text(
                      product.sku,
                      style: Theme.of(context).textTheme.labelSmall?.copyWith(color: scheme.onSurfaceVariant),
                    ),
                  ],
                ),
                const SizedBox(height: AppSpacing.xs),
                Row(
                  children: [
                    Text(
                      AppFormat.money(product.sellingPrice),
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    const SizedBox(width: AppSpacing.sm),
                    if (product.categoryName != null) ...[
                      Flexible(
                        child: Text(
                          product.categoryName!,
                          style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: scheme.onSurfaceVariant),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                    const Spacer(),
                    if (!product.isActive)
                      const StatusBadge(label: 'Inactive', status: AppStatus.neutral),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
