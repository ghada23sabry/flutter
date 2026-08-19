import 'package:flutter/material.dart';

import '../../../core/api_client.dart';
import '../../../core/models/auth_models.dart';
import '../../../core/session.dart';
import '../../../core/theme/app_tokens.dart';
import '../../../core/widgets/app_button.dart';
import '../../../core/widgets/app_card.dart';
import '../../../core/widgets/app_input.dart';
import '../data/catalog_api.dart';
import '../data/catalog_models.dart';

/// Create or edit a store category. In edit mode [existing] is non-null.
class CategoryEditScreen extends StatefulWidget {
  const CategoryEditScreen({
    super.key,
    required this.api,
    required this.session,
    this.existing,
  });

  final CatalogApi api;
  final SessionController session;
  final Category? existing;

  @override
  State<CategoryEditScreen> createState() => _CategoryEditScreenState();
}

class _CategoryEditScreenState extends State<CategoryEditScreen> {
  final _formKey = GlobalKey<FormState>();

  late final TextEditingController _name;
  late final TextEditingController _code;

  List<Category> _categories = [];
  String? _parentId;
  bool _isActive = true;
  bool _submitting = false;
  String? _submitError;

  bool get _isEditing => widget.existing != null;

  StoreInfo get _store => widget.session.selectedStore!;

  @override
  void initState() {
    super.initState();
    final c = widget.existing;
    _name = TextEditingController(text: c?.name ?? '');
    _code = TextEditingController(text: c?.code ?? '');
    _parentId = c?.parentId;
    _isActive = c?.isActive ?? true;
    _loadCategories();
  }

  @override
  void dispose() {
    _name.dispose();
    _code.dispose();
    super.dispose();
  }

  Future<void> _loadCategories() async {
    try {
      final categories = await widget.api.listCategories(store: _store);
      if (mounted) {
        setState(() {
          // Exclude self so the parent picker cannot form a cycle (the backend
          // enforces this too).
          _categories = [
            for (final c in categories)
              if (c.id != widget.existing?.id) c,
          ];
        });
      }
    } catch (_) {
      // Parent picker degrades to "No parent"; category save still works.
    }
  }

  String? _required(String? value) {
    if (value == null || value.trim().isEmpty) return 'This field is required';
    return null;
  }

  String? _validateCode(String? value) {
    final v = value?.trim() ?? '';
    if (v.isEmpty) return null;
    if (v.length > 40) return 'Must be 40 characters or fewer';
    return null;
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() {
      _submitting = true;
      _submitError = null;
    });
    try {
      if (_isEditing) {
        final c = widget.existing!;
        final category = await widget.api.updateCategory(
          store: _store,
          id: c.id,
          update: CategoryUpdate(
            name: _name.text.trim(),
            code: _code.text.trim().isEmpty ? null : _code.text.trim(),
            parentId: _parentId,
            clearParent: c.parentId != null && _parentId == null,
            status: _isActive ? 'active' : 'inactive',
          ),
        );
        if (mounted) Navigator.of(context).pop(category);
      } else {
        final category = await widget.api.createCategory(
          store: _store,
          input: CategoryInput(
            name: _name.text.trim(),
            code: _code.text.trim().isEmpty ? null : _code.text.trim(),
            parentId: _parentId,
          ),
        );
        if (mounted) Navigator.of(context).pop(category);
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

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: Text(_isEditing ? 'Edit Category' : 'New Category'),
      ),
      body: SafeArea(
        child: Form(
          key: _formKey,
          child: ListView(
            padding: const EdgeInsets.all(AppSpacing.lg),
            children: [
              AppCard(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Details',
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    const SizedBox(height: AppSpacing.lg),
                    AppInput(
                      label: 'Name *',
                      hintText: 'e.g. Dairy',
                      controller: _name,
                      textInputAction: TextInputAction.next,
                      autofocus: !_isEditing,
                      validator: _required,
                    ),
                    const SizedBox(height: AppSpacing.md),
                    AppInput(
                      label: 'Code',
                      hintText: 'Optional, e.g. DAIRY',
                      controller: _code,
                      textInputAction: TextInputAction.next,
                      validator: _validateCode,
                    ),
                    const SizedBox(height: AppSpacing.md),
                    DropdownButtonFormField<String>(
                      key: const Key('category-parent-field'),
                      initialValue: _parentId,
                      decoration: const InputDecoration(
                        labelText: 'Parent category',
                        hintText: 'No parent',
                      ),
                      isExpanded: true,
                      items: [
                        const DropdownMenuItem<String>(
                          value: null,
                          child: Text('No parent'),
                        ),
                        for (final c in _categories)
                          DropdownMenuItem<String>(
                            value: c.id,
                            child: Text(c.name),
                          ),
                      ],
                      onChanged: (v) => setState(() => _parentId = v),
                    ),
                    if (_isEditing) ...[
                      const SizedBox(height: AppSpacing.md),
                      SwitchListTile(
                        contentPadding: EdgeInsets.zero,
                        title: const Text('Active'),
                        subtitle: Text(
                          _isActive
                              ? 'Can be assigned to products'
                              : 'Hidden from product forms',
                          style: Theme.of(context).textTheme.bodyMedium
                              ?.copyWith(color: scheme.onSurfaceVariant),
                        ),
                        value: _isActive,
                        onChanged: (v) => setState(() => _isActive = v),
                      ),
                    ],
                  ],
                ),
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
              const SizedBox(height: AppSpacing.xl),
              AppButton(
                label: _isEditing ? 'Save changes' : 'Create category',
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
