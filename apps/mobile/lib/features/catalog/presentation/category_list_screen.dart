import 'package:flutter/material.dart';

import '../../../core/api_client.dart';
import '../../../core/models/auth_models.dart';
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
import 'category_edit_screen.dart';

/// Store-scoped category list. The backend endpoint is not paginated, so the
/// full store category set is loaded in one request.
class CategoryListScreen extends StatefulWidget {
  const CategoryListScreen({
    super.key,
    required this.api,
    required this.session,
  });

  final CatalogApi api;
  final SessionController session;

  @override
  State<CategoryListScreen> createState() => _CategoryListScreenState();
}

class _CategoryListScreenState extends State<CategoryListScreen> {
  final List<Category> _categories = [];
  bool _loading = true;
  String? _error;
  bool _showInactive = false;

  StoreInfo get _store => widget.session.selectedStore!;

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
      final categories = await widget.api.listCategories(
        store: _store,
        status: _showInactive ? null : 'active',
      );
      if (!mounted) return;
      setState(() {
        _categories
          ..clear()
          ..addAll(categories);
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

  Future<void> _openEdit([Category? category]) async {
    final saved = await Navigator.of(context).push<Category>(
      MaterialPageRoute(
        builder: (_) => CategoryEditScreen(
          api: widget.api,
          session: widget.session,
          existing: category,
        ),
      ),
    );
    if (saved != null && mounted) {
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(
          SnackBar(
            content: Text(
              category == null ? 'Category created' : 'Category updated',
            ),
          ),
        );
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
            padding: const EdgeInsets.symmetric(
              horizontal: AppSpacing.lg,
              vertical: AppSpacing.xs,
            ),
            child: Row(
              children: [
                TextButton.icon(
                  onPressed: () => setState(() {
                    _showInactive = !_showInactive;
                    _load();
                  }),
                  icon: Icon(
                    _showInactive
                        ? Icons.check_box
                        : Icons.check_box_outline_blank,
                    size: 18,
                  ),
                  label: const Text('Show inactive'),
                ),
                const Spacer(),
                Text(
                  _loading ? 'Updating…' : '${_categories.length} total',
                  style: Theme.of(context).textTheme.labelMedium?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          Expanded(child: _buildBody()),
        ],
      ),
      floatingActionButton:
          widget.session.hasPermission(Permissions.categoriesManage)
          ? FloatingActionButton(
              tooltip: 'Add category',
              onPressed: () => _openEdit(),
              child: const Icon(Icons.add),
            )
          : null,
    );
  }

  Widget _buildBody() {
    if (_loading) return const LoadingState(message: 'Loading categories…');
    if (_error != null) return ErrorState(message: _error!, onRetry: _load);
    if (_categories.isEmpty) {
      return EmptyState(
        icon: Icons.category_outlined,
        title: 'No categories found',
        message: _showInactive
            ? 'No inactive categories in this store.'
            : 'Add your first category to organize products.',
        action: widget.session.hasPermission(Permissions.categoriesManage)
            ? AppButton(
                label: 'Add category',
                onPressed: () => _openEdit(),
                expand: false,
                icon: Icons.add,
              )
            : null,
      );
    }
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView.separated(
        padding: const EdgeInsets.all(AppSpacing.lg),
        itemCount: _categories.length,
        separatorBuilder: (_, _) => const SizedBox(height: AppSpacing.sm),
        itemBuilder: (context, index) {
          final category = _categories[index];
          return AppCard(
            onTap: () => _openEdit(category),
            padding: const EdgeInsets.symmetric(
              horizontal: AppSpacing.lg,
              vertical: AppSpacing.md,
            ),
            child: Row(
              children: [
                Container(
                  width: 44,
                  height: 44,
                  decoration: BoxDecoration(
                    color: Theme.of(
                      context,
                    ).colorScheme.surfaceContainerHighest,
                    borderRadius: BorderRadius.circular(AppRadius.md),
                  ),
                  child: const Icon(Icons.category_outlined, size: 22),
                ),
                const SizedBox(width: AppSpacing.md),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        category.name,
                        style: Theme.of(context).textTheme.bodyLarge,
                      ),
                      const SizedBox(height: AppSpacing.xs),
                      Text(
                        category.code ?? '—',
                        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ),
                ),
                if (!category.isActive)
                  const StatusBadge(
                    label: 'Inactive',
                    status: AppStatus.neutral,
                  ),
              ],
            ),
          );
        },
      ),
    );
  }
}
