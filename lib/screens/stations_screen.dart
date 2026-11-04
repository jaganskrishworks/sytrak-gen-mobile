import 'package:flutter/material.dart';

import '../models.dart';
import '../services/discovery.dart';
import '../services/identity.dart';
import '../services/station_client.dart';
import '../theme/app_colors.dart';
import 'session_screen.dart';

/// Home: name this phone and connect to a SyTrak Gen station on the network.
class StationsScreen extends StatefulWidget {
  const StationsScreen({super.key, required this.identity, required this.discovery, required this.client});

  final Identity identity;
  final StationDiscovery discovery;
  final StationClient client;

  @override
  State<StationsScreen> createState() => _StationsScreenState();
}

class _StationsScreenState extends State<StationsScreen> {
  String? _connectingId;

  @override
  void initState() {
    super.initState();
    widget.discovery.start();
  }

  Future<void> _editName() async {
    final ctrl = TextEditingController(text: widget.identity.name);
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Phone name'),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          decoration: const InputDecoration(helperText: 'Shown on the PC when you connect'),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, ctrl.text), child: const Text('Save')),
        ],
      ),
    );
    if (name != null && name.trim().isNotEmpty) {
      setState(() => widget.identity.name = name);
      widget.client.mobileName = name.trim();
    }
  }

  Future<void> _addByIp() async {
    final ctrl = TextEditingController();
    final host = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Add PC by IP address'),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          decoration: const InputDecoration(hintText: '192.168.1.103', helperText: 'Shown on the PC: Verify QR → mobile server'),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, ctrl.text.trim()), child: const Text('Add')),
        ],
      ),
    );
    if (host == null || host.isEmpty) return;
    widget.identity.addManualHost(host);
    widget.discovery.addHost(host);
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Looking for a station at $host…')));
    }
  }

  Future<String?> _askPassword(Station s) async {
    final ctrl = TextEditingController(text: widget.identity.passwordFor(s.id));
    return showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Password for ${s.name}'),
        content: TextField(controller: ctrl, obscureText: true, autofocus: true),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, ctrl.text), child: const Text('Connect')),
        ],
      ),
    );
  }

  Future<void> _connect(Station s) async {
    var password = '';
    if (s.auth) {
      final entered = await _askPassword(s);
      if (entered == null) return;
      password = entered;
    }
    setState(() => _connectingId = s.id);
    final ok = await widget.client.connect(s, password: password);
    if (!mounted) return;
    setState(() => _connectingId = null);
    if (!ok) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(widget.client.error ?? 'Connection failed')));
      return;
    }
    if (s.auth) widget.identity.savePassword(s.id, password);
    await Navigator.of(context).push(MaterialPageRoute(builder: (_) => SessionScreen(client: widget.client)));
    await widget.client.disconnect();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('SyTrak Gen')),
      body: ListenableBuilder(
        listenable: widget.discovery,
        builder: (context, _) {
          final stations = widget.discovery.stations;
          return RefreshIndicator(
            onRefresh: () async => widget.discovery.probe(),
            color: AppColors.primary,
            child: ListView(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
              children: [
                _PhoneHeader(name: widget.identity.name, id: widget.identity.id, onEdit: _editName),
                const SizedBox(height: 28),
                Text('Connect to a SyTrak Gen station', style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
                const SizedBox(height: 4),
                Text('Phone and PC must be on the same Wi-Fi.', style: theme.textTheme.bodySmall?.copyWith(color: AppColors.textSecondary)),
                const SizedBox(height: 16),
                if (stations.isEmpty)
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 28),
                      child: Column(
                        children: [
                          const SizedBox(width: 32, height: 32, child: CircularProgressIndicator(strokeWidth: 3)),
                          const SizedBox(height: 16),
                          Text(
                            widget.discovery.error ?? 'Searching for stations…',
                            textAlign: TextAlign.center,
                            style: theme.textTheme.bodyMedium?.copyWith(color: AppColors.textSecondary),
                          ),
                        ],
                      ),
                    ),
                  ),
                for (final s in stations) ...[
                  _StationTile(
                    station: s,
                    myId: widget.identity.id,
                    busy: _connectingId == s.id,
                    onTap: _connectingId == null ? () => _connect(s) : null,
                  ),
                  const SizedBox(height: 10),
                ],
                const SizedBox(height: 12),
                OutlinedButton.icon(onPressed: _addByIp, icon: const Icon(Icons.add), label: const Text('Add PC by IP address')),
              ],
            ),
          );
        },
      ),
    );
  }
}

