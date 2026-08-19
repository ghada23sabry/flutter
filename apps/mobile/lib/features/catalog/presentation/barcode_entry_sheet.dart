import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../core/barcode/barcode.dart';
import '../../../core/theme/app_tokens.dart';

/// Bottom sheet for manually entering a barcode. The real camera scanner
/// replaces the keypad path once the APK build lands.
class BarcodeEntrySheet extends StatefulWidget {
  const BarcodeEntrySheet({super.key});

  @override
  State<BarcodeEntrySheet> createState() => _BarcodeEntrySheetState();
}

class _BarcodeEntrySheetState extends State<BarcodeEntrySheet> {
  final _controller = TextEditingController();
  String? _error;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() {
    final raw = _controller.text;
    if (!isValidBarcode(raw)) {
      setState(() => _error = 'Enter at least 6 letters/digits (no spaces or symbols).');
      return;
    }
    Navigator.of(context).pop(normalizeBarcode(raw));
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: EdgeInsets.only(
        left: AppSpacing.lg,
        right: AppSpacing.lg,
        top: AppSpacing.xl,
        bottom: MediaQuery.viewInsetsOf(context).bottom + AppSpacing.xl,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('Enter barcode', style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: AppSpacing.xs),
          Text(
            'Camera scanning is coming soon — type the code for now.',
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: scheme.onSurfaceVariant),
          ),
          const SizedBox(height: AppSpacing.lg),
          TextField(
            controller: _controller,
            autofocus: true,
            textCapitalization: TextCapitalization.characters,
            inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[A-Za-z0-9]'))],
            keyboardType: TextInputType.text,
            textInputAction: TextInputAction.done,
            onSubmitted: (_) => _submit(),
            decoration: InputDecoration(
              labelText: 'Barcode',
              prefixIcon: const Icon(Icons.qr_code_2),
              errorText: _error,
              errorMaxLines: 2,
            ),
          ),
          const SizedBox(height: AppSpacing.xl),
          FilledButton(
            style: FilledButton.styleFrom(
              padding: const EdgeInsets.symmetric(vertical: AppSpacing.lg),
            ),
            onPressed: _submit,
            child: const Text('Look up'),
          ),
        ],
      ),
    );
  }
}

