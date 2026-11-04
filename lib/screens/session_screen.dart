import 'dart:async';

import 'package:flutter/material.dart';

import '../models.dart';
import '../services/station_client.dart';
import '../theme/app_colors.dart';
import 'nfc_write_screen.dart';
import 'scanner_screen.dart';

/// Connected to a station: scan QR -> details -> send to device. NFC write
/// requests from the station open the write screen automatically.
class SessionScreen extends StatefulWidget {
  const SessionScreen({super.key, required this.client});

  final StationClient client;

  @override
  State<SessionScreen> createState() => _SessionScreenState();
}

class _SessionScreenState extends State<SessionScreen> {
  QrData? _scanned;
  bool _sent = false;
  bool _nfcOpen = false;
  late final StreamSubscription<NfcWriteRequest> _nfcSub;

  StationClient get client => widget.client;

  @override
  void initState() {
    super.initState();
    _nfcSub = client.nfcRequests.listen(_openNfcWrite);
  }

  @override
  void dispose() {
    _nfcSub.cancel();
    super.dispose();
  }

  Future<void> _openNfcWrite(NfcWriteRequest request) async {
    if (_nfcOpen || !mounted) return;
    _nfcOpen = true;
    final written = await Navigator.of(context).push<bool>(
      MaterialPageRoute(builder: (_) => NfcWriteScreen(client: client, request: request)),
    );
    _nfcOpen = false;
    if (written == true && mounted) {
      setState(() {
        _scanned = null;
        _sent = false;
      });
    }
  }

  Future<void> _scan() async {
    final raw = await Navigator.of(context).push<String>(MaterialPageRoute(builder: (_) => const ScannerScreen()));
    if (raw == null || !mounted) return;
    setState(() {
      _scanned = QrData.parse(raw);
      _sent = false;
    });
  }

  void _send() {
    final qr = _scanned;
    if (qr == null) return;
    if (client.sendScan(qr.raw)) {
      setState(() => _sent = true);
    } else {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Not paired with the PC yet')));
    }
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: client,
      builder: (context, _) => Scaffold(
        appBar: AppBar(
          title: Text(client.station?.name ?? 'Station'),
          actions: [
            IconButton(tooltip: 'Disconnect', icon: const Icon(Icons.link_off), onPressed: () => Navigator.pop(context)),
          ],
        ),
        body: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            _StatusCard(client: client),
            const SizedBox(height: 20),
            FilledButton.icon(
              onPressed: _scan,
              icon: const Icon(Icons.qr_code_scanner_rounded, size: 26),
              label: Text(_scanned == null ? 'Scan QR' : 'Scan again'),
              style: FilledButton.styleFrom(
                minimumSize: const Size.fromHeight(64),
                textStyle: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
              ),
            ),
            if (_scanned != null) ...[
              const SizedBox(height: 20),
              _QrDetailsCard(qr: _scanned!),
              const SizedBox(height: 16),
              FilledButton.icon(
                onPressed: client.isPaired && _scanned!.isSyTrak ? _send : null,
                icon: const Icon(Icons.send),
                label: const Text('Send to Device'),
                style: FilledButton.styleFrom(backgroundColor: AppColors.success, foregroundColor: AppColors.onPrimary),
              ),
              if (_sent) ...[const SizedBox(height: 12), _AckBanner(ack: client.lastAck)],
            ],
          ],
        ),
      ),
    );
  }
}

class _StatusCard extends StatelessWidget {
  const _StatusCard({required this.client});

  final StationClient client;

  @override
  Widget build(BuildContext context) {
    final (IconData icon, Color color, Color soft, String title, String detail) = switch (client.state) {
      LinkState.paired => (
          Icons.check_circle_rounded,
          AppColors.success,
          AppColors.successSoft,
          'Connected to ${client.station?.name}',
          'Scan a device QR code to verify it.',
        ),
      LinkState.connected => (
          Icons.hourglass_top_rounded,
          AppColors.warning,
          AppColors.warningSoft,
          'Waiting for the PC',
          'On the PC: Verify QR → select "${client.mobileName}" → Connect',
        ),
      LinkState.connecting => (Icons.sync_rounded, AppColors.primary, AppColors.primarySoft, 'Connecting…', client.error ?? ''),
      _ => (Icons.error_rounded, AppColors.error, AppColors.errorSoft, 'Not connected', client.error ?? 'Go back and pick the station again.'),
    };
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            Container(
              width: 52,
              height: 52,
              decoration: BoxDecoration(color: soft, borderRadius: BorderRadius.circular(14)),
              child: Icon(icon, color: color, size: 30),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title, style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: color)),
                  if (detail.isNotEmpty) ...[
                    const SizedBox(height: 4),
                    Text(detail, style: const TextStyle(fontSize: 13, color: AppColors.textSecondary)),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _QrDetailsCard extends StatelessWidget {
  const _QrDetailsCard({required this.qr});

  final QrData qr;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    Widget row(String label, String value) => Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Row(
            children: [
              SizedBox(width: 56, child: Text(label, style: const TextStyle(color: AppColors.textSecondary, fontWeight: FontWeight.w600))),
              Expanded(
                child: Text(value,
                    style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w700, fontFamily: 'monospace', color: AppColors.textPrimary)),
              ),
            ],
          ),
        );
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.qr_code_2_rounded, color: AppColors.primary),
                const SizedBox(width: 8),
                Text('QR Details', style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
              ],
            ),
            const Divider(height: 24),
            if (qr.isSyTrak) ...[row('MAC', qr.mac!), if (qr.seq != null) row('SEQ', qr.seq!)] else
              const Text('Not a SyTrak QR code', style: TextStyle(color: AppColors.error, fontWeight: FontWeight.w600)),
            const SizedBox(height: 10),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(color: AppColors.surfaceMuted, borderRadius: BorderRadius.circular(10)),
              child: Text(qr.raw, style: theme.textTheme.bodySmall?.copyWith(color: AppColors.textSecondary)),
            ),
          ],
        ),
      ),
    );
  }
}

class _AckBanner extends StatelessWidget {
  const _AckBanner({required this.ack});

  final ScanAck? ack;

  @override
  Widget build(BuildContext context) {
    final (IconData icon, Color color, Color soft, String text) = switch (ack) {
      null => (Icons.schedule_rounded, AppColors.neutral, AppColors.neutralSoft, 'Sent - waiting for the PC…'),
      ScanAck(accepted: true) => (Icons.check_rounded, AppColors.success, AppColors.successSoft, 'Received by the PC - verifying…'),
      ScanAck(:final reason) => (Icons.block_rounded, AppColors.error, AppColors.errorSoft, 'Rejected: $reason'),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(color: soft, borderRadius: BorderRadius.circular(12)),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(icon, color: color),
          const SizedBox(width: 8),
          Flexible(child: Text(text, style: TextStyle(color: color, fontWeight: FontWeight.w600))),
        ],
      ),
    );
  }
}
