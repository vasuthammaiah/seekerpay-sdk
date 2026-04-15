import 'dart:convert';

import 'package:flutter/foundation.dart';
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
class ArweaveOrderClient {
  static const _irysGatewayUrl = 'https://gateway.irys.xyz';
  static const _arweaveGatewayUrl = 'https://arweave.net';

  static const _appName = 'SKR-Shop';

  /// List of GraphQL endpoints to try. 
  /// node1 and arweave.net are currently the most reliable for finding recent records.
  static const _graphqlUrls = [
    'https://node1.irys.xyz/graphql',
    'https://arweave.net/graphql',
    'https://node2.irys.xyz/graphql',
    'https://uploader.irys.xyz/graphql',
  ];

  /// Queries Arweave for all order backups belonging to [ownerHash].
  Future<List<ArweaveOrderRecord>> queryOrders({
    required String ownerHash,
    int limit = 200,
  }) async {
    const query = r'''
      query($tags: [TagFilter!]!, $first: Int!) {
        transactions(tags: $tags, first: $first) {
          edges {
            node {
              id
              tags { name value }
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

    for (final url in _graphqlUrls) {
      for (int attempt = 1; attempt <= 2; attempt++) {
        debugPrint('[SKR-Arweave/Client] queryOrders: POST $url (attempt $attempt) ownerHash=$ownerHash');
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
          
          if (body['errors'] != null) {
            final errors = body['errors'] as List;
            final msg = errors.isNotEmpty ? errors[0]['message'] : 'Unknown GraphQL error';
            debugPrint('[SKR-Arweave/Client] queryOrders: ❌ GraphQL error from $url: $msg');
            break; 
          }

          final data = body['data']?['transactions'];
          if (data == null) break;

          final edges = (data['edges'] as List?) ?? [];
          debugPrint('[SKR-Arweave/Client] queryOrders: ✅ found ${edges.length} edges from $url');

          if (edges.isEmpty) break; 

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
            ));
          }
          return records;
        } catch (e) {
          debugPrint('[SKR-Arweave/Client] queryOrders: ❌ Exception from $url: $e');
          if (attempt == 2) break;
          await Future.delayed(const Duration(seconds: 2));
        }
      }
    }

    return [];
  }

  /// Fetches the raw bytes of a transaction by [txId].
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
            .timeout(const Duration(seconds: 30));
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
