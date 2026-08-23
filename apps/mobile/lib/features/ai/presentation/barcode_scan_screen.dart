/// Barcode-only scanner screen using mobile_scanner.
///
/// Uses [MobileScannerController] with `returnImage: false` (barcode-only).
/// Camera ownership is exclusive — this screen does not share the camera
/// with [CameraCaptureScreen].
///
/// Lifecycle: the controller is created in [initState] with `autoStart: true`
/// (the default). The [MobileScanner] widget handles attaching the native
/// camera surface and starting the scan. Calling `controller.start()` before
/// the widget is in the tree causes `controllerNotAttached` — never do that.
library;

import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../../../core/theme/app_tokens.dart';
import '../../../core/widgets/app_button.dart';
import '../../../core/barcode/barcode.dart' show BarcodeScanResult;

/// Full-screen barcode scanner. Pops with [BarcodeScanResult] on detection.
class BarcodeScanScreen extends StatefulWidget {
  const BarcodeScanScreen({super.key});

  @override
  State<BarcodeScanScreen> createState() => _BarcodeScanScreenState();
}

class _BarcodeScanScreenState extends State<BarcodeScanScreen> {
  MobileScannerController? _controller;
  String? _error;
  bool _popped = false;

  @override
  void initState() {
    super.initState();
    _controller = MobileScannerController(
      facing: CameraFacing.back,
      detectionSpeed: DetectionSpeed.normal,
      returnImage: false,
    );
  }

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }

  void _onDetect(BarcodeCapture capture) {
    if (_popped) return;
    final barcode = capture.barcodes.firstOrNull;
    final value = barcode?.rawValue;
    if (value == null || value.isEmpty || !mounted) return;
    _popped = true;
    Navigator.of(context).pop(
      BarcodeScanResult(barcode: value, symbology: barcode?.format.name),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Scan Barcode')),
      body: _buildBody(),
    );
  }

  Widget _buildBody() {
    if (_error != null) return _buildError();
    final controller = _controller;
    if (controller == null) {
      return const Center(child: CircularProgressIndicator());
    }
    return Column(
      children: [
        Expanded(
          child: MobileScanner(
            controller: controller,
            onDetect: _onDetect,
            errorBuilder: _onScannerError,
          ),
        ),
        Padding(
          padding: const EdgeInsets.all(AppSpacing.lg),
          child: Row(
            children: [
              const Icon(Icons.qr_code_scanner, size: 20),
              const SizedBox(width: AppSpacing.md),
              const Expanded(
                child: Text('Point the camera at a barcode.'),
              ),
              IconButton(
                tooltip: 'Torch',
                icon: const Icon(Icons.flashlight_on_outlined),
                onPressed: _toggleTorch,
              ),
            ],
          ),
        ),
      ],
    );
  }

  Future<void> _toggleTorch() async {
    final controller = _controller;
    if (controller == null) return;
    try {
      await controller.toggleTorch();
    } catch (_) {}
  }

  Widget _onScannerError(
    BuildContext context,
    MobileScannerException error,
  ) {
    final message = switch (error.errorCode) {
      MobileScannerErrorCode.permissionDenied =>
        'Camera permission was denied. Enable camera access in device settings.',
      MobileScannerErrorCode.unsupported =>
        'Barcode scanning is not supported on this device.',
      _ => 'Scanner could not be started (${error.errorCode}).',
    };
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _error == null) setState(() => _error = message);
    });
    return const Center(child: CircularProgressIndicator());
  }

  Widget _buildError() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.xl),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.qr_code_scanner_outlined, size: 48),
            const SizedBox(height: AppSpacing.lg),
            Text(
              _error!,
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodyMedium,
            ),
            const SizedBox(height: AppSpacing.lg),
            AppButton(
              label: 'Back',
              icon: Icons.arrow_back,
              expand: false,
              onPressed: () => Navigator.of(context).pop(),
            ),
          ],
        ),
      ),
    );
  }
}
