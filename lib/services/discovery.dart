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
      try {
        _socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, port, reuseAddress: true);
      } on SocketException {
        // Port busy: still works for replies to our own requests.
        _socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
      }
    } on SocketException catch (e) {
      error = 'Network unavailable - check Wi-Fi (${e.osError?.message ?? e.message})';
      notifyListeners();
      return;
    }
    final socket = _socket!;
    socket
      ..broadcastEnabled = true
      ..listen(
        (event) {
          if (event == RawSocketEvent.closed) return _drop(socket);
          if (event != RawSocketEvent.read) return;
          final dg = socket.receive();
          if (dg != null) _onDatagram(dg);
        },
        // The OS can close the socket while the app is in the background: throw it away so the
        // next probe binds a new one (a dead socket would leave the list at "Searching…" forever).
        onError: (Object e) => _drop(socket),
        onDone: () => _drop(socket),
        cancelOnError: true,
      );
    // One timer only - start() is also called again from probe() after a dropped socket.
    _timer ??= Timer.periodic(const Duration(seconds: 3), (_) {
      probe();
      _expire();
    });
    probe();
  }

  void _drop(RawDatagramSocket socket) {
    if (!identical(_socket, socket)) return; // already replaced
    socket.close();
    _socket = null;
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
    final socket = _socket;
    _socket = null;
    socket?.close();
  }

  /// Fresh start: new socket, empty list, immediate probe (app resumed, pull to refresh).
  Future<void> restart() async {
    stop();
    _stations.clear();
    _lastSeen.clear();
    error = null;
    notifyListeners();
    await start();
  }

  /// Station with this id seen recently (its current address), else null.
  Station? find(String id) => _stations[id];

  @override
  void dispose() {
    stop();
    super.dispose();
  }

  /// Sends a discovery request: limited broadcast, a directed broadcast and
  /// (until a station answers) a unicast sweep of each local Wi-Fi /24, plus
  /// every manual host.
  ///
  /// The directed broadcast and sweep matter on Android: when the Wi-Fi has no
  /// internet the OS routes 255.255.255.255 over mobile data, where the send
  /// fails with EPERM. Subnet addresses still route over the Wi-Fi interface.
  Future<void> probe() async {
    if (_socket == null) {
      await start(); // bind failed earlier (e.g. no Wi-Fi) - retry
      return;
    }
    final request = utf8.encode('SYTRAK_DISCOVER');
    var sent = _send(request, '255.255.255.255');

    final prefixes = await _lanPrefixes();
    for (final prefix in prefixes) {
      sent = _send(request, '$prefix.255') || sent;
      if (_stations.isEmpty) {
        for (var i = 1; i < 255; i++) {
          sent = _send(request, '$prefix.$i') || sent;
        }
      }
    }
    for (final host in _manualHosts) {
      _send(request, host);
    }

    final String? newError;
    if (sent || _manualHosts.isNotEmpty) {
      newError = null;
    } else if (prefixes.isEmpty) {
      newError = 'Phone is not on Wi-Fi - connect to the same Wi-Fi as the PC';
    } else {
      newError = 'Network blocked discovery - add the PC by IP';
    }
    if (newError != error) {
      error = newError;
      notifyListeners();
    }
  }

  bool _send(List<int> data, String host) {
    try {
      return (_socket?.send(data, InternetAddress(host), port) ?? 0) > 0;
    } on Object {
      return false; // invalid address, unreachable or not permitted
    }
  }

  /// First three octets of each private IPv4 address on a Wi-Fi/Ethernet/hotspot
  /// interface (mobile data, VPN and loopback interfaces are skipped).
  static Future<List<String>> _lanPrefixes() async {
    const skip = ['rmnet', 'ccmni', 'v4-', 'tun', 'ppp', 'dummy', 'lo', 'clat'];
    try {
      final interfaces = await NetworkInterface.list(type: InternetAddressType.IPv4);
      final prefixes = <String>{};
      for (final iface in interfaces) {
        final name = iface.name.toLowerCase();
        if (skip.any(name.startsWith)) continue;
        for (final addr in iface.addresses) {
          final o = addr.address.split('.').map(int.tryParse).toList();
          if (o.length != 4 || o.contains(null)) continue;
          final private = o[0] == 10 || (o[0] == 172 && o[1]! >= 16 && o[1]! <= 31) || (o[0] == 192 && o[1] == 168);
          if (private) prefixes.add('${o[0]}.${o[1]}.${o[2]}');
        }
      }
      return prefixes.toList();
    } on Object {
      return const [];
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
