import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as pkg_crypto;
import 'package:cryptography/cryptography.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/chat_message.dart';

/// Handles all cryptographic operations for seekerpay_chat.
///
/// ### Key model
/// Each device generates a **random X25519 keypair** on first launch.
/// The private key is stored locally in [SharedPreferences]; the public key is
/// published once to Arweave (tagged with the wallet address) so peers can look
/// it up before sending the first message.
///
/// ### Encryption scheme — ECIES
/// ```
/// Send:
///   1. Generate ephemeral X25519 keypair.
///   2. sharedSecret = X25519(ephemeral_private, recipient_x25519_public)
///   3. aesKey = HKDF-SHA256(sharedSecret, info="SKR-Chat-v1", len=32)
///   4. Encrypt plaintext with AES-256-GCM (random 12-byte nonce).
///   5. Wire: { eph_pub (32B) | nonce (12B) | ciphertext+tag }
///
/// Receive:
///   1. sharedSecret = X25519(my_private, eph_pub_from_wire)
///   2. aesKey = HKDF-SHA256(sharedSecret, same info)
///   3. Decrypt AES-256-GCM.
/// ```
///
/// The sender looks up the recipient's X25519 public key via [ArweaveClient]
/// (queried by wallet address tag, cached in sqflite). The conversion helper
/// [ed25519ToX25519PublicKey] is provided for potential future use but is NOT
/// currently used for encryption — each user registers their own X25519 key.
class ChatCrypto {
  static const _prefPrivKey = 'skr_chat_x25519_priv';
  static const _prefPubKey = 'skr_chat_x25519_pub';

  static final _x25519 = X25519();
  static final _aesGcm = AesGcm.with256bits();
  static final _hkdf = Hkdf(hmac: Hmac.sha256(), outputLength: 32);
  static const _hkdfInfo = 'SKR-Chat-v1';

  final SimpleKeyPair _keyPair;

  ChatCrypto._(this._keyPair);

  // ---------------------------------------------------------------------------
  // Initialisation
  // ---------------------------------------------------------------------------

  /// Loads the persisted X25519 keypair from [SharedPreferences] or generates
  /// a new one on first launch.
  static Future<ChatCrypto> init() async {
    final prefs = await SharedPreferences.getInstance();
    final privB64 = prefs.getString(_prefPrivKey);
    final pubB64 = prefs.getString(_prefPubKey);

    if (privB64 != null && pubB64 != null) {
      final privBytes = base64.decode(privB64);
      final pubBytes = base64.decode(pubB64);
      final keyPair = SimpleKeyPairData(
        privBytes,
        publicKey: SimplePublicKey(pubBytes, type: KeyPairType.x25519),
        type: KeyPairType.x25519,
      );
      return ChatCrypto._(keyPair);
    }

    // First launch: generate and persist.
    final keyPair = await _x25519.newKeyPair();
    final pubKey = await keyPair.extractPublicKey();
    final privBytes = await keyPair.extractPrivateKeyBytes();

    await prefs.setString(_prefPrivKey, base64.encode(privBytes));
    await prefs.setString(_prefPubKey, base64.encode(pubKey.bytes));

    return ChatCrypto._(keyPair as SimpleKeyPair);
  }

  // ---------------------------------------------------------------------------
  // Public key access
  // ---------------------------------------------------------------------------

  /// Returns the local X25519 public key bytes (32 bytes).
  ///
  /// This value is published to Arweave once so that peers can encrypt messages
  /// addressed to this device.
  Future<Uint8List> get publicKeyBytes async {
    final pub = await _keyPair.extractPublicKey();
    return Uint8List.fromList(pub.bytes);
  }

  // ---------------------------------------------------------------------------
  // Encrypt
  // ---------------------------------------------------------------------------

  /// Encrypts [plaintext] for the peer identified by [recipientX25519PublicKey].
  ///
  /// Returns an [EncryptedChatPayload] ready to be serialised and uploaded to Irys.
  Future<EncryptedChatPayload> encrypt(
    String plaintext,
    Uint8List recipientX25519PublicKey,
  ) async {
    // 1. Ephemeral keypair.
    final ephKeyPair = await _x25519.newKeyPair();
    final ephPub = await ephKeyPair.extractPublicKey();

    // 2. ECDH shared secret.
    final remoteKey = SimplePublicKey(
      recipientX25519PublicKey,
      type: KeyPairType.x25519,
    );
    final sharedSecret = await _x25519.sharedSecretKey(
      keyPair: ephKeyPair,
      remotePublicKey: remoteKey,
    );

    // 3. Derive AES-256 key via HKDF-SHA256.
    final aesKey = await _hkdf.deriveKey(
      secretKey: sharedSecret,
      info: utf8.encode(_hkdfInfo),
    );

    // 4. AES-256-GCM encrypt.
    final nonce = _aesGcm.newNonce();
    final secretBox = await _aesGcm.encrypt(
      utf8.encode(plaintext),
      secretKey: aesKey,
      nonce: nonce,
    );

    // 5. Pack ciphertext + GCM tag into one buffer.
    final ciphertextWithTag =
        Uint8List.fromList([...secretBox.cipherText, ...secretBox.mac.bytes]);

    return EncryptedChatPayload(
      ephemeralPublicKeyBase64: base64.encode(ephPub.bytes),
      nonceBase64: base64.encode(nonce),
      ciphertextBase64: base64.encode(ciphertextWithTag),
    );
  }

