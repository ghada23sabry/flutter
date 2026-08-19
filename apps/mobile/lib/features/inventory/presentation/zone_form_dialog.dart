import 'package:flutter/material.dart';

import '../../../core/api_client.dart';
import '../../../core/models/auth_models.dart';
import '../../../core/session.dart';
import '../../../core/theme/app_tokens.dart';
import '../../../core/widgets/app_input.dart';
import '../data/inventory_api.dart';
import '../data/inventory_models.dart';

/// Create or edit a store zone via a modal dialog.
///
/// - Create: name + optional code; the zone starts active.
/// - Edit: name, optional code and active/inactive status.
///
/// Returns the created/updated [Zone] on success, or null when cancelled.
/// Mutations are gated by `inventory.manage_layout` at the call site.
Future<Zone?> showZoneFormDialog({
  required BuildContext context,
  required InventoryApi api,
  required SessionController session,
  Zone? existing,
}) {
  return showDialog<Zone>(
    context: context,
    builder: (_) =>
        _ZoneFormDialog(api: api, session: session, existing: existing),
  );
}

class _ZoneFormDialog extends StatefulWidget {
  const _ZoneFormDialog({
    required this.api,
    required this.session,
    this.existing,
  });

  final InventoryApi api;
  final SessionController session;
  final Zone? existing;

  @override
  State<_ZoneFormDialog> createState() => _ZoneFormDialogState();
}

class _ZoneFormDialogState extends State<_ZoneFormDialog> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _name;
  late final TextEditingController _code;
  late String _status;
  bool _submitting = false;
  String? _submitError;

  bool get _isEdit => widget.existing != null;

  StoreInfo get _store => widget.session.selectedStore!;

  @override
  void initState() {
    super.initState();
    _name = TextEditingController(text: widget.existing?.name ?? '');
    _code = TextEditingController(text: widget.existing?.code ?? '');
    _status = widget.existing?.status ?? 'active';
  }

  @override
  void dispose() {
    _name.dispose();
    _code.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() {
      _submitting = true;
      _submitError = null;
    });
    final code = _code.text.trim();
    try {
      final zone = _isEdit
          ? await widget.api.updateZone(
              store: _store,
              zoneId: widget.existing!.id,
              name: _name.text.trim(),
              code: code.isEmpty ? null : code,
              status: _status,
            )
          : await widget.api.createZone(
              store: _store,
              name: _name.text.trim(),
              code: code.isEmpty ? null : code,
            );
      if (!mounted) return;
      Navigator.of(context).pop(zone);
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

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(_isEdit ? 'Edit zone' : 'New zone'),
      content: Form(
        key: _formKey,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              AppInput(
                label: 'Zone name',
                hintText: 'e.g. Frozen',
                controller: _name,
                autofocus: true,
                validator: (value) => (value == null || value.trim().isEmpty)
                    ? 'Name is required.'
                    : null,
              ),
              const SizedBox(height: AppSpacing.md),
              AppInput(
                label: 'Code (optional)',
                hintText: 'e.g. FZ',
                controller: _code,
              ),
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
