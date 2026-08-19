import 'package:flutter/material.dart';

import '../../../core/api_client.dart';
import '../../../core/models/auth_models.dart';
import '../../../core/permissions.dart';
import '../../../core/session.dart';
import '../../../core/theme/app_tokens.dart';
import '../../../core/widgets/app_card.dart';
import '../../../core/widgets/loading_state.dart';
import '../data/catalog_api.dart';
import '../data/catalog_models.dart';
import 'barcode_entry_sheet.dart';
import 'product_detail_screen.dart';
import 'product_edit_screen.dart';

/// Scan / lookup tab. Camera capture is deferred; manual barcode entry drives
/// the same lookup path.
class ScanScreen extends StatefulWidget {
  const ScanScreen({super.key, required this.api, required this.session});

  final CatalogApi api;
  final SessionController session;

  @override
  State<ScanScreen> createState() => _ScanScreenState();
}

class _ScanScreenState extends State<ScanScreen> {
  bool _lookingUp = false;
  String? _error;

  StoreInfo get _store => widget.session.selectedStore!;

  Future<void> _openEntry() async {
    final barcode = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      builder: (_) => const BarcodeEntrySheet(),
    );
    if (barcode == null || !mounted) return;
    setState(() {
      _lookingUp = true;
      _error = null;
    });
    try {
      final product = await widget.api.lookupByBarcode(
        store: _store,
        barcode: barcode,
      );
      if (!mounted) return;
      setState(() => _lookingUp = false);
      if (product != null) {
        await Navigator.of(context).push<bool>(
          MaterialPageRoute(
            builder: (_) => ProductDetailScreen(
              api: widget.api,
              session: widget.session,
              productId: product.id,
            ),
          ),
        );
      } else {
        _showNotFound(barcode);
      }
    } on ApiException catch (e) {
      if (mounted) {
        setState(() {
          _lookingUp = false;
          _error = e.message;
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _lookingUp = false;
          _error = 'Cannot reach the server. Check your connection.';
        });
      }
    }
  }

  void _showNotFound(String barcode) {
    final canAdd = widget.session.hasPermission(Permissions.productsManage);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('No product found for barcode "$barcode" in this store.'),
        action: canAdd
            ? SnackBarAction(
                label: 'Add',
                onPressed: () => _addProduct(barcode),
              )
            : null,
      ),
    );
  }

  Future<void> _addProduct(String barcode) async {
    await Navigator.of(context).push<Product>(
      MaterialPageRoute(
        builder: (_) => ProductEditScreen(
          api: widget.api,
          session: widget.session,
          initialBarcode: barcode,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      body: Padding(
        padding: const EdgeInsets.all(AppSpacing.xl),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Container(
              width: 120,
              height: 120,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: scheme.primaryContainer,
                shape: BoxShape.circle,
              ),
              child: Icon(
                Icons.qr_code_scanner,
                size: 56,
                color: scheme.onPrimaryContainer,
              ),
            ),
            const SizedBox(height: AppSpacing.xl),
            Text(
              'Scan a barcode',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.headlineMedium,
            ),
            const SizedBox(height: AppSpacing.sm),
            Text(
              'Camera scanning is coming soon. Enter a barcode to find the product.',
              textAlign: TextAlign.center,
              style: Theme.of(
                context,
              ).textTheme.bodyMedium?.copyWith(color: scheme.onSurfaceVariant),
            ),
            const SizedBox(height: AppSpacing.xl),
            AppCard(
              onTap: _lookingUp ? null : _openEntry,
              child: Row(
                children: [
                  Icon(Icons.keyboard_outlined, color: scheme.primary),
                  const SizedBox(width: AppSpacing.md),
                  Expanded(
                    child: Text(
                      'Enter barcode',
                      style: Theme.of(context).textTheme.bodyLarge,
                    ),
                  ),
                  Icon(Icons.chevron_right, color: scheme.onSurfaceVariant),
                ],
              ),
            ),
            if (_lookingUp) ...[
              const SizedBox(height: AppSpacing.xl),
              const LoadingState(message: 'Looking up product…', expand: false),
            ],
            if (_error != null) ...[
              const SizedBox(height: AppSpacing.xl),
              Text(
                _error!,
                textAlign: TextAlign.center,
                style: Theme.of(
                  context,
                ).textTheme.bodyMedium?.copyWith(color: scheme.error),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