  // ---------------------------------------------------------------------------
  // Decrypt
  // ---------------------------------------------------------------------------

  /// Decrypts an [EncryptedChatPayload] using the local X25519 private key.
  ///
  /// Throws [StateError] if authentication fails (wrong key or tampered data).
  Future<String> decrypt(EncryptedChatPayload payload) async {
    final ephPubBytes = base64.decode(payload.ephemeralPublicKeyBase64);
    final nonce = base64.decode(payload.nonceBase64);
    final ciphertextWithTag = base64.decode(payload.ciphertextBase64);

    // Split ciphertext and 16-byte GCM tag.
    if (ciphertextWithTag.length < 16) {
      throw const FormatException('Invalid ciphertext: too short');
    }
    final ciphertext =
        ciphertextWithTag.sublist(0, ciphertextWithTag.length - 16);
    final macBytes = ciphertextWithTag.sublist(ciphertextWithTag.length - 16);

    // 1. ECDH shared secret using our private key + sender's ephemeral public key.
    final ephPub = SimplePublicKey(ephPubBytes, type: KeyPairType.x25519);
    final sharedSecret = await _x25519.sharedSecretKey(
      keyPair: _keyPair,
      remotePublicKey: ephPub,
    );

    // 2. Derive same AES-256 key.
    final aesKey = await _hkdf.deriveKey(
      secretKey: sharedSecret,
      info: utf8.encode(_hkdfInfo),
    );

    // 3. Decrypt and verify authentication tag.
    final plainBytes = await _aesGcm.decrypt(
      SecretBox(
        ciphertext,
        nonce: nonce,
        mac: Mac(macBytes),
      ),
      secretKey: aesKey,
    );

    return utf8.decode(plainBytes);
  }

  // ---------------------------------------------------------------------------
  // Ed25519 → X25519 public key conversion (birational map)
  // ---------------------------------------------------------------------------

  /// Converts a 32-byte Ed25519 public key (Solana wallet address bytes decoded
  /// from Base58) to its corresponding Curve25519 (X25519) Montgomery-form
  /// public key using the standard birational map:
  ///
  /// ```
  /// u = (1 + y) / (1 - y)  mod  p      where p = 2^255 − 19
  /// ```
  ///
  /// This is the same conversion used by libsodium and the Signal protocol.
  ///
  /// **Note:** This yields the X25519 public key that corresponds to the *same*
  /// scalar as the Ed25519 private key seed. It cannot be used for decryption
  /// unless the holder also derives their X25519 private key from the Ed25519
  /// seed (which requires raw key access — not possible via MWA). It is exposed
  /// here for future cross-device key derivation support.
  static Uint8List ed25519ToX25519PublicKey(Uint8List ed25519PublicKey) {
    assert(ed25519PublicKey.length == 32, 'Ed25519 public key must be 32 bytes');

    // p = 2^255 - 19
    final p = (BigInt.one << 255) - BigInt.from(19);

    // Decode compressed Edwards point: y is little-endian with sign bit in MSB.
    final yBytes = Uint8List.fromList(ed25519PublicKey);
    yBytes[31] &= 0x7F; // clear sign bit to get y coordinate

    BigInt y = BigInt.zero;
    for (int i = 31; i >= 0; i--) {
      y = (y << 8) | BigInt.from(yBytes[i]);
    }

    // Montgomery u = (1 + y) * modInverse(1 - y, p) mod p
    BigInt denom = (BigInt.one - y) % p;
    if (denom < BigInt.zero) denom += p;
    final u = ((BigInt.one + y) * denom.modPow(p - BigInt.two, p)) % p;

    // Encode as 32-byte little-endian.
    final result = Uint8List(32);
    BigInt val = u < BigInt.zero ? u + p : u;
    for (int i = 0; i < 32; i++) {
      result[i] = (val & BigInt.from(0xFF)).toInt();
      val >>= 8;
    }
    return result;
  }

  // ---------------------------------------------------------------------------
  // Address tag hashing (privacy layer)
  // ---------------------------------------------------------------------------

  /// Produces a hex-encoded SHA-256 hash of [walletAddress] salted with the
  /// protocol constant. Used as the `To-Hash` / `From-Hash` / `Owner-Hash`
  /// Arweave tag values so that raw wallet addresses are never exposed in tags.
  static String hashAddress(String walletAddress) {
    final bytes = utf8.encode('$walletAddress:SKR-Chat-v1');
    return pkg_crypto.sha256.convert(bytes).toString();
  }

  /// Produces a deterministic conversation identifier from two wallet addresses
  /// regardless of order (sorted before hashing).
  static String conversationHash(String addressA, String addressB) {
    final sorted = [addressA, addressB]..sort();
    final bytes = utf8.encode('${sorted[0]}:${sorted[1]}:SKR-Chat-v1');
    return pkg_crypto.sha256.convert(bytes).toString();
  }
}
