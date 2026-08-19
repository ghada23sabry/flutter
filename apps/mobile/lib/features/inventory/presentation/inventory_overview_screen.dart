import 'dart:async';

import 'package:flutter/material.dart' hide Page;

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
import '../../catalog/data/catalog_models.dart' show Page;
import '../../ai/data/ai_api.dart';
import '../../ai/data/ai_models.dart' show AiScanOperation;
import '../../ai/presentation/ai_count_screen.dart';
import '../data/inventory_api.dart';
import '../data/inventory_models.dart';
import 'expiry_list_screen.dart';
import 'movements_screen.dart';
import 'shelves_list_screen.dart';
import 'stock_detail_screen.dart';
import 'zones_list_screen.dart';

/// Inventory dashboard: summary metrics + searchable/filterable stock list.
class InventoryOverviewScreen extends StatefulWidget {
  const InventoryOverviewScreen({
    super.key,
    required this.api,
    required this.session,
  });

  final InventoryApi api;
  final SessionController session;

  @override
  State<InventoryOverviewScreen> createState() =>
      _InventoryOverviewScreenState();
}

class _InventoryOverviewScreenState extends State<InventoryOverviewScreen> {
  static const int _pageSize = 30;

  final _searchController = TextEditingController();
  final _scrollController = ScrollController();

