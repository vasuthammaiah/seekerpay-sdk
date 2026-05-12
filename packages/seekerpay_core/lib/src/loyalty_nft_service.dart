import 'dart:typed_data';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:solana_web3/solana_web3.dart' as web3;
import 'package:solana_web3/programs.dart';
import 'rpc_client.dart';
import 'mwa_client.dart';

const _tokenProgram = 'TokenkegQfeZyiNwAJbNbGKPFXCWuBvf9Ss623VQ5DA';
const _ataProgram   = 'ATokenGPvbdGVxr1b2hvZbsiqW5xWH25efTNsLJA8knL';
const _sysvarRent   = 'SysvarRent111111111111111111111111111111111';
const _systemProgram = '11111111111111111111111111111111';

class LoyaltyNftService {
  static const _prefMintPrefix = 'spay_loyalty_mint_';

  final RpcClient _rpc;
  final MwaClient _mwa;

  LoyaltyNftService(this._rpc, this._mwa);

  /// Returns the persistent mint address for [merchantAddress], creating it
  /// on-chain the first time. Null if the MWA wallet rejected the transaction.
  Future<String?> getMerchantMintAddress(String merchantAddress) async {
    final prefs = await SharedPreferences.getInstance();
    final key = '$_prefMintPrefix$merchantAddress';
    final saved = prefs.getString(key);
    if (saved != null) return saved;

    final mintAddress = await _createMint(merchantAddress);
    if (mintAddress != null) {
      await prefs.setString(key, mintAddress);
    }
    return mintAddress;
  }

  /// Returns true if [customerAddress] holds at least 1 token of this
  /// merchant's loyalty mint.
  Future<bool> customerHasLoyaltyPass(
      String customerAddress, String merchantAddress) async {
    try {
      final mint = await getMerchantMintAddress(merchantAddress);
      if (mint == null) return false;
      final balance = await _rpc.getTokenAccountsByOwner(customerAddress, mint);
      return balance > BigInt.zero;
    } catch (_) {
      return false;
    }
  }

  /// Mints 1 loyalty pass to [customerAddress] from the merchant's persistent
  /// mint. Returns the transaction signature, or null on failure.
  /// Returns 'already_has_pass' (without minting) if the customer already holds one.
  Future<String?> mintLoyaltyNft({
    required String merchantAddress,
    required String customerAddress,
  }) async {
    try {
      final mint = await getMerchantMintAddress(merchantAddress);
      if (mint == null) return null;

      final alreadyHas =
          await customerHasLoyaltyPass(customerAddress, merchantAddress);
      if (alreadyHas) return 'already_has_pass';

      return await _mintToCustomer(merchantAddress, customerAddress, mint);
    } catch (e) {
      print('[LoyaltyNftService] mintLoyaltyNft error: $e');
      return null;
    }
  }

  // ---------------------------------------------------------------------------
  // Private helpers
  // ---------------------------------------------------------------------------

  /// Creates the merchant's mint on-chain (once per merchant).
  /// Requires two signers: merchant wallet (MWA) + mint keypair (local).
  Future<String?> _createMint(String merchantAddress) async {
    try {
      final blockhash = await _rpc.getLatestBlockhash();
      final merchantPubkey = web3.Pubkey.fromBase58(merchantAddress);
      final mintKp = await web3.Keypair.generate();
      final space = 82;
      final rent = await _rpc.getMinimumBalanceForRentExemption(space);

      final instructions = <web3.TransactionInstruction>[
        // 1. Create the mint account, funded by the merchant.
        SystemProgram.createAccount(
          fromPubkey: merchantPubkey,
          newAccountPubkey: mintKp.pubkey,
          lamports: BigInt.from(rent.toInt()),
          space: BigInt.from(space),
          programId: web3.Pubkey.fromBase58(_tokenProgram),
        ),
        // 2. Initialize mint: 0 decimals, merchant is authority.
        _initializeMintIx(mintKp.pubkey, merchantPubkey),
      ];

      final tx = web3.Transaction.v0(
        payer: merchantPubkey,
        instructions: instructions,
        recentBlockhash: blockhash,
      );

      // MWA signs with merchant wallet.
      final mwaSigned = await _mwa.signTransaction(
        transactionBytes: tx.serialize().asUint8List(),
      );
      if (mwaSigned == null) return null;

      // Add local mint keypair signature.
      final signedTx = web3.Transaction.deserialize(mwaSigned);
      signedTx.sign([mintKp]);

      await _rpc.sendTransaction(signedTx.serialize().asUint8List());
      return mintKp.pubkey.toBase58();
    } catch (e) {
      print('[LoyaltyNftService] _createMint error: $e');
      return null;
    }
  }

