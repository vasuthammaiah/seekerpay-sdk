import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

/// A lightweight record returned by [ArweaveOrderClient.queryOrders].
class ArweaveOrderRecord {
  final String txId;
  final Map<String, String> tags;
  final int? blockTimestamp;

  const ArweaveOrderRecord({
    required this.txId,
    required this.tags,
    this.blockTimestamp,
  });
}

/// Queries Arweave/Irys for backed-up order records and fetches their content.
///
/// Uses `node2.irys.xyz/graphql` for GraphQL queries (indexes immediately after
/// upload) and tries the Irys gateway before falling back to arweave.net for
/// content fetches so that recently uploaded records are always accessible.
class ArweaveOrderClient {
  static const _graphqlUrl = 'https://node2.irys.xyz/graphql';
  static const _irysGatewayUrl = 'https://gateway.irys.xyz';
  static const _arweaveGatewayUrl = 'https://arweave.net';

  static const _appName = 'SKR-Shop';

  /// Queries Arweave for all order backups belonging to [ownerHash].
  ///
  /// [ownerHash] is a SHA-256 hash of the wallet address (see
  /// [ArweaveOrderService.hashAddress]).
  Future<List<ArweaveOrderRecord>> queryOrders({
    required String ownerHash,
    int limit = 200,
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
        {'name': 'Type', 'values': ['order_backup']},
        {'name': 'Owner-Hash', 'values': [ownerHash]},
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
      throw ArweaveOrderQueryException(
          'GraphQL query failed: ${response.statusCode}');
    }

    final body = jsonDecode(response.body) as Map<String, dynamic>;
    final edges =
        (body['data']?['transactions']?['edges'] as List?) ?? [];

    final records = <ArweaveOrderRecord>[];
    for (final edge in edges) {
      final node = edge['node'] as Map<String, dynamic>;
      final txId = node['id'] as String;
      final tagList = (node['tags'] as List?) ?? [];
      final tags = <String, String>{
        for (final t in tagList)
          (t['name'] as String): (t['value'] as String),
      };
      records.add(ArweaveOrderRecord(
        txId: txId,
        tags: tags,
        blockTimestamp: node['block']?['timestamp'] as int?,
      ));
    }
    return records;
  }

  /// Fetches the raw bytes of a transaction by [txId].
  ///
  /// Tries the Irys gateway first (immediate availability), then arweave.net
  /// (after the bundle is mined into the Arweave network).
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
            .timeout(const Duration(seconds: 15));
        if (response.statusCode == 200) {
          return response.bodyBytes;
        }
        lastError = 'HTTP ${response.statusCode} from $url';
      } catch (e) {
        lastError = e;
      }
    }
    throw ArweaveOrderQueryException(
        'Content fetch failed for $txId: $lastError');
  }
}

class ArweaveOrderQueryException implements Exception {
  final String message;
  const ArweaveOrderQueryException(this.message);

  @override
  String toString() => 'ArweaveOrderQueryException: $message';
}