  final List<StockItem> _items = [];
  StockSummary? _summary;
  bool _loading = true;
  bool _loadingMore = false;
  String? _error;
  int _total = 0;
  int _page = 1;
  String? _statusFilter;
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
    if (_scrollController.position.pixels >=
        _scrollController.position.maxScrollExtent - 200) {
      _loadMore();
    }
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final results = await Future.wait([
        widget.api.listStock(
          store: _store,
          q: _searchController.text.trim(),
          stockStatus: _statusFilter,
          page: 1,
          pageSize: _pageSize,
        ),
        widget.api.getStockSummary(store: _store),
      ]);
      if (!mounted) return;
      setState(() {
        final page = results[0] as Page<StockItem>;
        _items
          ..clear()
          ..addAll(page.items);
        _total = page.total;
        _page = page.page;
        _summary = results[1] as StockSummary;
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

  Future<void> _loadMore() async {
    if (_loading || _loadingMore || !(_items.length < _total)) return;
    final nextPage = _page + 1;
    setState(() => _loadingMore = true);
    try {
      final page = await widget.api.listStock(
        store: _store,
        q: _searchController.text.trim(),
        stockStatus: _statusFilter,
        page: nextPage,
        pageSize: _pageSize,
      );
      if (!mounted) return;
      setState(() {
        _items.addAll(page.items);
        _total = page.total;
        _page = page.page;
        _loadingMore = false;
      });
    } catch (_) {
      if (mounted) setState(() => _loadingMore = false);
    }
  }

  void _openDetail(StockItem item) async {
    final changed = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) => StockDetailScreen(
          api: widget.api,
          session: widget.session,
          productId: item.productId,
          initialName: item.productName,
        ),
      ),
    );
    if (changed == true && mounted) _load();
  }

  void _openMovements() {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) =>
            MovementsScreen(api: widget.api, session: widget.session),
      ),
    );
  }

  void _openExpiry([String? status]) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => ExpiryListScreen(
          api: widget.api,
          session: widget.session,
          initialStatus: status,
        ),
      ),
    );
  }

  void _openZones() {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) =>
            ZonesListScreen(api: widget.api, session: widget.session),
      ),
    );
  }

  void _openShelves() {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) =>
            ShelvesListScreen(api: widget.api, session: widget.session),
      ),
    );
  }

  Future<void> _openAiCount() async {
    final changed = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) => AiCountScreen(
          aiApi: AiApi(widget.session.apiClient),
          inventoryApi: widget.api,
          session: widget.session,
        ),
      ),
    );
    if (changed == true && mounted) _load();
  }

  Future<void> _openAiWithOperation(AiScanOperation op) async {
    final changed = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) => AiCountScreen(
          aiApi: AiApi(widget.session.apiClient),
          inventoryApi: widget.api,
          session: widget.session,
          initialOperation: op,
        ),
      ),
    );
    if (changed == true && mounted) _load();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final session = widget.session;
    return Scaffold(
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
          SizedBox(
            height: 40,
            child: ListView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(
                horizontal: AppSpacing.lg,
                vertical: AppSpacing.xs,
              ),
              children: [
                _FilterChip(
                  'All',
                  null,
                  _statusFilter,
                  () => setState(() {
                    _statusFilter = null;
                    _load();
                  }),
                ),
                const SizedBox(width: AppSpacing.sm),
                _FilterChip(
                  'Healthy',
                  StockStatus.healthy,
                  _statusFilter,
                  () => setState(() {
                    _statusFilter = StockStatus.healthy;
                    _load();
                  }),
                ),
                const SizedBox(width: AppSpacing.sm),
                _FilterChip(
                  'Low stock',
                  StockStatus.lowStock,
                  _statusFilter,
                  () => setState(() {
                    _statusFilter = StockStatus.lowStock;
                    _load();
                  }),
                ),
                const SizedBox(width: AppSpacing.sm),
                _FilterChip(
                  'Out of stock',
                  StockStatus.outOfStock,
                  _statusFilter,
                  () => setState(() {
                    _statusFilter = StockStatus.outOfStock;
                    _load();
                  }),
                ),
              ],
            ),
          ),
          Row(
            children: [
              const SizedBox(width: AppSpacing.lg),
              Expanded(
                child: Text(
                  _loading ? 'Updating…' : '$_total products',
                  style: Theme.of(context).textTheme.labelMedium?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ),
              if (session.hasPermission(Permissions.aiScan) &&
                  session.selectedStore != null) ...[
                TextButton.icon(
                  onPressed: _openAiCount,
                  icon: const Icon(Icons.auto_awesome_outlined, size: 18),
                  label: const Text('AI Count'),
                ),
                const SizedBox(width: AppSpacing.xs),
                TextButton.icon(
                  onPressed: () => _openAiWithOperation(AiScanOperation.sale),
                  icon: const Icon(Icons.camera_alt_outlined, size: 18),
                  label: const Text('AI Sale'),
                ),
                const SizedBox(width: AppSpacing.xs),
                TextButton.icon(
                  onPressed: () => _openAiWithOperation(AiScanOperation.receive),
                  icon: const Icon(Icons.camera_alt_outlined, size: 18),
                  label: const Text('AI Receive'),
                ),
              ],
              const SizedBox(width: AppSpacing.xs),
              if (session.hasPermission(Permissions.inventoryMovements))
                TextButton.icon(
                  onPressed: _openMovements,
                  icon: const Icon(Icons.swap_vert, size: 18),
                  label: const Text('Movements'),
                ),
              const SizedBox(width: AppSpacing.xs),
              if (session.hasPermission(Permissions.inventoryView)) ...[
                TextButton.icon(
                  onPressed: _openExpiry,
                  icon: const Icon(Icons.event_note_outlined, size: 18),
                  label: const Text('Expiry'),
                ),
                const SizedBox(width: AppSpacing.xs),
                TextButton.icon(
                  onPressed: _openZones,
                  icon: const Icon(Icons.grid_view_outlined, size: 18),
                  label: const Text('Layout'),
                ),
                const SizedBox(width: AppSpacing.xs),
                TextButton.icon(
                  onPressed: _openShelves,
                  icon: const Icon(Icons.storefront_outlined, size: 18),
                  label: const Text('Shelves'),
                ),
                const SizedBox(width: AppSpacing.lg),
              ],
            ],
          ),
          const Divider(height: 1),
          Expanded(child: _buildBody()),
        ],
      ),
    );
  }

  Widget _buildBody() {
    if (_loading) return const LoadingState(message: 'Loading inventory…');
    if (_error != null) {
      return ErrorState(message: _error!, onRetry: _load);
    }
    final summary = _summary;
    if (summary == null) {
      return ErrorState(message: 'No summary available.', onRetry: _load);
    }
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        controller: _scrollController,
        padding: const EdgeInsets.all(AppSpacing.lg),
        children: [
          _SummaryGrid(
            summary: summary,
            currency: _store.currency,
            onStatusTap: (status) {
              setState(() {
                _statusFilter = status;
                _load();
              });
            },
            onExpiryTap: _openExpiry,
          ),
          const SizedBox(height: AppSpacing.md),
          if (_items.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: AppSpacing.xxl),
              child: EmptyState(
                icon: Icons.inventory_2_outlined,
                title: 'No stock found',
                message: _searchController.text.trim().isNotEmpty
                    ? 'No products match "${_searchController.text.trim()}".'
                    : 'Set opening stock for a product to start tracking inventory.',
              ),
            )
          else ...[
            for (final item in _items)
              Padding(
                padding: const EdgeInsets.only(bottom: AppSpacing.sm),
                child: _StockItemTile(
                  item: item,
                  currency: _store.currency,
                  onTap: () => _openDetail(item),
                ),
              ),
            if (_loadingMore)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: AppSpacing.md),
                child: Center(
                  child: SizedBox(
                    width: 24,
                    height: 24,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                ),
              ),
          ],
        ],
      ),
    );
  }
}

class _FilterChip extends StatelessWidget {
  const _FilterChip(this.label, this.value, this.selected, this.onTap);

  final String label;
  final String? value;
  final String? selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final active = value == selected;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 2),
      child: FilterChip(
        label: Text(label),
        selected: active,
        onSelected: (_) => onTap(),
        showCheckmark: false,
      ),
    );
  }
}

class _SummaryGrid extends StatelessWidget {
  const _SummaryGrid({
    required this.summary,
    required this.currency,
    required this.onStatusTap,
    required this.onExpiryTap,
  });

  final StockSummary summary;
  final String currency;
  final ValueChanged<String?> onStatusTap;

