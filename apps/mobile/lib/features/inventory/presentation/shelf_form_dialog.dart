import 'package:flutter/material.dart';

import '../../../core/api_client.dart';
import '../../../core/models/auth_models.dart';
import '../../../core/session.dart';
import '../../../core/theme/app_tokens.dart';
import '../../../core/widgets/app_input.dart';
import '../data/inventory_api.dart';
import '../data/inventory_models.dart';

/// Create or edit a store shelf via a modal dialog.
///
/// - Create: label, optional code, position and the zone the shelf belongs to.
/// - Edit: label, optional code, position, zone (re-zone) and active/inactive status.
///
/// Returns the created/updated [Shelf] on success, or null when cancelled.
/// Mutations are gated by `inventory.manage_layout` at the call site.
Future<Shelf?> showShelfFormDialog({
  required BuildContext context,
  required InventoryApi api,
  required SessionController session,
  Shelf? existing,
  String? defaultZoneId,
}) {
  return showDialog<Shelf>(
    context: context,
    builder: (_) => _ShelfFormDialog(
      api: api,
      session: session,
      existing: existing,
      defaultZoneId: defaultZoneId,
    ),
  );
}

class _ShelfFormDialog extends StatefulWidget {
  const _ShelfFormDialog({
    required this.api,
    required this.session,
    this.existing,
    this.defaultZoneId,
  });

  final InventoryApi api;
  final SessionController session;
  final Shelf? existing;
  final String? defaultZoneId;

  @override
  State<_ShelfFormDialog> createState() => _ShelfFormDialogState();
}

class _ShelfFormDialogState extends State<_ShelfFormDialog> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _label;
  late final TextEditingController _code;
  late final TextEditingController _position;
  late String? _zoneId;
  late String _status;
  late Future<List<Zone>> _zonesFuture;
  bool _submitting = false;
  String? _submitError;

  bool get _isEdit => widget.existing != null;

  StoreInfo get _store => widget.session.selectedStore!;

  @override
  void initState() {
    super.initState();
    final existing = widget.existing;
    _label = TextEditingController(text: existing?.label ?? '');
    _code = TextEditingController(text: existing?.code ?? '');
    _position = TextEditingController(
      text: (existing?.position ?? 0).toString(),
    );
    _zoneId = existing?.zoneId ?? widget.defaultZoneId;
    _status = existing?.status ?? 'active';
    _zonesFuture = _loadZones();
  }

  @override
  void dispose() {
    _label.dispose();
    _code.dispose();
    _position.dispose();
    super.dispose();
  }

  Future<List<Zone>> _loadZones() => widget.api.listZones(store: _store);

  void _retryZones() => setState(() => _zonesFuture = _loadZones());

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;
    if (!_isEdit && _zoneId == null) {
      setState(() => _submitError = 'Select a zone.');
      return;
    }
    setState(() {
      _submitting = true;
      _submitError = null;
    });
    final code = _code.text.trim();
    final position = int.tryParse(_position.text.trim()) ?? 0;
    try {
      final shelf = _isEdit
          ? await widget.api.updateShelf(
              store: _store,
              shelfId: widget.existing!.id,
              zoneId: _zoneId,
              label: _label.text.trim(),
              code: code.isEmpty ? null : code,
              position: position,
              status: _status,
            )
          : await widget.api.createShelf(
              store: _store,
              zoneId: _zoneId!,
              label: _label.text.trim(),
              code: code.isEmpty ? null : code,
              position: position,
            );
      if (!mounted) return;
      Navigator.of(context).pop(shelf);
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _submitting = false;
        _submitError = e.message;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _submitting = false;
        _submitError = 'Cannot reach the server. Check your connection.';
      });
    }
  }

  Widget _zoneField() {
    return FutureBuilder<List<Zone>>(
      future: _zonesFuture,
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                'Could not load zones.',
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: Theme.of(context).colorScheme.error,
                ),
              ),
              const SizedBox(height: AppSpacing.sm),
              OutlinedButton.icon(
                onPressed: _retryZones,
                icon: const Icon(Icons.refresh),
                label: const Text('Retry'),
              ),
            ],
          );
        }
        if (!snapshot.hasData) {
          return const SizedBox(
            height: 56,
            child: Center(child: CircularProgressIndicator()),
          );
        }
        return DropdownButtonFormField<String>(
          initialValue: _zoneId,
          decoration: const InputDecoration(labelText: 'Zone'),
          isExpanded: true,
          items: [
            for (final zone in snapshot.data!)
              DropdownMenuItem(value: zone.id, child: Text(zone.name)),
          ],
          onChanged: (v) => setState(() => _zoneId = v),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(_isEdit ? 'Edit shelf' : 'New shelf'),
      content: Form(
        key: _formKey,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              AppInput(
                label: 'Shelf label',
                hintText: 'e.g. Frozen A',
                controller: _label,
                autofocus: true,
                validator: (value) => (value == null || value.trim().isEmpty)
                    ? 'Label is required.'
                    : null,
              ),
              const SizedBox(height: AppSpacing.md),
              AppInput(
                label: 'Code (optional)',
                hintText: 'e.g. FRZ-A',
                controller: _code,
              ),
              const SizedBox(height: AppSpacing.md),
              AppInput(
                label: 'Position',
                hintText: '0',
                controller: _position,
                keyboardType: TextInputType.number,
                validator: (value) {
                  if (value == null || value.trim().isEmpty) {
                    return 'Position is required.';
                  }
                  if (int.tryParse(value.trim()) == null) {
                    return 'Enter a whole number.';
                  }
                  return null;
                },
              ),
              const SizedBox(height: AppSpacing.md),
              _zoneField(),
              if (_isEdit) ...[
                const SizedBox(height: AppSpacing.md),
                DropdownButtonFormField<String>(
                  initialValue: _status,
                  decoration: const InputDecoration(labelText: 'Status'),
                  isExpanded: true,
                  items: const [
                    DropdownMenuItem(value: 'active', child: Text('Active')),
                    DropdownMenuItem(
                      value: 'inactive',
                      child: Text('Inactive'),
                    ),
                  ],
                  onChanged: (v) => setState(() => _status = v!),
                ),
              ],
              if (_submitError != null) ...[
                const SizedBox(height: AppSpacing.md),
                Text(
                  _submitError!,
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: Theme.of(context).colorScheme.error,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _submitting ? null : () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _submitting ? null : _submit,
          child: Text(_isEdit ? 'Save' : 'Create'),
        ),
      ],
    );
  }
}
