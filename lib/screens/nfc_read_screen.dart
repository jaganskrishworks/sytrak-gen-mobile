import 'package:flutter/material.dart';
import 'package:nfc_manager/nfc_manager.dart';

import '../models.dart';
import '../services/nfc_writer.dart';
import '../services/station_client.dart';
import '../theme/app_colors.dart';

enum _Phase { ready, reading, done, failed }

/// "VERIFY NFC" - read a tag (nothing is written), compare it with the device the PC
/// expects and report the content to the PC. Pops with true when the tag matched.
class NfcReadScreen extends StatefulWidget {
  const NfcReadScreen({super.key, required this.client, required this.request});

  final StationClient client;
  final NfcReadRequest request;

  @override
  State<NfcReadScreen> createState() => _NfcReadScreenState();
}

class _NfcReadScreenState extends State<NfcReadScreen> {
  _Phase _phase = _Phase.ready;
  String _text = '';
  String _error = '';
  bool _reported = false;

  bool get _matches => _text.trim().toUpperCase() == widget.request.expected.toUpperCase();

  @override
  void initState() {
    super.initState();
    _read(); // start listening straight away - the operator just taps the tag
  }

  void _report({required bool ok, String text = '', String error = ''}) {
    if (_reported) return;
    _reported = true;
    widget.client.sendNfcReadResult(ok: ok, text: text, error: error);
  }

  Future<void> _read() async {
    final availability = await NfcWriter.availability();
    if (availability != NfcAvailability.enabled) {
      if (!mounted) return;
      setState(() {
        _phase = _Phase.failed;
        _error = availability == NfcAvailability.disabled ? 'NFC is turned off - enable it in phone settings' : 'This phone has no NFC';
      });
      return;
    }
    if (!mounted) return;
    setState(() => _phase = _Phase.reading);
    try {
      final text = await NfcWriter.readTag();
      _reported = false; // a fresh read always reports (also after "Read again")
      _report(ok: true, text: text);
      if (mounted) {
        setState(() {
          _text = text;
          _phase = _Phase.done;
        });
      }
    } on NfcWriteException catch (e) {
      if (mounted) {
        setState(() {
          _phase = _Phase.failed;
          _error = e.message;
        });
      }
    }
  }

  void _close() {
    if (_phase == _Phase.reading) NfcWriter.cancel();
    if (_phase != _Phase.done) _report(ok: false, error: _error.isEmpty ? 'Cancelled on phone' : _error);
    Navigator.of(context).pop(_phase == _Phase.done && _matches);
  }

  @override
  Widget build(BuildContext context) {
    final r = widget.request;
    final theme = Theme.of(context);
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _close();
      },
      child: Scaffold(
        appBar: AppBar(title: const Text('Verify NFC'), leading: IconButton(icon: const Icon(Icons.close), onPressed: _close)),
        body: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          const Icon(Icons.fact_check_rounded, color: AppColors.primary),
                          const SizedBox(width: 8),
                          Text('VERIFY NFC TAG  (read only)',
                              style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800, color: AppColors.primary, letterSpacing: 0.6)),
                        ],
                      ),
                      const Divider(height: 24),
                      const Text('Expected on the tag', style: TextStyle(color: AppColors.textSecondary)),
                      Text(r.expected,
                          style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w700, fontFamily: 'monospace', color: AppColors.textPrimary)),
                      if (r.seq.isNotEmpty) Text('SEQ  ${r.seq}', style: const TextStyle(fontSize: 16, color: AppColors.textSecondary)),
                    ],
                  ),
                ),
              ),
              const Spacer(),
              _phaseView(theme),
              const Spacer(),
              ..._actions(),
            ],
          ),
        ),
      ),
    );
  }

  Widget _phaseView(ThemeData theme) {
    Widget big(IconData icon, Color color, Color soft, String text) => Column(
          children: [
            Container(
              width: 140,
              height: 140,
              decoration: BoxDecoration(color: soft, shape: BoxShape.circle),
              child: Icon(icon, size: 72, color: color),
            ),
            const SizedBox(height: 20),
            Text(text, textAlign: TextAlign.center, style: TextStyle(fontSize: 17, fontWeight: FontWeight.w600, color: color)),
          ],
        );
    return switch (_phase) {
      _Phase.ready => big(Icons.nfc_rounded, AppColors.primary, AppColors.primarySoft, 'Starting NFC…'),
      _Phase.reading => Column(children: [
          const SizedBox(width: 72, height: 72, child: CircularProgressIndicator(strokeWidth: 6)),
          const SizedBox(height: 24),
          Text('Hold the NFC tag to the back of the phone…\nreading only - nothing is written',
              textAlign: TextAlign.center, style: theme.textTheme.titleMedium?.copyWith(color: AppColors.textSecondary)),
        ]),
      _Phase.done => _matches
          ? big(Icons.verified_rounded, AppColors.success, AppColors.successSoft, 'Tag matches\nReads: $_text\nThe PC has been notified')
          : big(Icons.cancel_rounded, AppColors.error, AppColors.errorSoft,
              'Wrong tag\nReads: ${_text.isEmpty ? '(empty)' : _text}\nExpected: ${widget.request.expected}'),
      _Phase.failed => big(Icons.error_rounded, AppColors.error, AppColors.errorSoft, _error),
    };
  }

  List<Widget> _actions() => switch (_phase) {
        _Phase.ready || _Phase.reading => [
            OutlinedButton(onPressed: _close, child: const Text('Cancel')),
          ],
        _Phase.done => [
            FilledButton(onPressed: _close, child: const Text('Done')),
            const SizedBox(height: 8),
            OutlinedButton.icon(onPressed: _read, icon: const Icon(Icons.refresh), label: const Text('Read again')),
          ],
        _Phase.failed => [
            FilledButton.icon(onPressed: _read, icon: const Icon(Icons.refresh), label: const Text('Try again')),
            const SizedBox(height: 8),
            OutlinedButton(onPressed: _close, child: const Text('Give up - report to PC')),
          ],
      };
}
