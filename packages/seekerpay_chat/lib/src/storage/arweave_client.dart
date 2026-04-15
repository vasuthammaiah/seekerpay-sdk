import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

/// A lightweight record returned by [ArweaveClient.queryInbox].
class ArweaveMessage {
  final String txId;
  final Map<String, String> tags;
  final int? blockTimestamp;

  const ArweaveMessage({
    required this.txId,
    required this.tags,
    this.blockTimestamp,
  });
}

/// Queries the Arweave GraphQL API and fetches raw data item content.
class ArweaveClient {
  static const _irysGatewayUrl = 'https://gateway.irys.xyz';
  static const _arweaveGatewayUrl = 'https://arweave.net';
  static const _appName = 'SKR-Chat';

  static const _graphqlUrls = [
    'https://node1.irys.xyz/graphql',
    'https://arweave.net/graphql',
    'https://node2.irys.xyz/graphql',
    'https://uploader.irys.xyz/graphql',
  ];

  /// Queries Arweave for messages addressed to [toHash].
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

    for (final url in _graphqlUrls) {
      for (int attempt = 1; attempt <= 2; attempt++) {
        try {
          final response = await http
              .post(
                Uri.parse(url),
                headers: {'Content-Type': 'application/json'},
                body: jsonEncode({'query': query, 'variables': variables}),
              )
              .timeout(const Duration(seconds: 90));

          if (response.statusCode != 200) break;

          final body = jsonDecode(response.body) as Map<String, dynamic>;
          if (body['errors'] != null) break;

          final data = body['data']?['transactions'];
          if (data == null) break;

          final edges = (data['edges'] as List?) ?? [];
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
        } catch (_) {
          if (attempt == 2) break;
          await Future.delayed(const Duration(seconds: 2));
        }
      }
    }
    return [];
  }

  /// Queries Arweave for the X25519 public key registration record.
  Future<ArweaveMessage?> queryKeyRegistration(String ownerHash) async {
    const query = r'''
      query($tags: [TagFilter!]!) {
        transactions(tags: $tags, first: 1, sort: HEIGHT_DESC) {
          edges { node { id tags { name value } } }
        }
      }
    ''';

    Future<ArweaveMessage?> _tryNode(String url, List<Map<String, dynamic>> tags) async {
      try {
        final response = await http
            .post(
              Uri.parse(url),
              headers: {'Content-Type': 'application/json'},
              body: jsonEncode({'query': query, 'variables': {'tags': tags}}),
            )
            .timeout(const Duration(seconds: 40));
        if (response.statusCode != 200) return null;
        final body = jsonDecode(response.body) as Map<String, dynamic>;
        if (body['errors'] != null) return null;
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
      } catch (_) {
        return null;
      }
    }

    Future<ArweaveMessage?> _queryAllNodes(List<Map<String, dynamic>> tags) async {
      for (final url in _graphqlUrls) {
        final res = await _tryNode(url, tags);
        if (res != null) return res;
      }
      return null;
    }

    final result = await _queryAllNodes([
      {'name': 'App-Name', 'values': [_appName]},
      {'name': 'Type', 'values': ['key_reg']},
      {'name': 'Owner-Hash', 'values': [ownerHash]},
    ]);
    if (result != null) return result;

    return _queryAllNodes([
      {'name': 'Type', 'values': ['key_reg']},
      {'name': 'Owner-Hash', 'values': [ownerHash]},
    ]);
  }

  /// Fetches the raw bytes of an Arweave transaction by [txId].
  Future<Uint8List> fetchContent(String txId) async {
    final urls = [
      '$_irysGatewayUrl/$txId',
      '$_arweaveGatewayUrl/$txId',
    ];

    Object? lastError;
    for (final url in urls) {
      try {
        final response = await http
            .get(Uri.parse(url))
            .timeout(const Duration(seconds: 20));
        if (response.statusCode == 200) {
          return response.bodyBytes;
        }
        lastError = 'HTTP ${response.statusCode} from $url';
      } catch (e) {
        lastError = e;
      }
    }
    throw ArweaveQueryException(
        'Content fetch failed for $txId: $lastError');
  }
}

class ArweaveQueryException implements Exception {
  final String message;
  const ArweaveQueryException(this.message);

  @override
  String toString() => 'ArweaveQueryException: $message';
}
