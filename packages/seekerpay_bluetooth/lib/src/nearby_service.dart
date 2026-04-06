import 'dart:typed_data';

import 'package:flutter_riverpod/legacy.dart';
import 'package:nearby_connections/nearby_connections.dart';
import 'package:permission_handler/permission_handler.dart';

/// Lifecycle states for a Nearby Connections session.
enum NearbyStatus { idle, advertising, discovering, connecting, connected, error, deniedPermissions, locationDisabled }

/// Represents a Nearby Connections peer discovered during discovery.
class NearbyDevice {
  /// Unique endpoint ID assigned by the Nearby Connections framework.
  final String id;

  /// Human-readable display name advertised by the peer.
  final String name;

  NearbyDevice(this.id, this.name);
}

/// Immutable snapshot of the Nearby Connections session state.
class NearbyState {
  /// Current session status.
  final NearbyStatus status;

  /// Peers discovered during the current discovery session.
  final List<NearbyDevice> discoveredDevices;

  /// Error message from the last failed operation, if any.
  final String? error;

  /// The Solana Pay URL received from a connected peer, if any.
  final String? receivedUrl;

  /// Whether the device location service is enabled (required for Nearby).
  final bool isLocationEnabled;

  NearbyState({
    this.status = NearbyStatus.idle,
    this.discoveredDevices = const [],
    this.error,
    this.receivedUrl,
    this.isLocationEnabled = true,
  });

  /// Returns a copy of this state with the provided fields replaced.
  NearbyState copyWith({
    NearbyStatus? status,
    List<NearbyDevice>? discoveredDevices,
    String? error,
    String? receivedUrl,
    bool? isLocationEnabled,
  }) {
    return NearbyState(
      status: status ?? this.status,
      discoveredDevices: discoveredDevices ?? this.discoveredDevices,
      error: error,
      receivedUrl: receivedUrl ?? this.receivedUrl,
      isLocationEnabled: isLocationEnabled ?? this.isLocationEnabled,
    );
  }
}

/// Riverpod [StateNotifier] that manages Nearby Connections advertising,
/// discovery, and peer-to-peer Solana Pay URL exchange over Bluetooth/WiFi.
class NearbyService extends StateNotifier<NearbyState> {
  /// Nearby Connections topology used for all sessions.
  final Strategy strategy = Strategy.P2P_CLUSTER;
  String? _currentPayload;
  void Function()? _onUrlSent;

  NearbyService() : super(NearbyState());

  /// Requests all required runtime permissions and checks that the location
  /// service is enabled. Returns `true` only when all are granted.
  Future<bool> checkPermissions() async {
    final status = await [
      Permission.bluetoothScan,
      Permission.bluetoothAdvertise,
      Permission.bluetoothConnect,
      Permission.location,
      Permission.nearbyWifiDevices,
    ].request();
    
    bool allGranted = status.values.every((s) => s.isGranted);
    
    // Check if location service is enabled
    bool locationEnabled = await Permission.location.serviceStatus.isEnabled;
    state = state.copyWith(
      isLocationEnabled: locationEnabled,
      status: !allGranted ? NearbyStatus.deniedPermissions : (locationEnabled ? state.status : NearbyStatus.locationDisabled),
    );
    
    return allGranted && locationEnabled;
  }

  /// Requests Nearby Connections runtime permissions without returning a result.
  Future<void> askPermissions() async {
    await checkPermissions();
  }

