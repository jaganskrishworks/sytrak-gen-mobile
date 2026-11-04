import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../models.dart';

/// Finds SyTrak Gen stations on the LAN.
///
/// Stations broadcast a JSON beacon on UDP 47474 every 2 s and answer a
/// `SYTRAK_DISCOVER` request directly. Hosts entered manually are probed by
/// unicast, which also works where broadcasts are blocked (e.g. iOS without
/// the multicast entitlement).
class StationDiscovery extends ChangeNotifier {
  StationDiscovery({List<String> manualHosts = const []}) : _manualHosts = {...manualHosts};

  static const port = 47474;
  static const _staleAfter = Duration(seconds: 10);

  final Set<String> _manualHosts;
  final Map<String, Station> _stations = {};
  final Map<String, DateTime> _lastSeen = {};
  RawDatagramSocket? _socket;
  Timer? _timer;
  String? error;

  List<Station> get stations => _stations.values.toList()..sort((a, b) => a.name.compareTo(b.name));

  Future<void> start() async {
    if (_socket != null) return;
    try {
      _socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, port, reuseAddress: true);
    } on SocketException {
      // Port busy: still works for replies to our own requests.
      _socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
    }
    _socket!
      ..broadcastEnabled = true
      ..listen((event) {
        if (event != RawSocketEvent.read) return;
        final dg = _socket?.receive();
        if (dg != null) _onDatagram(dg);
      });
    probe();
    _timer = Timer.periodic(const Duration(seconds: 3), (_) {
      probe();
      _expire();
    });
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
    _socket?.close();
    _socket = null;
  }

  @override
  void dispose() {
    stop();
    super.dispose();
  }

  /// Sends a discovery request (broadcast + every manual host).
  void probe() {
    final request = utf8.encode('SYTRAK_DISCOVER');
    var sent = false;
    try {
      sent = (_socket?.send(request, InternetAddress('255.255.255.255'), port) ?? 0) > 0;
    } on SocketException {
      sent = false;
    }
    for (final host in _manualHosts) {
      try {
        _socket?.send(request, InternetAddress(host), port);
      } on Object {
        // invalid address or unreachable - ignore
      }
    }
    final newError = sent || _manualHosts.isNotEmpty ? null : 'Network broadcast blocked - add the PC by IP';
    if (newError != error) {
      error = newError;
      notifyListeners();
    }
  }

  /// Adds a station by IP (used when broadcasts don't reach the phone).
  void addHost(String host) {
    _manualHosts.add(host.trim());
    probe();
  }

  void _onDatagram(Datagram dg) {
    final text = utf8.decode(dg.data, allowMalformed: true);
    if (!text.startsWith('{')) return; // our own SYTRAK_DISCOVER echo
    final station = Station.fromBeacon(text, dg.address.address);
    if (station == null) return;
    _lastSeen[station.id] = DateTime.now();
    final old = _stations[station.id];
    _stations[station.id] = station;
    if (old == null || old.host != station.host || old.pairedWith != station.pairedWith || old.name != station.name) {
      notifyListeners();
    }
  }

  void _expire() {
    final now = DateTime.now();
    final stale = _lastSeen.entries.where((e) => now.difference(e.value) > _staleAfter).map((e) => e.key).toList();
    if (stale.isEmpty) return;
    for (final id in stale) {
      _stations.remove(id);
      _lastSeen.remove(id);
    }
    notifyListeners();
  }
}