class _PhoneHeader extends StatelessWidget {
  const _PhoneHeader({required this.name, required this.id, required this.onEdit});

  final String name;
  final String id;
  final VoidCallback onEdit;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        gradient: AppColors.primaryGradient,
        borderRadius: BorderRadius.circular(20),
        boxShadow: const [BoxShadow(color: AppColors.shadow, blurRadius: 24, offset: Offset(0, 10))],
      ),
      child: Row(
        children: [
          Container(
            width: 52,
            height: 52,
            decoration: BoxDecoration(color: AppColors.onPrimary.withValues(alpha: 0.18), borderRadius: BorderRadius.circular(14)),
            child: const Icon(Icons.smartphone_rounded, color: AppColors.onPrimary, size: 28),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('THIS PHONE',
                    style: TextStyle(color: AppColors.onPrimary.withValues(alpha: 0.75), fontSize: 11, fontWeight: FontWeight.w700, letterSpacing: 1.2)),
                const SizedBox(height: 4),
                Text(name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: AppColors.onPrimary, fontSize: 20, fontWeight: FontWeight.w700)),
                const SizedBox(height: 2),
                Text('ID $id', style: TextStyle(color: AppColors.onPrimary.withValues(alpha: 0.8), fontSize: 13)),
              ],
            ),
          ),
          IconButton(
            onPressed: onEdit,
            tooltip: 'Rename',
            icon: const Icon(Icons.edit_rounded),
            style: IconButton.styleFrom(
              foregroundColor: AppColors.onPrimary,
              backgroundColor: AppColors.onPrimary.withValues(alpha: 0.18),
            ),
          ),
        ],
      ),
    );
  }
}

class _StationTile extends StatelessWidget {
  const _StationTile({required this.station, required this.myId, required this.busy, this.onTap});

  final Station station;
  final String myId;
  final bool busy;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final inUse = station.pairedWith.isNotEmpty && station.pairedWith != myId;
    final (label, color, soft) = station.pairedWith == myId
        ? ('Yours', AppColors.primary, AppColors.primarySoft)
        : inUse
            ? ('In use', AppColors.warning, AppColors.warningSoft)
            : ('Free', AppColors.success, AppColors.successSoft);
    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            children: [
              Container(
                width: 48,
                height: 48,
                decoration: BoxDecoration(color: AppColors.primarySoft, borderRadius: BorderRadius.circular(14)),
                child: const Icon(Icons.desktop_windows_rounded, color: AppColors.primary),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Flexible(
                          child: Text(station.name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: AppColors.textPrimary)),
                        ),
                        if (station.auth) ...[
                          const SizedBox(width: 6),
                          const Icon(Icons.lock_rounded, size: 15, color: AppColors.textMuted),
                        ],
                      ],
                    ),
                    const SizedBox(height: 4),
                    Text(station.id, style: const TextStyle(fontSize: 13, color: AppColors.textSecondary)),
                    Text('${station.host}:${station.port}', style: const TextStyle(fontSize: 12, color: AppColors.textMuted)),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              busy
                  ? const SizedBox(width: 24, height: 24, child: CircularProgressIndicator(strokeWidth: 2.5))
                  : Container(
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                      decoration: BoxDecoration(color: soft, borderRadius: BorderRadius.circular(20)),
                      child: Text(label, style: TextStyle(color: color, fontSize: 12, fontWeight: FontWeight.w700)),
                    ),
            ],
          ),
        ),
      ),
    );
  }
}