  /// Opens the expiry list pre-filtered to the tapped risk status.
  final ValueChanged<String?> onExpiryTap;

  @override
  Widget build(BuildContext context) {
    final tiles = <_SummaryTile>[
      _SummaryTile(
        label: 'Total products',
        value: AppFormat.integer(summary.totalProducts),
        icon: Icons.inventory_2_outlined,
        onTap: () => onStatusTap(null),
      ),
      _SummaryTile(
        label: 'Inventory value',
        value: AppFormat.money(summary.totalValue, currency: currency),
        icon: Icons.payments_outlined,
      ),
      _SummaryTile(
        label: 'Healthy',
        value: AppFormat.integer(summary.healthy),
        icon: Icons.check_circle_outline,
        status: AppStatus.success,
        onTap: () => onStatusTap(StockStatus.healthy),
      ),
      _SummaryTile(
        label: 'Low stock',
        value: AppFormat.integer(summary.lowStock),
        icon: Icons.trending_down,
        status: AppStatus.warning,
        onTap: () => onStatusTap(StockStatus.lowStock),
      ),
      _SummaryTile(
        label: 'Out of stock',
        value: AppFormat.integer(summary.outOfStock),
        icon: Icons.remove_circle_outline,
        status: AppStatus.error,
        onTap: () => onStatusTap(StockStatus.outOfStock),
      ),
      _SummaryTile(
        label: 'Near expiry',
        value: AppFormat.integer(summary.nearExpiry),
        icon: Icons.schedule_outlined,
        status: AppStatus.warning,
        onTap: () => onExpiryTap('near_expiry'),
      ),
      _SummaryTile(
        label: 'Expired',
        value: AppFormat.integer(summary.expired),
        icon: Icons.event_busy_outlined,
        status: AppStatus.error,
        onTap: () => onExpiryTap('expired'),
      ),
    ];
    return GridView.count(
      crossAxisCount: 2,
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      mainAxisSpacing: AppSpacing.sm,
      crossAxisSpacing: AppSpacing.sm,
      childAspectRatio: 1.9,
      children: tiles,
    );
  }
}

class _SummaryTile extends StatelessWidget {
  const _SummaryTile({
    required this.label,
    required this.value,
    required this.icon,
    this.status,
    this.onTap,
  });

  final String label;
  final String value;
  final IconData icon;
  final AppStatus? status;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final iconColor = switch (status) {
      AppStatus.success => AppColors.success,
      AppStatus.warning => AppColors.warning,
      AppStatus.error => AppColors.error,
      _ => scheme.primary,
    };
    return AppCard(
      onTap: onTap,
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.md,
        vertical: AppSpacing.md,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Row(
            children: [
              Icon(icon, size: 18, color: iconColor),
              const SizedBox(width: AppSpacing.sm),
              Expanded(
                child: Text(
                  label,
                  style: Theme.of(context).textTheme.labelMedium?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
          Text(
            value,
            style: Theme.of(context).textTheme.titleLarge,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ],
      ),
    );
  }
}

class _StockItemTile extends StatelessWidget {
  const _StockItemTile({
    required this.item,
    required this.currency,
    required this.onTap,
  });

  final StockItem item;
  final String currency;
  final VoidCallback onTap;

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
                    Expanded(
                      child: Text(
                        item.productName,
                        style: Theme.of(context).textTheme.bodyLarge,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    const SizedBox(width: AppSpacing.sm),
                    Text(
                      item.sku,
                      style: Theme.of(context).textTheme.labelSmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: AppSpacing.xs),
                Row(
                  children: [
                    Text(
                      item.quantityLabel,
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    const SizedBox(width: AppSpacing.sm),
                    Text(
                      AppFormat.money(item.value, currency: currency),
                      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                    const Spacer(),
                    StatusBadge(
                      label: StockStatus.label(item.stockStatus),
                      status: _statusOf(item.stockStatus),
                    ),
                  ],
                ),
                if (item.expiryTrackingEnabled &&
                    item.nearestExpiryDate != null) ...[
                  const SizedBox(height: AppSpacing.xs),
                  Row(
                    children: [
                      Icon(
                        item.nearestExpiryStatus == 'expired'
                            ? Icons.event_busy
                            : Icons.schedule,
                        size: 14,
                        color: item.nearestExpiryStatus == 'expired'
                            ? AppColors.error
                            : AppColors.warning,
                      ),
                      const SizedBox(width: AppSpacing.xs),
                      Text(
                        'Expires ${_date(item.nearestExpiryDate!)}',
                        style: Theme.of(context).textTheme.labelSmall?.copyWith(
                          color: item.nearestExpiryStatus == 'expired'
                              ? AppColors.error
                              : AppColors.warning,
                        ),
                      ),
                    ],
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  AppStatus _statusOf(String status) => switch (status) {
    StockStatus.lowStock => AppStatus.warning,
    StockStatus.outOfStock => AppStatus.error,
    _ => AppStatus.success,
  };

  String _date(DateTime d) =>
      '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
}
