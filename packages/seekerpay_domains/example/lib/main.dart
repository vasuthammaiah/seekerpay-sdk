/// seekerpay_domains — example app.
///
/// Demonstrates .skr and .sol domain resolution, autocomplete search,
/// and Seeker Genesis Token verification.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:seekerpay_domains/seekerpay_domains.dart';

void main() {
  runApp(const ProviderScope(child: _App()));
}

class _App extends StatelessWidget {
  const _App();
  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'seekerpay_domains example',
        theme: ThemeData.dark(),
        home: const _HomeScreen(),
      );
}

class _HomeScreen extends ConsumerStatefulWidget {
  const _HomeScreen();
  @override
  ConsumerState<_HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends ConsumerState<_HomeScreen> {
  final _controller = TextEditingController(text: 'bob.skr');
  String? _resolvedAddress;
  bool? _isVerified;
  bool _loading = false;
  String? _error;

  Future<void> _resolve() async {
    final query = _controller.text.trim();
    if (query.isEmpty) return;

    setState(() { _loading = true; _error = null; _resolvedAddress = null; _isVerified = null; });

    try {
      final resolver = ref.read(snsResolverProvider);
      final address = await resolver.resolve(query);
      if (!mounted) return;

      if (address == null) {
        setState(() { _error = '$query not found'; _loading = false; });
        return;
      }

      // Also check Seeker Genesis Token for this address
      final verified = await ref.read(isAddressVerifiedProvider(address).future);
      if (!mounted) return;

      setState(() {
        _resolvedAddress = address;
        _isVerified = verified;
        _loading = false;
      });
    } catch (e) {
      if (mounted) setState(() { _error = e.toString(); _loading = false; });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('seekerpay_domains')),
      body: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextField(
              controller: _controller,
              decoration: const InputDecoration(
                labelText: 'Enter domain (.skr or .sol)',
                hintText: 'e.g. alice.skr or solana.sol',
                border: OutlineInputBorder(),
              ),
              textInputAction: TextInputAction.search,
              onSubmitted: (_) => _resolve(),
            ),
            const SizedBox(height: 16),
            ElevatedButton(
              onPressed: _loading ? null : _resolve,
              child: _loading
                  ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Text('Resolve'),
            ),
            const SizedBox(height: 24),
            if (_error != null)
              Text(_error!, style: const TextStyle(color: Colors.red)),
            if (_resolvedAddress != null) ...[
              const Text('Resolved address:', style: TextStyle(color: Colors.white54, fontSize: 11)),
              const SizedBox(height: 4),
              SelectableText(
                _resolvedAddress!,
                style: const TextStyle(fontFamily: 'Courier', fontSize: 12),
              ),
              const SizedBox(height: 12),
              Row(children: [
                Icon(
                  _isVerified == true ? Icons.verified_rounded : Icons.shield_outlined,
                  size: 16,
                  color: _isVerified == true ? Colors.green : Colors.white38,
                ),
                const SizedBox(width: 6),
                Text(
                  _isVerified == true ? 'Seeker Verified' : 'Not Seeker Verified',
                  style: TextStyle(
                    color: _isVerified == true ? Colors.green : Colors.white38,
                    fontSize: 13,
                  ),
                ),
              ]),
            ],
          ],
        ),
      ),
    );
  }
}