  /// Begins advertising this device as [userName] and prepares [solanaPayUrl]
  /// to be sent automatically when a peer connects.
  Future<void> startAdvertising(String userName, String solanaPayUrl, {void Function()? onUrlSent}) async {
    // Ensure permissions before starting
    if (!await checkPermissions()) return;

    // Ensure all endpoints are stopped before starting a new session
    await Nearby().stopAllEndpoints();
    
    _currentPayload = solanaPayUrl;
    _onUrlSent = onUrlSent;
    state = state.copyWith(status: NearbyStatus.advertising, discoveredDevices: [], error: null);

    try {
      bool running = await Nearby().startAdvertising(
        userName,
        strategy,
        onConnectionInitiated: _onConnectionInitiated,
        onConnectionResult: (id, status) {
          if (status == Status.CONNECTED) {
            state = state.copyWith(status: NearbyStatus.connected);
            _sendUrl(id);
          }
        },
        onDisconnected: (id) {
          state = state.copyWith(status: NearbyStatus.advertising);
        },
        serviceId: "com.seekerpay.nearby",
      );

      if (!running) {
        state = state.copyWith(status: NearbyStatus.error, error: "Failed to start advertising");
      }
    } catch (e) {
      state = state.copyWith(status: NearbyStatus.error, error: e.toString());
    }
  }

  /// Starts scanning for nearby advertisers as [userName].
  /// Discovered peers are added to [NearbyState.discoveredDevices].
  Future<void> startDiscovery(String userName) async {
    // Ensure permissions before starting
    if (!await checkPermissions()) return;

    // Ensure all endpoints are stopped before starting a new session
    await Nearby().stopAllEndpoints();
    
    state = state.copyWith(status: NearbyStatus.discovering, discoveredDevices: [], receivedUrl: null, error: null);

    try {
      bool running = await Nearby().startDiscovery(
        userName,
        strategy,
        onEndpointFound: (id, name, serviceId) {
          final devices = List<NearbyDevice>.from(state.discoveredDevices);
          if (!devices.any((d) => d.id == id)) {
            devices.add(NearbyDevice(id, name));
            state = state.copyWith(discoveredDevices: devices);
          }
        },
        onEndpointLost: (id) {
          final devices = List<NearbyDevice>.from(state.discoveredDevices);
          devices.removeWhere((d) => d.id == id);
          state = state.copyWith(discoveredDevices: devices);
        },
        serviceId: "com.seekerpay.nearby",
      );

      if (!running) {
        state = state.copyWith(status: NearbyStatus.error, error: "Failed to start discovery");
      }
    } catch (e) {
      state = state.copyWith(status: NearbyStatus.error, error: e.toString());
    }
  }

  /// Stops all advertising, discovery, and endpoint connections, and resets state.
  Future<void> stopAll() async {
    _onUrlSent = null;
    await Nearby().stopAdvertising();
    await Nearby().stopDiscovery();
    await Nearby().stopAllEndpoints();
    state = NearbyState();
  }

  /// Requests a Nearby Connections session with the endpoint identified by [id].
  Future<void> connectToDevice(String id, String userName) async {
    state = state.copyWith(status: NearbyStatus.connecting);
    try {
      await Nearby().requestConnection(
        userName,
        id,
        onConnectionInitiated: _onConnectionInitiated,
        onConnectionResult: (id, status) {
          if (status == Status.CONNECTED) {
            state = state.copyWith(status: NearbyStatus.connected);
          } else {
            state = state.copyWith(status: NearbyStatus.discovering);
          }
        },
        onDisconnected: (id) {
          state = state.copyWith(status: NearbyStatus.discovering);
        },
      );
    } catch (e) {
      state = state.copyWith(status: NearbyStatus.error, error: e.toString());
    }
  }

  void _onConnectionInitiated(String id, ConnectionInfo info) {
    Nearby().acceptConnection(
      id,
      onPayLoadRecieved: (id, payload) {
        if (payload.type == PayloadType.BYTES) {
          final str = String.fromCharCodes(payload.bytes!);
          if (str.startsWith("solana:")) {
            state = state.copyWith(receivedUrl: str);
            stopAll();
          }
        }
      },
      onPayloadTransferUpdate: (id, transferUpdate) {
      },
    );
  }

  void _sendUrl(String endpointId) {
    if (_currentPayload != null) {
      Nearby().sendBytesPayload(endpointId, Uint8List.fromList(_currentPayload!.codeUnits));
      _onUrlSent?.call();
    }
  }
}

/// Global provider for [NearbyService].
final nearbyServiceProvider = StateNotifierProvider<NearbyService, NearbyState>((ref) {
  return NearbyService();
});
