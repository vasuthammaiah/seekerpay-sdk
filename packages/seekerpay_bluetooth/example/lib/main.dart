/// seekerpay_bluetooth — example app.
///
/// Demonstrates P2P Solana Pay URL exchange via Google Nearby Connections.
/// One device advertises a payment request; the other discovers and connects.
///
/// Requires physical Android devices with Bluetooth and location enabled.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';
import 'package:seekerpay_bluetooth/seekerpay_bluetooth.dart';
import 'package:seekerpay_core/seekerpay_core.dart';
import 'package:seekerpay_qr/seekerpay_qr.dart';

void main() {
  // Configure the app identity shown in the wallet signing dialog.
  // Replace with your own app name and domain.
  MwaClient.instance.configure(
    identityName: 'seekerpay',
    identityUri: Uri.parse('https://seekerpay.live'),
  );
  runApp(const ProviderScope(child: _App()));
}

class _App extends StatelessWidget {
  const _App();
  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'seekerpay_bluetooth example',
        theme: ThemeData.dark(),
        home: const _HomeScreen(),
      );
}

class _HomeScreen extends ConsumerWidget {
  const _HomeScreen();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(nearbyServiceProvider);
    final nearby = ref.read(nearbyServiceProvider.notifier);

    // Show received URL when available
    if (state.receivedUrl != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Received: ${state.receivedUrl}'),
            duration: const Duration(seconds: 6),
          ),
        );
      });
    }

    return Scaffold(
      appBar: AppBar(title: const Text('seekerpay_bluetooth')),
      body: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Status badge
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              decoration: BoxDecoration(
                color: _statusColor(state.status).withOpacity(0.15),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: _statusColor(state.status).withOpacity(0.4)),
              ),
              child: Text(
                'Status: ${state.status.name.toUpperCase()}',
                style: TextStyle(color: _statusColor(state.status), fontWeight: FontWeight.w900, fontSize: 12),
              ),
            ),

            if (state.error != null) ...[
              const SizedBox(height: 8),
              Text(state.error!, style: const TextStyle(color: Colors.red, fontSize: 12)),
            ],

            const SizedBox(height: 24),

            // ADVERTISE side — sends a payment request to nearby discoverers
            const Text('ADVERTISE (sender)',
                style: TextStyle(fontSize: 10, fontWeight: FontWeight.w900, letterSpacing: 1.5, color: Colors.white54)),
            const SizedBox(height: 8),
            ElevatedButton(
              onPressed: state.status != NearbyStatus.idle ? null : () async {
                final granted = await nearby.checkPermissions();
                if (!granted) { await nearby.askPermissions(); return; }

                // Replace MY_WALLET_ADDRESS with real address
                final url = SolanaPayUrl(
                  recipient: 'MY_WALLET_ADDRESS',
                  amount: BigInt.from(1000000), // 1.00 SKR
                  splToken: SKRToken.mintAddress,
                ).encode();

                await nearby.startAdvertising('My Seeker', url);
              },
              child: const Text('Advertise Payment Request'),
            ),

            const SizedBox(height: 24),

            // DISCOVER side — finds nearby advertisers
            const Text('DISCOVER (receiver)',
                style: TextStyle(fontSize: 10, fontWeight: FontWeight.w900, letterSpacing: 1.5, color: Colors.white54)),
            const SizedBox(height: 8),
            ElevatedButton(
              onPressed: state.status != NearbyStatus.idle ? null : () async {
                final granted = await nearby.checkPermissions();
                if (!granted) { await nearby.askPermissions(); return; }
                await nearby.startDiscovery('My Seeker');
              },
              child: const Text('Start Discovery'),
            ),

            const SizedBox(height: 16),

            // Device list
            if (state.discoveredDevices.isNotEmpty) ...[
              const Text('Nearby devices:', style: TextStyle(fontSize: 11, color: Colors.white54)),
              const SizedBox(height: 8),
              ...state.discoveredDevices.map((device) => ListTile(
                leading: const Icon(Icons.phone_android),
                title: Text(device.name),
                subtitle: Text(device.id, style: const TextStyle(fontSize: 10, color: Colors.white38)),
                trailing: ElevatedButton(
                  onPressed: () => nearby.connectToDevice(device.id, 'My Seeker'),
                  child: const Text('Connect'),
                ),
              )),
            ],

            const Spacer(),

            // Stop all
            OutlinedButton(
              onPressed: state.status == NearbyStatus.idle ? null : nearby.stopAll,
              child: const Text('Stop All'),
            ),
          ],
        ),
      ),
    );
  }

  Color _statusColor(NearbyStatus s) => switch (s) {
        NearbyStatus.idle => Colors.white38,
        NearbyStatus.advertising => Colors.orange,
        NearbyStatus.discovering => Colors.blue,
        NearbyStatus.connecting => Colors.amber,
        NearbyStatus.connected => Colors.green,
        NearbyStatus.error => Colors.red,
      };
}
