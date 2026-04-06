import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

/// A lightweight record returned by [ArweaveClient.queryInbox].
class ArweaveMessage {
  /// Arweave transaction ID.
  final String txId;

  /// All tags attached to the data item.
  final Map<String, String> tags;

  /// Block timestamp (seconds since epoch), null if not yet mined.
  final int? blockTimestamp;

  const ArweaveMessage({
    required this.txId,
    required this.tags,
    this.blockTimestamp,
  });
}

/// Queries the Arweave GraphQL API and fetches raw data item content.
///
/// ### GraphQL endpoint
/// `https://node2.irys.xyz/graphql` — Irys node GraphQL, indexes transactions
/// immediately after upload (no need to wait for Arweave block mining).
/// This gives near-instant message delivery (~seconds instead of minutes/hours).
///
/// ### Content fetch
/// `GET https://arweave.net/<txId>` — content is served immediately from the
/// Irys gateway cache even before the tx is mined into an Arweave block.
class ArweaveClient {
  static const _graphqlUrl = 'https://node2.irys.xyz/graphql';
  static const _gatewayUrl = 'https://arweave.net';
  static const _appName = 'SKR-Chat';

  /// Queries Arweave for messages addressed to [toHash] (a hashed wallet
  /// address produced by [ChatCrypto.hashAddress]).
  ///
  /// [afterTimestamp]: only return transactions whose block timestamp is after
  /// this value (seconds since epoch). Pass 0 to fetch all.
  ///
  /// Returns up to [limit] results sorted newest-first.
  Future<List<ArweaveMessage>> queryInbox({
    required String toHash,
    int afterTimestamp = 0,
    int limit = 50,
  }) async {
    const query = r'''
      query($tags: [TagFilter!]!, $first: Int!) {
        transactions(tags: $tags, first: $first, sort: HEIGHT_DESC) {
          edges {
            node {
              id
              tags { name value }
              block { timestamp }
            }
          }
        }
      }
    ''';

    final variables = {
      'first': limit,
      'tags': [
        {'name': 'App-Name', 'values': [_appName]},
        {'name': 'Protocol', 'values': ['1']},
        {'name': 'To-Hash', 'values': [toHash]},
      ],
    };

    final response = await http
        .post(
          Uri.parse(_graphqlUrl),
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode({'query': query, 'variables': variables}),
        )
        .timeout(const Duration(seconds: 15));

    if (response.statusCode != 200) {
      throw ArweaveQueryException(
          'GraphQL query failed: ${response.statusCode}');
    }

    final body = jsonDecode(response.body) as Map<String, dynamic>;
    final edges = (body['data']?['transactions']?['edges'] as List?) ?? [];

    final messages = <ArweaveMessage>[];
    for (final edge in edges) {
      final node = edge['node'] as Map<String, dynamic>;
      final txId = node['id'] as String;
      final tagList = (node['tags'] as List?) ?? [];
      final tags = <String, String>{
        for (final t in tagList)
          (t['name'] as String): (t['value'] as String),
      };
      final blockTimestamp = node['block']?['timestamp'] as int?;

      // Filter by timestamp client-side (GraphQL doesn't support block range filters).
      if (afterTimestamp > 0 &&
          blockTimestamp != null &&
          blockTimestamp <= afterTimestamp) {
        continue;
      }

      messages.add(ArweaveMessage(
        txId: txId,
        tags: tags,
        blockTimestamp: blockTimestamp,
      ));
    }
    return messages;
  }

  /// Queries Arweave for the X25519 public key registration record belonging
  /// to [ownerHash] (a hashed wallet address).
  ///
  /// Returns `null` if no registration exists yet.
  /// Tries with App-Name filter first; falls back to Owner-Hash only for
  /// keys registered before App-Name was added to the upload tags.
  Future<ArweaveMessage?> queryKeyRegistration(String ownerHash) async {
    const query = r'''
      query($tags: [TagFilter!]!) {
        transactions(tags: $tags, first: 1, sort: HEIGHT_DESC) {
          edges { node { id tags { name value } } }
        }
      }
    ''';

    Future<ArweaveMessage?> _query(List<Map<String, dynamic>> tags) async {
      final response = await http
          .post(
            Uri.parse(_graphqlUrl),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({'query': query, 'variables': {'tags': tags}}),
          )
          .timeout(const Duration(seconds: 15));
      if (response.statusCode != 200) return null;
      final body = jsonDecode(response.body) as Map<String, dynamic>;
      final edges = (body['data']?['transactions']?['edges'] as List?) ?? [];
      if (edges.isEmpty) return null;
      final node = edges.first['node'] as Map<String, dynamic>;
      final tagList = (node['tags'] as List?) ?? [];
      return ArweaveMessage(
        txId: node['id'] as String,
        tags: {
          for (final t in tagList)
            (t['name'] as String): (t['value'] as String),
        },
      );
    }

    // Try with App-Name filter (keys registered with correct tags).
    final result = await _query([
      {'name': 'App-Name', 'values': [_appName]},
      {'name': 'Type', 'values': ['key_reg']},
      {'name': 'Owner-Hash', 'values': [ownerHash]},
    ]);
    if (result != null) return result;

    // Fallback: keys registered before App-Name tag was added.
    return _query([
      {'name': 'Type', 'values': ['key_reg']},
      {'name': 'Owner-Hash', 'values': [ownerHash]},
    ]);
  }

  /// Fetches the raw bytes of an Arweave transaction by [txId].
  ///
  /// Content is served from the Irys / Arweave gateway cache immediately after
  /// upload — no need to wait for on-chain mining.
  Future<Uint8List> fetchContent(String txId) async {
    final response = await http
        .get(Uri.parse('$_gatewayUrl/$txId'))
        .timeout(const Duration(seconds: 15));

    if (response.statusCode == 200) {
      return response.bodyBytes;
    }
    throw ArweaveQueryException(
        'Content fetch failed for $txId: ${response.statusCode}');
  }
}

/// Thrown when an Arweave query or content fetch fails.
class ArweaveQueryException implements Exception {
  final String message;
  const ArweaveQueryException(this.message);

  @override
  String toString() => 'ArweaveQueryException: $message';
}
