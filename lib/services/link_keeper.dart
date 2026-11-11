import 'dart:async';

import 'package:flutter/widgets.dart';

import '../models.dart';
import 'discovery.dart';
import 'station_client.dart';

/// Keeps discovery and the station link alive across app switches.
///
/// While the app is in the background Android can freeze it, close its UDP socket and let the
/// MQTT connection die (the PC drops it after the keep-alive). On resume this restarts discovery
/// with a fresh socket and, if we were connected, reopens the link - at the station's current IP.
/// A watchdog also reopens a link that has been down for too long (auto-reconnect stuck on an old
/// IP or a dead network).
class LinkKeeper with WidgetsBindingObserver {
  LinkKeeper({required this.discovery, required this.client});

  final StationDiscovery discovery;
  final StationClient client;

  /// Away at least this long = the link is probably dead: reopen it instead of waiting.
  static const resumeReconnectAfter = Duration(seconds: 15);

  /// Link down at least this long while we want it = reopen it.
  static const stuckAfter = Duration(seconds: 15);

  DateTime? _pausedAt;
  DateTime? _downSince;
  Timer? _watchdog;
  bool _busy = false;

  void start() {
    WidgetsBinding.instance.addObserver(this);
    client.lookup = discovery.find;
    _watchdog = Timer.periodic(const Duration(seconds: 3), (_) => _check());
  }

  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _watchdog?.cancel();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    switch (state) {
      case AppLifecycleState.paused:
      case AppLifecycleState.hidden:
        _pausedAt ??= DateTime.now();
      case AppLifecycleState.resumed:
        final away = _pausedAt == null ? Duration.zero : DateTime.now().difference(_pausedAt!);
        _pausedAt = null;
        _onResumed(away);
      default:
        break;
    }
  }

  Future<void> _onResumed(Duration away) async {
    if (away == Duration.zero) return; // only inactive (dialog, NFC sheet) - nothing was lost
    await discovery.restart();
    if (client.wantsLink && (!client.isUp || away >= resumeReconnectAfter)) {
      await _reopen();
    }
  }

  void _check() {
    if (!client.wantsLink || client.isUp) {
      _downSince = null;
      return;
    }
    if (_pausedAt != null) return; // in the background - handled on resume
    final now = DateTime.now();
    _downSince ??= now;
    final seen = _current();
    final moved = seen != null && client.station != null && seen.host != client.station!.host;
    if (moved || now.difference(_downSince!) >= stuckAfter) _reopen();
  }

  /// The station as discovery sees it now (null = not heard yet).
  Station? _current() {
    final id = client.station?.id;
    return id == null ? null : discovery.find(id);
  }

  Future<void> _reopen() async {
    if (_busy) return;
    _busy = true;
    try {
      // Give discovery a moment to hear the station - its IP may have changed.
      for (var i = 0; i < 8 && _current() == null; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 500));
      }
      if (!client.wantsLink) return; // the user left meanwhile
      await client.reconnect(via: _current());
    } finally {
      _downSince = null;
      _busy = false;
    }
  }
}
