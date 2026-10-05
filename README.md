# BTCW CUDA Miner

NVIDIA miner for [BitcoinPoW Core 31.x](https://github.com/btcw-space/BitcoinPoW). The node builds the block and checks the result. This program only searches the block signature. The rules in force are the ones from block **144444**.

You need BTCW already. An empty wallet cannot mine.

## Quick start

### 1. Sync a 31.x node

Install from [btcw.space/download](https://btcw.space/download) or build [BitcoinPoW](https://github.com/btcw-space/BitcoinPoW). Use the BTCW data directory, not a Bitcoin one.

- Linux: `~/.bitcoin-pow`
- Windows: `%APPDATA%\Bitcoin-PoW`
- Port: **8555**

```bash
bitcoind -daemon
bitcoin-cli getblockchaininfo
```

`bitcoin-qt -server` works the same. In Qt the commands go in **Window > Console**.

Leave it until `initialblockdownload` is `false`, `blocks` equals `headers`, and `blocks` is past **144444**. The Qt countdown is only a guess. First sync is often an afternoon on an SSD and overnight or longer on a hard disk. The node estimates about 30 GB of blocks and 30 GB of chain state, so leave at least 100 GB free. The chain starts 4 December 2023. If `blocks` is still `0` after about 15 minutes, it is not reaching the BTCW network.

### 2. Put BTCW on a legacy address

Get BTCW and have it sent to a legacy address in this wallet. The address must start with `1`. SegWit (`bc1`), wrapped SegWit, and Taproot are ignored. Watch-only wallets cannot mine.

```bash
bitcoin-cli createwallet "mining"
bitcoin-cli -rpcwallet=mining getnewaddress "stake" legacy
bitcoin-cli -rpcwallet=mining backupwallet "$HOME/btcw-mining-wallet.backup"
```

Windows backup path: `%USERPROFILE%\btcw-mining-wallet.backup`. Back up the wallet before coins are sent to it.

BTCW addresses look like Bitcoin addresses. They are a different chain. Do not send Bitcoin to this address.

One payment is enough. Coin size does not change the GPU search. Wait until the payment has **6 confirmations**, then:

```bash
bitcoin-cli -rpcwallet=mining listunspent 6 9999999
bitcoin-cli -rpcwallet=mining getstakinginfo
```

`weight` is the eligible amount in satoshis (`100000000` = 1 BTCW). Above 0, the wallet can mine. `0` means the coin is still immature, on a `bc1` address, or in another wallet.

If the coins are already on a `bc1` address, send the whole balance to the legacy address. That payment has to mature too.

```bash
bitcoin-cli -rpcwallet=mining -named sendtoaddress address="LEGACY_ADDRESS" amount=BALANCE subtractfeefromamount=true
```

### 3. Build

NVIDIA driver, CUDA toolkit, and `nvcc` on `PATH`. The GPU table is about 2.5 GB, so use a card with about 8 GB. A 4 GB card usually fails at startup.

| GPU | `CUDA_ARCH` | CUDA toolkit |
| --- | --- | --- |
| RTX 20-series, GTX 16-series | `sm_75` | 12.x |
| RTX 30-series | `sm_86` | 12.x |
| RTX 40-series | `sm_89` | 12.x |
| A100 | `sm_80` | 12.x |
| H100 | `sm_90` | 12.x |
| RTX 50-series | `sm_120` | 12.8 or newer |

Default is `sm_89`. A mismatch exits with “no kernel image”.

Linux, from this directory:

```bash
chmod +x build_cuda.sh
./build_cuda.sh
```

```bash
CUDA_ARCH=sm_120 ./build_cuda.sh
```

Windows, from an x64 Native Tools prompt:

```bat
build_cuda.bat
```

```bat
set CUDA_ARCH=sm_120
build_cuda.bat
```

Linux writes `release/btcw_cuda_miner`. Windows writes `release\btcw_cuda_miner.exe`. GitHub Actions builds an `sm_89` binary. Use that artifact only on an RTX 40-series GPU.

### 4. Mine

Same operating-system user for the node and the miner. On Windows, the same login session. One miner per node. Start the miner **before** staking. It opens the shared-memory connection the node writes into (`/dev/shm/shared_mem` on Linux, `shared_mem` on Windows). That mapping holds the staking private key during an attempt. Use an account you trust.

Unlock an encrypted wallet first. The Qt unlock dialog keeps the passphrase out of shell history. This example stays unlocked for 24 hours:

```bash
bitcoin-cli -rpcwallet=mining walletpassphrase "PASSPHRASE" 86400
```

```bash
./release/btcw_cuda_miner
```

```bat
release\btcw_cuda_miner.exe
```

The first argument is the GPU index. `0` is the first GPU. Leave the rest empty.

Startup runs two self-tests, then six `group 1/6` … `group 6/6` lines while it builds the GPU table. That is usually a couple of minutes and is not hashing yet. Then it prints `GPU initialized - waiting for block data...`.

`source=rpc` means the target is `next.signaturetarget` from `getmininginfo`. If `bitcoin-cli` is not on `PATH`, or the node uses `-datadir`, set this before launch:

```bash
export BTCW_CLI="$HOME/bitcoin-pow/bin/bitcoin-cli"
export BTCW_DATADIR="$HOME/.bitcoin-pow"
```

```bat
set BTCW_CLI=C:\path\to\bitcoin-cli.exe
set BTCW_DATADIR=%APPDATA%\Bitcoin-PoW
```

`BTCW_DATADIR` is only for a custom data directory. You can also pass the 64-hex target as the 4th argument, set `BTCW_SIG_TARGET`, or put that hex alone in `target.txt`. The miner refreshes the RPC target while it runs. Difficulty moves, so do not keep yesterday’s target.

Then:

```bash
bitcoin-cli -rpcwallet=mining setstaking true 30
bitcoin-cli -rpcwallet=mining getstakinginfo
```

Keep `30`. `mining` is `true` and `weight` is above 0.

Within a few seconds the miner prints `Connected to BTCW node wallet`, then a hashrate line about every 2 seconds. Read the rate after the first few lines. Each attempt lasts at most 30 seconds, then the node builds the next one. A brief `NOT CONNECTED` between attempts is normal. A line that stays there means staking is off, the wallet is locked, or `weight` is 0.

A long run of only `MH/s` is the normal case. `GPU share nonce=... submitted` means the GPU met the full target. The node log (`~/.bitcoin-pow/debug.log` or `%APPDATA%\Bitcoin-PoW\debug.log`) then shows `found=true` and `Mined BTCW block`. `signing_failed=true`, or a failed startup self-test, means this binary does not match the node. Stop and rebuild.

Staking does not resume after a restart. Start the node, wait until it is synced, start the miner, unlock, then `setstaking true 30` again.

Stop staking first, then `Ctrl+C` the miner:

```bash
bitcoin-cli -rpcwallet=mining setstaking false
```

## Timing

Blocks are targeted every **10 minutes**. Gaps of 20 or 30 minutes happen. ASERT takes about **3 hours** to halve or double the target when blocks run ahead or behind.

| Wait | Average |
| --- | --- |
| Next block | 10 minutes |
| 6 confirmations | about 50 minutes after the block that paid you, about 1 hour after the payment was sent |
| First sync | several hours; a hard disk often takes overnight or longer |
| GPU table at miner start | usually 1–2 minutes |
| One mining attempt | at most 30 seconds |
| Hashrate line | about every 2 seconds |

The subsidy is **50 BTCW** until height 210000, about 4 years of 10-minute blocks, then it halves. Fees in the block are added. The reward pays the same key that staked. There is no separate payout address.

There are about 4.29 billion signing cases in one attempt. A GPU near **143 MH/s** walks that space once in 30 seconds. Faster than that repeats cases until the next attempt. Slower covers less of each attempt, and the average wait grows in proportion.

## After you find a block

The balance updates at once with the returned stake, the 50 BTCW subsidy, and any fees. That new output needs 5 more blocks, about 50 minutes, before it can stake. With one UTXO, `weight` drops to 0 for that wait.

A second mature legacy UTXO keeps mining through it. Hashrate does not increase. Create `LEGACY_B`, send part of the balance there, and force the change back to a legacy address. Both outputs need 6 confirmations before you start.

```bash
bitcoin-cli -rpcwallet=mining -named send outputs='{"LEGACY_B": AMOUNT}' change_address="LEGACY_A"
```

## How long until a block

The network is aimed at one block every 10 minutes. `getmininginfo` field `networkhashps` counts chain work, which is **10,000,000** times the signature rate the GPU searches.

```text
network signature rate = networkhashps / 10000000
your average minutes   = 10 * (network signature rate) / (your MH/s * 1000000)
```

Example only: `40.00 MH/s` against `networkhashps` of `400000000000000` is about 10 minutes. At 4 MH/s against that same network, about 100 minutes.

`next.signaturetarget` is the other way to the same number. Average signatures to try is `2^256` divided by that target. Average seconds is that count divided by `MH/s * 1000000`.

About 63% of searches finish by the average. About half finish before 0.7 times the average. About 1 in 20 takes longer than 3 times the average. Steady `MH/s`, `weight` above 0, and a synced node means a long gap is an unlucky run.

## If it is not working

**No signature target.** `bitcoin-cli getmininginfo` must show `next.signaturetarget`. Set `BTCW_CLI` and, if needed, `BTCW_DATADIR`.

**`weight` is 0.** Legacy address starting with `1`, 6 confirmations, unlocked wallet, correct `-rpcwallet`.

**Wallet locked.** Unlock, then `setstaking true 30` again.

**NOT CONNECTED and it stays.** Same OS user, and on Windows the same desktop session. Miner started first. `getstakinginfo` shows `"mining": true`.

**Out of memory.** Close other GPU programs. Use a card with at least 8 GB.

**No kernel image.** Rebuild with that GPU’s `CUDA_ARCH`. RTX 50-series needs `sm_120` and CUDA 12.8+.

**Still syncing.** `initialblockdownload` must be false and the tip must be past block 144444.

## What the search is

The wallet picks a mature legacy output and builds a coinstake. The node writes that key and the unsigned-header hash into shared memory. The GPU tries 32-bit RFC6979 cases, the same extra entropy `CKey::Sign(grind=false, test_case)` uses, hashes the 70- or 71-byte DER signature, and compares it with the live target. The node signs that case itself and accepts the block only when the check passes. This miner does not submit blocks on its own.