  /// Mints 1 token to [customerAddress] using the existing [mintAddress].
  /// Only the merchant wallet (MWA) needs to sign as the mint authority.
  Future<String?> _mintToCustomer(
      String merchantAddress, String customerAddress, String mintAddress) async {
    try {
      final blockhash = await _rpc.getLatestBlockhash();
      final merchantPubkey = web3.Pubkey.fromBase58(merchantAddress);
      final customerPubkey = web3.Pubkey.fromBase58(customerAddress);
      final mintPubkey = web3.Pubkey.fromBase58(mintAddress);
      final customerAta = _findATA(customerPubkey, mintPubkey);

      final instructions = <web3.TransactionInstruction>[
        // Create customer ATA if it doesn't exist (merchant pays rent).
        _createAtaIx(merchantPubkey, customerAta, customerPubkey, mintPubkey),
        // Mint 1 token to the customer ATA.
        _mintToIx(mintPubkey, customerAta, merchantPubkey),
      ];

      final tx = web3.Transaction.v0(
        payer: merchantPubkey,
        instructions: instructions,
        recentBlockhash: blockhash,
      );

      final mwaSigned = await _mwa.signTransaction(
        transactionBytes: tx.serialize().asUint8List(),
      );
      if (mwaSigned == null) return null;

      final signedTx = web3.Transaction.deserialize(mwaSigned);
      await _rpc.sendTransaction(signedTx.serialize().asUint8List());
      return web3.base58Encode(signedTx.signatures.first);
    } catch (e) {
      print('[LoyaltyNftService] _mintToCustomer error: $e');
      return null;
    }
  }

  // ---------------------------------------------------------------------------
  // Instruction builders
  // ---------------------------------------------------------------------------

  web3.TransactionInstruction _initializeMintIx(
      web3.Pubkey mint, web3.Pubkey authority) {
    // Token program InitializeMint instruction (index 0).
    // Layout: [u8 index=0, u8 decimals=0, 32B mintAuthority, u8 hasFreezeAuth=1, 32B freezeAuthority]
    final data = ByteData(67);
    data.setUint8(0, 0); // InitializeMint
    data.setUint8(1, 0); // 0 decimals → NFT
    final authBytes = authority.toBytes();
    for (var i = 0; i < 32; i++) {
      data.setUint8(2 + i, authBytes[i]);
      data.setUint8(35 + i, authBytes[i]);
    }
    data.setUint8(34, 1); // has freeze authority

    return web3.TransactionInstruction(
      keys: [
        web3.AccountMeta(mint, isWritable: true, isSigner: true),
        web3.AccountMeta(web3.Pubkey.fromBase58(_sysvarRent),
            isWritable: false, isSigner: false),
      ],
      programId: web3.Pubkey.fromBase58(_tokenProgram),
      data: data.buffer.asUint8List(),
    );
  }

  web3.TransactionInstruction _createAtaIx(web3.Pubkey payer,
      web3.Pubkey ata, web3.Pubkey owner, web3.Pubkey mint) {
    return web3.TransactionInstruction(
      keys: [
        web3.AccountMeta(payer, isWritable: true, isSigner: true),
        web3.AccountMeta(ata, isWritable: true, isSigner: false),
        web3.AccountMeta(owner, isWritable: false, isSigner: false),
        web3.AccountMeta(mint, isWritable: false, isSigner: false),
        web3.AccountMeta(web3.Pubkey.fromBase58(_systemProgram),
            isWritable: false, isSigner: false),
        web3.AccountMeta(web3.Pubkey.fromBase58(_tokenProgram),
            isWritable: false, isSigner: false),
      ],
      programId: web3.Pubkey.fromBase58(_ataProgram),
      data: Uint8List(0),
    );
  }

  web3.TransactionInstruction _mintToIx(
      web3.Pubkey mint, web3.Pubkey destination, web3.Pubkey authority) {
    // Token program MintTo instruction (index 7).
    // Layout: [u8 index=7, u64 amount=1 LE]
    final data = ByteData(9);
    data.setUint8(0, 7);
    data.setUint64(1, 1, Endian.little);

    return web3.TransactionInstruction(
      keys: [
        web3.AccountMeta(mint, isWritable: true, isSigner: false),
        web3.AccountMeta(destination, isWritable: true, isSigner: false),
        web3.AccountMeta(authority, isWritable: false, isSigner: true),
      ],
      programId: web3.Pubkey.fromBase58(_tokenProgram),
      data: data.buffer.asUint8List(),
    );
  }

  web3.Pubkey _findATA(web3.Pubkey owner, web3.Pubkey mint) {
    return web3.Pubkey.findProgramAddress(
      [
        owner.toBytes(),
        web3.Pubkey.fromBase58(_tokenProgram).toBytes(),
        mint.toBytes(),
      ],
      web3.Pubkey.fromBase58(_ataProgram),
    ).pubkey;
  }
}
