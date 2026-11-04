import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../theme/app_colors.dart';

/// Full-screen camera; pops with the first QR code's text.
class ScannerScreen extends StatefulWidget {
  const ScannerScreen({super.key});

  @override
  State<ScannerScreen> createState() => _ScannerScreenState();
}

class _ScannerScreenState extends State<ScannerScreen> {
  final _controller = MobileScannerController(
    detectionSpeed: DetectionSpeed.noDuplicates,
    formats: const [BarcodeFormat.qrCode],
  );
  bool _done = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _onDetect(BarcodeCapture capture) {
    if (_done) return;
    final value = capture.barcodes.map((b) => b.rawValue).whereType<String>().firstOrNull;
    if (value == null || value.isEmpty) return;
    _done = true;
    Navigator.of(context).pop(value);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.scannerBackground,
      extendBodyBehindAppBar: true,
      appBar: AppBar(
        title: const Text('QR Scanner'),
        backgroundColor: AppColors.transparent,
        foregroundColor: AppColors.scannerText,
        iconTheme: const IconThemeData(color: AppColors.scannerText),
        titleTextStyle: const TextStyle(fontSize: 20, fontWeight: FontWeight.w700, color: AppColors.scannerText),
        systemOverlayStyle: SystemUiOverlayStyle.light,
        actions: [
          IconButton(
            tooltip: 'Torch',
            icon: const Icon(Icons.flashlight_on_rounded),
            color: AppColors.scannerText,
            onPressed: _controller.toggleTorch,
          ),
        ],
      ),
      body: Stack(
        fit: StackFit.expand,
        children: [
          MobileScanner(
            controller: _controller,
            onDetect: _onDetect,
            errorBuilder: (context, error) => Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Text(
                  'Camera unavailable: ${error.errorCode.name}\nAllow camera access in the phone settings.',
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: AppColors.scannerText),
                ),
              ),
            ),
          ),
          Center(
            child: Container(
              width: 260,
              height: 260,
              decoration: BoxDecoration(
                border: Border.all(color: AppColors.scannerFrame, width: 3),
                borderRadius: BorderRadius.circular(24),
                boxShadow: const [BoxShadow(color: AppColors.scannerOverlay, spreadRadius: 1000)],
              ),
            ),
          ),
          Positioned(
            left: 24,
            right: 24,
            bottom: 56,
            child: Center(
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
                decoration: BoxDecoration(color: AppColors.primary, borderRadius: BorderRadius.circular(30)),
                child: const Text(
                  'Point the camera at the device QR code',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: AppColors.onPrimary, fontSize: 15, fontWeight: FontWeight.w600),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
