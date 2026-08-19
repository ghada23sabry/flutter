import 'package:flutter/material.dart';

import '../../../core/api_client.dart';
import '../../../core/session.dart';
import '../../../core/theme/app_tokens.dart';
import '../../../core/util/app_format.dart';
import '../../../core/widgets/app_card.dart';
import '../../../core/widgets/empty_state.dart';
import '../../../core/widgets/error_state.dart';
import '../../../core/widgets/loading_state.dart';
import '../../../core/widgets/status_badge.dart';
import '../data/inventory_api.dart';
import '../data/inventory_models.dart';

/// Full stock movement history for the store (optionally one product).
class MovementsScreen extends StatefulWidget {
  const MovementsScreen({
    super.key,
    required this.api,
    required this.session,
    this.productId,
  });

  final InventoryApi api;
  final SessionController session;
  final String? productId;

  @override
  State<MovementsScreen> createState() => _MovementsScreenState();
}

class _MovementsScreenState extends State<MovementsScreen> {
  static const int _pageSize = 50;

  final _scrollController = ScrollController();

  final List<StockMovement> _movements = [];
  bool _loading = true;
  bool _loadingMore = false;
  String? _error;
  int _total = 0;
  int _page = 1;
  String? _typeFilter;

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_onScroll);
    _load();
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
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
      final page = await widget.api.listMovements(
        store: widget.session.selectedStore!,
        productId: widget.productId,
        movementType: _typeFilter,
        page: 1,
        pageSize: _pageSize,
      );
      if (!mounted) return;
      setState(() {
        _movements
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
        _error = e is ApiException
            ? e.message
            : 'Cannot reach the server. Check your connection.';
      });
    }
  }

  Future<void> _loadMore() async {
    if (_loading || _loadingMore || !(_movements.length < _total)) return;
    final nextPage = _page + 1;
    setState(() => _loadingMore = true);
    try {
      final page = await widget.api.listMovements(
        store: widget.session.selectedStore!,
        productId: widget.productId,
        movementType: _typeFilter,
        page: nextPage,
        pageSize: _pageSize,
      );
      if (!mounted) return;
      setState(() {
        _movements.addAll(page.items);
        _total = page.total;
        _page = page.page;
        _loadingMore = false;
      });
    } catch (_) {
      if (mounted) setState(() => _loadingMore = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Stock movements')),
      body: _buildBody(),
    );
  }

  Widget _buildBody() {
    if (_loading) return const LoadingState(message: 'Loading movements…');
    if (_error != null) return ErrorState(message: _error!, onRetry: _load);
    final scheme = Theme.of(context).colorScheme;
    return Column(
      children: [
        SizedBox(
          height: 40,
          child: ListView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(
              horizontal: AppSpacing.lg,
              vertical: AppSpacing.xs,
            ),
            children: [
              _TypeChip(
                'All',
                null,
                _typeFilter,
                () => setState(() {
                  _typeFilter = null;
                  _load();
                }),
              ),
              const SizedBox(width: AppSpacing.sm),
              _TypeChip(
                'Opening',
                MovementType.opening,
                _typeFilter,
                () => setState(() {
                  _typeFilter = MovementType.opening;
                  _load();
                }),
              ),
              const SizedBox(width: AppSpacing.sm),
              _TypeChip(
                'Adjustments',
                MovementType.adjustment,
                _typeFilter,
                () => setState(() {
                  _typeFilter = MovementType.adjustment;
                  _load();
                }),
              ),
              const SizedBox(width: AppSpacing.sm),
              _TypeChip(
                'Counts',
                MovementType.count,
                _typeFilter,
                () => setState(() {
                  _typeFilter = MovementType.count;
                  _load();
                }),
              ),
              const SizedBox(width: AppSpacing.sm),
              _TypeChip(
                'Sales',
                MovementType.sale,
                _typeFilter,
                () => setState(() {
                  _typeFilter = MovementType.sale;
                  _load();
                }),
              ),
              const SizedBox(width: AppSpacing.sm),
              _TypeChip(
                'Purchases',
                MovementType.purchase,
                _typeFilter,
                () => setState(() {
                  _typeFilter = MovementType.purchase;
                  _load();
                }),
              ),
              const SizedBox(width: AppSpacing.sm),
              _TypeChip(
                'Write offs',
                MovementType.writeOff,
                _typeFilter,
                () => setState(() {
                  _typeFilter = MovementType.writeOff;
                  _load();
                }),
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg),
          child: Row(
            children: [
              Text(
                '$_total movements',
                style: Theme.of(context).textTheme.labelMedium?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
        const Divider(height: 1),
        Expanded(
          child: _movements.isEmpty
              ? const EmptyState(
                  icon: Icons.swap_vert,
                  title: 'No movements yet',
                  message: 'Opening stock and adjustments will appear here.',
                )
              : RefreshIndicator(
                  onRefresh: _load,
                  child: ListView.separated(
                    controller: _scrollController,
                    padding: const EdgeInsets.all(AppSpacing.lg),
                    itemCount: _movements.length + (_loadingMore ? 1 : 0),
                    separatorBuilder: (_, _) =>
                        const SizedBox(height: AppSpacing.sm),
                    itemBuilder: (context, index) {
                      if (index >= _movements.length) {
                        return const Padding(
                          padding: EdgeInsets.symmetric(
                            vertical: AppSpacing.md,
                          ),
                          child: Center(
                            child: SizedBox(
                              width: 24,
                              height: 24,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            ),
                          ),
                        );
                      }
                      return _MovementTile(movement: _movements[index]);
                    },
                  ),
                ),
        ),
      ],
    );
  }
}

class _TypeChip extends StatelessWidget {
  const _TypeChip(this.label, this.value, this.selected, this.onTap);

  final String label;
  final String? value;
  final String? selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 2),
      child: FilterChip(
        label: Text(label),
        selected: value == selected,
        onSelected: (_) => onTap(),
        showCheckmark: false,
      ),
    );
  }
}

class _MovementTile extends StatelessWidget {
  const _MovementTile({required this.movement});

  final StockMovement movement;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final isIn = movement.quantityDelta >= 0;
    final color = isIn ? AppColors.success : AppColors.error;
    return AppCard(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.lg,
        vertical: AppSpacing.md,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  movement.productName,
                  style: Theme.of(context).textTheme.bodyLarge,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              const SizedBox(width: AppSpacing.sm),
              StatusBadge(
                label: MovementType.label(movement.movementType),
                status: switch (movement.movementType) {
                  MovementType.opening => AppStatus.info,
                  MovementType.count => AppStatus.info,
                  MovementType.purchase => AppStatus.success,
                  MovementType.sale => AppStatus.error,
                  MovementType.adjustment => AppStatus.neutral,
                  MovementType.writeOff => AppStatus.error,
                  _ => AppStatus.neutral,
                },
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.xs),
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      movement.sku,
                      style: Theme.of(context).textTheme.labelSmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                    if (movement.notes != null && movement.notes!.isNotEmpty)
                      Text(
                        movement.notes!,
                        style: Theme.of(context).textTheme.labelSmall?.copyWith(
                          color: scheme.onSurfaceVariant,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                  ],
                ),
              ),
              Text(
                AppFormat.signedQty(movement.quantityDelta),
                style: Theme.of(
                  context,
                ).textTheme.titleMedium?.copyWith(color: color),
              ),
              const SizedBox(width: AppSpacing.sm),
              if (movement.resultingQuantity != null)
                Text(
                  '→ ${AppFormat.qty(movement.resultingQuantity!)}',
                  style: Theme.of(context).textTheme.labelSmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
            ],
          ),
          const SizedBox(height: AppSpacing.xs),
          Text(
            '${movement.createdByName ?? 'Unknown'} · ${AppFormat.relativeDate(movement.createdAt)}',
            style: Theme.of(
              context,
            ).textTheme.labelSmall?.copyWith(color: scheme.onSurfaceVariant),
          ),
        ],
      ),
    );
  }
}
