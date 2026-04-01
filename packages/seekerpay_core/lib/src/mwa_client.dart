import 'dart:async';
import 'dart:io' show Platform;
import 'dart:typed_data';

import 'package:solana_mobile_client/solana_mobile_client.dart';
import 'package:solana_web3/solana_web3.dart' as web3;

/// Base exception thrown when a Mobile Wallet Adapter operation fails.
class MwaException implements Exception {
  /// Human-readable description of the failure.
  final String message;
  MwaException(this.message);
  @override
  String toString() => 'MwaException: $message';
}

/// Thrown when the user explicitly declines a wallet authorization or signing request.
class MwaUserRejectedException extends MwaException {
  MwaUserRejectedException() : super('User rejected the request');
}

/// Thrown when the wallet app does not establish a connection within the timeout window.
class MwaTimeoutException extends MwaException {
  MwaTimeoutException() : super('Wallet connection timed out');
}

/// Singleton client for interacting with a Solana wallet via the
/// Mobile Wallet Adapter (MWA) protocol on Android.
///
/// Handles [LocalAssociationScenario] lifecycle, authorization caching, and
/// transaction signing. All operations are serialised via [_busy] to prevent
/// concurrent MWA sessions.
///
/// Call [configure] once at app startup to set the app name and domain shown
/// to the user during wallet authorization:
/// ```dart
/// MwaClient.instance.configure(
///   identityName: 'My App',
///   identityUri: Uri.parse('https://myapp.com'),
/// );
/// ```
class MwaClient {
  MwaClient._();

  /// The shared [MwaClient] instance for the app.
  static final MwaClient instance = MwaClient._();

  AuthorizationResult? _auth;
  bool _busy = false;

  String _identityName = 'seekerpay';
  Uri _identityUri = Uri.parse('https://seekerpay.live');

  /// Configures the app identity shown to the user during wallet authorization.
  ///
  /// Call this once at app startup before any wallet operations.
  void configure({
    required String identityName,
    required Uri identityUri,
  }) {
    _identityName = identityName;
    _identityUri = identityUri;
  }

  /// Whether the client currently holds a valid authorization token.
  bool get isAuthorized => _auth != null;

  /// Clears the cached authorization and resets the busy flag.
  void reset() {
    _auth = null;
    _busy = false;
  }

  Future<void> _sleep(int ms) =>
      Future<void>.delayed(Duration(milliseconds: ms));

  Future<_ClientCtx> _openClient({int attempts = 10}) async {
    final scenario = await LocalAssociationScenario.create();
    scenario.startActivityForResult(null).ignore();
    await _sleep(300);

    var tries = 0;
    while (true) {
      tries++;
      try {
        final client = await scenario.start()
            .timeout(const Duration(seconds: 15));
        return _ClientCtx(client, scenario);
      } on TimeoutException {
        await scenario.close();
        throw MwaTimeoutException();
      } catch (e) {
        final msg = e.toString();
        final retryable =
            msg.contains('Unable to connect to websocket server') ||
                msg.contains('ConnectionFailedException') ||
                msg.contains('ECONNREFUSED');
        if (!retryable || tries >= attempts) {
          try {
            await scenario.close();
          } catch (_) {}
          rethrow;
        }
        await _sleep(600);
      }
    }
  }

  /// Authorizes with the wallet app and returns the connected wallet's Base58
  /// public key, or `null` if authorization fails or the platform is not Android.
  ///
  /// Re-uses an existing auth token when available; falls back to a fresh
  /// [authorize] call otherwise.
  Future<String?> connectWalletAndGetAddress({
    String cluster = 'mainnet-beta',
  }) async {
    if (!Platform.isAndroid) return null;
    if (_busy) return null;
    _busy = true;

    _ClientCtx? ctx;
    try {
      ctx = await _openClient();
      final client = ctx.client;

      AuthorizationResult? nextAuth;
      final currentAuth = _auth;
      if (currentAuth != null) {
        try {
          nextAuth = await client.reauthorize(
            identityUri: _identityUri,
            identityName: _identityName,
            authToken: currentAuth.authToken,
          );
        } catch (_) {
          // Auth token stale or unsupported by this wallet — fall through to
          // a fresh authorize() below.
          nextAuth = null;
          _auth = null;
        }
      }
      nextAuth ??= await client.authorize(
        identityUri: _identityUri,
        iconUri: Uri.parse('${_identityUri}favicon.png'),
        identityName: _identityName,
        cluster: cluster,
      );
      if (nextAuth == null) return null;

      _auth = nextAuth;
      final key = _extractPublicKey(nextAuth);
      if (key == null) return null;
      return web3.Pubkey.fromUint8List(key).toBase58();
    } catch (_) {
      rethrow;
    } finally {
      _busy = false;
      try {
        await ctx?.scenario.close();
      } catch (_) {}
    }
  }

  /// Presents [transactionBytes] to the wallet app for signing and returns the
  /// signed transaction bytes, or `null` if signing is rejected or unavailable.
  ///
  /// Requires Android. A fresh authorization is performed if no token is cached.
  Future<Uint8List?> signTransaction({
    required Uint8List transactionBytes,
    String cluster = 'mainnet-beta',
  }) async {
    if (!Platform.isAndroid || _busy) return null;
    _busy = true;

    _ClientCtx? ctx;
    try {
      ctx = await _openClient();
      final client = ctx.client;

      AuthorizationResult? auth = _auth;
      if (auth != null) {
        try {
          auth = await client.reauthorize(
            identityUri: _identityUri,
            identityName: _identityName,
            authToken: auth.authToken,
          );
        } catch (_) {
          // Auth token stale or not recognised by this wallet (common with
          // external wallets like Jupiter that don't persist tokens across
          // LocalAssociationScenario sessions).  Fall through to a fresh
          // authorize() so the user gets a proper sign dialog instead of a
          // confusing rejection.
          auth = null;
          _auth = null;
        }
      }
      auth ??= await client.authorize(
        identityUri: _identityUri,
        iconUri: Uri.parse('${_identityUri}favicon.png'),
        identityName: _identityName,
        cluster: cluster,
      );
      if (auth == null) throw MwaUserRejectedException();
      _auth = auth;

      final signed =
          await client.signTransactions(transactions: [transactionBytes]);
      if (signed.signedPayloads.isEmpty) throw MwaUserRejectedException();

      return signed.signedPayloads.first;
    } on MwaException {
      rethrow;
    } catch (e) {
      // Map native SDK rejection messages to a typed exception so callers
      // can distinguish a user cancellation from a connectivity error.
      final msg = e.toString().toLowerCase();
      if (msg.contains('user declined') ||
          msg.contains('user rejected') ||
          msg.contains('authorization not granted') ||
          msg.contains('not authorized')) {
        throw MwaUserRejectedException();
      }
      rethrow;
    } finally {
      _busy = false;
      try {
        await ctx?.scenario.close();
      } catch (_) {}
    }
  }

  Uint8List? _extractPublicKey(AuthorizationResult? auth) => auth?.publicKey;
}

class _ClientCtx {
  _ClientCtx(this.client, this.scenario);
  final MobileWalletAdapterClient client;
  final LocalAssociationScenario scenario;
}
