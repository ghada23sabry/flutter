/// Manual camera capture for AI product recognition (M4-B).
///
/// Uses the `camera` plugin for on-demand image capture via `takePicture()`.
/// Barcode detection is handled server-side by the AI vision API — this screen
/// only captures the image and pops with the raw bytes.
library;

import 'dart:async';
import 'dart:typed_data';

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';

import '../../../core/theme/app_tokens.dart';
import '../../../core/widgets/app_button.dart';

/// Frame bytes and the optional barcode value (null when not barcode-triggered).
class CameraCaptureResult {
  const CameraCaptureResult({
    required this.imageBytes,
    this.barcodeValue,
  });

  final Uint8List imageBytes;
  final String? barcodeValue;
}

/// Full-screen camera with a manual shutter button.
/// Pops with [CameraCaptureResult] on capture.
class CameraCaptureScreen extends StatefulWidget {
  const CameraCaptureScreen({super.key});

  @override
  State<CameraCaptureScreen> createState() => _CameraCaptureScreenState();
}

class _CameraCaptureScreenState extends State<CameraCaptureScreen> {
  CameraController? _controller;
  bool _initializing = true;
  String? _error;
  bool _captured = false;

  @override
  void initState() {
    super.initState();
    _initCamera();
  }

  Future<void> _initCamera() async {
    try {
      final cameras = await availableCameras();
      if (cameras.isEmpty) {
        if (mounted) setState(() { _error = 'No camera found on this device.'; });
        return;
      }
      // Prefer the back camera.
      final camera = cameras.firstWhere(
        (c) => c.lensDirection == CameraLensDirection.back,
        orElse: () => cameras.first,
      );
      final controller = CameraController(
        camera,
        ResolutionPreset.high,
        enableAudio: false,
      );
      await controller.initialize();
      if (!mounted) {
        await controller.dispose();
        return;
      }
      setState(() { _controller = controller; _initializing = false; });
    } on CameraException catch (e) {
      if (!mounted) return;
      final message = switch (e.code) {
        'CameraAccessDenied' =>
          'Camera permission was denied. Enable camera access in device settings.',
        'CameraAccessDeniedWithoutPrompt' =>
          'Camera permission was previously denied. Please enable it in device settings.',
        'CameraAccessRestricted' =>
          'Camera access is restricted on this device.',
        _ => 'Camera could not be started (${e.code}).',
      };
      setState(() { _error = message; _initializing = false; });
    } catch (e) {
      if (mounted) setState(() { _error = 'Unexpected camera error: $e'; _initializing = false; });
    }
  }

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }

  Future<void> _takePicture() async {
    final controller = _controller;
    if (controller == null || !controller.value.isInitialized || _captured) return;
    _captured = true;
    try {
      final xFile = await controller.takePicture();
      final bytes = await xFile.readAsBytes();
      if (!mounted) return;
      Navigator.of(context).pop(CameraCaptureResult(imageBytes: bytes));
    } catch (e) {
      _captured = false;
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Capture failed: $e')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('AI Product Scan')),
      body: _buildBody(),
    );
  }

  Widget _buildBody() {
    if (_error != null) return _buildError();
    if (_initializing || _controller == null) {
      return const Center(child: CircularProgressIndicator());
    }
    return Column(
      children: [
        Expanded(
          child: CameraPreview(_controller!),
        ),
        Padding(
          padding: const EdgeInsets.all(AppSpacing.lg),
          child: Row(
            children: [
              const Icon(Icons.camera_alt_outlined, size: 20),
              const SizedBox(width: AppSpacing.md),
              const Expanded(
                child: Text(
                  'Point the camera at a product and tap Capture.',
                ),
              ),
              IconButton(
                tooltip: 'Torch',
                icon: const Icon(Icons.flashlight_on_outlined),
                onPressed: () => _toggleTorch(),
              ),
              const SizedBox(width: AppSpacing.sm),
              FilledButton.icon(
                onPressed: _takePicture,
                icon: const Icon(Icons.camera_alt, size: 18),
                label: const Text('Capture'),
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
      final mode = controller.value.flashMode == FlashMode.torch
          ? FlashMode.off
          : FlashMode.torch;
      await controller.setFlashMode(mode);
    } catch (_) {}
  }

  Widget _buildError() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.xl),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.no_photography_outlined, size: 48),
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
