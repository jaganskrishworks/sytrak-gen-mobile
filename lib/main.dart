import 'package:flutter/material.dart';

import 'screens/stations_screen.dart';
import 'services/discovery.dart';
import 'services/identity.dart';
import 'services/link_keeper.dart';
import 'services/station_client.dart';
import 'theme/app_theme.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final identity = await Identity.load();
  final discovery = StationDiscovery(manualHosts: identity.manualHosts);
  final client = StationClient(mobileId: identity.id, mobileName: identity.name);
  LinkKeeper(discovery: discovery, client: client).start(); // recover after app switches
  runApp(SyTrakApp(identity: identity, discovery: discovery, client: client));
}

class SyTrakApp extends StatelessWidget {
  const SyTrakApp({super.key, required this.identity, required this.discovery, required this.client});

  final Identity identity;
  final StationDiscovery discovery;
  final StationClient client;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'SyTrak Gen',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.light,
      home: StationsScreen(identity: identity, discovery: discovery, client: client),
    );
  }
}
