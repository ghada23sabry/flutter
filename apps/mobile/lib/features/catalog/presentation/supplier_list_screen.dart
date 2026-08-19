import 'dart:async';

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
import '../data/catalog_api.dart';
import '../data/catalog_models.dart';
import 'supplier_detail_screen.dart';
import 'supplier_edit_screen.dart';

/// Paginated, searchable supplier list (tenant-scoped).
class SupplierListScreen extends StatefulWidget {
  const SupplierListScreen({super.key, required this.api, required this.session});

  final CatalogApi api;
  final SessionController session;

  @override
  State<SupplierListScreen> createState() => _SupplierListScreenState();
}

class _SupplierListScreenState extends State<SupplierListScreen> {
  static const int _pageSize = 30;

  final _searchController = TextEditingController();
  final _scrollController = ScrollController();

  final List<Supplier> _suppliers = [];
  bool _loading = true;
  bool _loadingMore = false;
  String? _error;
  int _total = 0;
  int _page = 1;
  bool _showInactive = false;
  Timer? _searchDebounce;

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
      final page = await widget.api.listSuppliers(
        q: _searchController.text.trim(),
        status: _showInactive ? null : 'active',
        page: 1,
        pageSize: _pageSize,
      );
      if (!mounted) return;
      setState(() {
        _suppliers
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
    if (_loading || _loadingMore || !(_suppliers.length < _total)) return;
    final nextPage = _page + 1;
    setState(() => _loadingMore = true);
    try {
      final page = await widget.api.listSuppliers(
        q: _searchController.text.trim(),
        status: _showInactive ? null : 'active',
        page: nextPage,
        pageSize: _pageSize,
      );
      if (!mounted) return;
      setState(() {
        _suppliers.addAll(page.items);
        _total = page.total;
        _page = page.page;
        _loadingMore = false;
      });
    } catch (_) {
      if (mounted) setState(() => _loadingMore = false);
    }
  }

  Future<void> _openAdd() async {
    final created = await Navigator.of(context).push<Supplier>(
      MaterialPageRoute(
        builder: (_) => SupplierEditScreen(api: widget.api, session: widget.session),
      ),
    );
    if (created != null && mounted) {
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(const SnackBar(content: Text('Supplier created')));
      _load();
    }
  }

  Future<void> _openDetail(Supplier supplier) async {
    final changed = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) => SupplierDetailScreen(
          api: widget.api,
          session: widget.session,
          supplierId: supplier.id,
        ),
      ),
    );
    if (changed == true && mounted) {
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(const SnackBar(content: Text('Supplier updated')));
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
                hintText: 'Search by name, contact, phone or email',
                prefixIcon: const Icon(Icons.search),
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
      floatingActionButton: widget.session.hasPermission(Permissions.suppliersManage)
          ? FloatingActionButton(
              tooltip: 'Add supplier',
              onPressed: _openAdd,
              child: const Icon(Icons.add),
            )
          : null,
    );
  }

  Widget _buildBody() {
    final scheme = Theme.of(context).colorScheme;
    if (_loading) return const LoadingState(message: 'Loading suppliers…');
    if (_error != null) return ErrorState(message: _error!, onRetry: _load);
    if (_suppliers.isEmpty) {
      return EmptyState(
        icon: Icons.local_shipping_outlined,
        title: 'No suppliers found',
        message: _searchController.text.trim().isNotEmpty
            ? 'No suppliers match "${_searchController.text.trim()}".'
            : 'Add your first supplier to track where products come from.',
        action: _searchController.text.trim().isNotEmpty
            ? null
            : (widget.session.hasPermission(Permissions.suppliersManage)
                ? AppButton(
                    label: 'Add supplier',
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
        itemCount: _suppliers.length + (_loadingMore ? 1 : 0),
        separatorBuilder: (_, _) => const SizedBox(height: AppSpacing.sm),
        itemBuilder: (context, index) {
          if (index >= _suppliers.length) {
            return const Padding(
              padding: EdgeInsets.symmetric(vertical: AppSpacing.md),
              child: Center(child: SizedBox(width: 24, height: 24, child: CircularProgressIndicator(strokeWidth: 2))),
            );
          }
          final supplier = _suppliers[index];
          return AppCard(
            onTap: () => _openDetail(supplier),
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
                  child: const Icon(Icons.local_shipping_outlined, size: 22),
                ),
                const SizedBox(width: AppSpacing.md),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(supplier.name, style: Theme.of(context).textTheme.bodyLarge),
                      const SizedBox(height: AppSpacing.xs),
                      Text(
                        supplier.contactName ?? supplier.email ?? '—',
                        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                              color: scheme.onSurfaceVariant,
                            ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ),
                ),
                if (!supplier.isActive)
                  const StatusBadge(label: 'Inactive', status: AppStatus.neutral),
              ],
            ),
          );
        },
      ),
    );
  }
}
