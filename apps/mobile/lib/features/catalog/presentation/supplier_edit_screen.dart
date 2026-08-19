import 'package:flutter/material.dart';

import '../../../core/api_client.dart';
import '../../../core/session.dart';
import '../../../core/theme/app_tokens.dart';
import '../../../core/widgets/app_button.dart';
import '../../../core/widgets/app_card.dart';
import '../../../core/widgets/app_input.dart';
import '../data/catalog_api.dart';
import '../data/catalog_models.dart';

/// Create or edit a supplier. In edit mode [existing] is non-null.
class SupplierEditScreen extends StatefulWidget {
  const SupplierEditScreen({super.key, required this.api, required this.session, this.existing});

  final CatalogApi api;
  final SessionController session;
  final Supplier? existing;

  @override
  State<SupplierEditScreen> createState() => _SupplierEditScreenState();
}

class _SupplierEditScreenState extends State<SupplierEditScreen> {
  final _formKey = GlobalKey<FormState>();

  late final TextEditingController _name;
  late final TextEditingController _contact;
  late final TextEditingController _email;
  late final TextEditingController _phone;
  late final TextEditingController _address;
  late final TextEditingController _notes;

  bool _isActive = true;
  bool _submitting = false;
  String? _submitError;

  bool get _isEditing => widget.existing != null;

  @override
  void initState() {
    super.initState();
    final s = widget.existing;
    _name = TextEditingController(text: s?.name ?? '');
    _contact = TextEditingController(text: s?.contactName ?? '');
    _email = TextEditingController(text: s?.email ?? '');
    _phone = TextEditingController(text: s?.phone ?? '');
    _address = TextEditingController(text: s?.address ?? '');
    _notes = TextEditingController(text: s?.notes ?? '');
    _isActive = s?.isActive ?? true;
  }

  @override
  void dispose() {
    _name.dispose();
    _contact.dispose();
    _email.dispose();
    _phone.dispose();
    _address.dispose();
    _notes.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() {
      _submitting = true;
      _submitError = null;
    });
    try {
      if (_isEditing) {
        final supplier = await widget.api.updateSupplier(
          id: widget.existing!.id,
          update: SupplierUpdate(
            name: _name.text.trim(),
            contactName: _contact.text.trim().isEmpty ? null : _contact.text.trim(),
            email: _email.text.trim().isEmpty ? null : _email.text.trim(),
            phone: _phone.text.trim().isEmpty ? null : _phone.text.trim(),
            address: _address.text.trim().isEmpty ? null : _address.text.trim(),
            notes: _notes.text.trim().isEmpty ? null : _notes.text.trim(),
            status: _isActive ? 'active' : 'inactive',
          ),
        );
        if (mounted) Navigator.of(context).pop(supplier);
      } else {
        final supplier = await widget.api.createSupplier(
          input: SupplierInput(
            name: _name.text.trim(),
            contactName: _contact.text.trim().isEmpty ? null : _contact.text.trim(),
            email: _email.text.trim().isEmpty ? null : _email.text.trim(),
            phone: _phone.text.trim().isEmpty ? null : _phone.text.trim(),
            address: _address.text.trim().isEmpty ? null : _address.text.trim(),
            notes: _notes.text.trim().isEmpty ? null : _notes.text.trim(),
          ),
        );
        if (mounted) Navigator.of(context).pop(supplier);
      }
    } on ApiException catch (e) {
      if (mounted) setState(() => _submitError = e.message);
    } catch (_) {
      if (mounted) {
        setState(() => _submitError = 'Cannot reach the server. Check your connection and try again.');
      }
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  String? _validateEmail(String? value) {
    final v = value?.trim() ?? '';
    if (v.isEmpty) return null;
    if (!RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$').hasMatch(v)) return 'Enter a valid email address';
    return null;
  }

  String? _required(String? value) {
    if (value == null || value.trim().isEmpty) return 'This field is required';
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: Text(_isEditing ? 'Edit Supplier' : 'New Supplier')),
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
                    Text('Details', style: Theme.of(context).textTheme.titleMedium),
                    const SizedBox(height: AppSpacing.lg),
                    AppInput(
                      label: 'Name *',
                      hintText: 'e.g. Acme Beverages',
                      controller: _name,
                      textInputAction: TextInputAction.next,
                      autofocus: !_isEditing,
                      validator: _required,
                    ),
                    const SizedBox(height: AppSpacing.md),
                    AppInput(
                      label: 'Contact name',
                      hintText: 'Optional',
                      controller: _contact,
                      textInputAction: TextInputAction.next,
                    ),
                    const SizedBox(height: AppSpacing.md),
                    AppInput(
                      label: 'Email',
                      hintText: 'orders@acme.com',
                      controller: _email,
                      keyboardType: TextInputType.emailAddress,
                      textInputAction: TextInputAction.next,
                      validator: _validateEmail,
                    ),
                    const SizedBox(height: AppSpacing.md),
                    AppInput(
                      label: 'Phone',
                      hintText: '+1 555 0100',
                      controller: _phone,
                      keyboardType: TextInputType.phone,
                      textInputAction: TextInputAction.next,
                    ),
                    const SizedBox(height: AppSpacing.md),
                    AppInput(
                      label: 'Address',
                      hintText: 'Optional',
                      controller: _address,
                      maxLines: 2,
                      textInputAction: TextInputAction.newline,
                    ),
                    const SizedBox(height: AppSpacing.md),
                    AppInput(
                      label: 'Notes',
                      hintText: 'Payment terms, minimum order, etc.',
                      controller: _notes,
                      maxLines: 3,
                      textInputAction: TextInputAction.newline,
                    ),
                    const SizedBox(height: AppSpacing.md),
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      title: const Text('Active'),
                      subtitle: Text(
                        _isActive ? 'Can be assigned to products' : 'Hidden from product forms',
                        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                              color: scheme.onSurfaceVariant,
                            ),
                      ),
                      value: _isActive,
                      onChanged: (v) => setState(() => _isActive = v),
                    ),
                  ],
                ),
              ),
              if (_submitError != null) ...[
                const SizedBox(height: AppSpacing.lg),
                Text(
                  _submitError!,
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: scheme.error),
                ),
              ],
              const SizedBox(height: AppSpacing.xl),
              AppButton(
                label: _isEditing ? 'Save changes' : 'Create supplier',
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
