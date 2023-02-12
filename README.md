Testing: 
forge test -vvv

Script (locall):
forge script script/Vault.s.sol:VaultScript

Deployment test:
 - Edit .env to set the ETHERSCAN_API_KEY
 - export FANTOM_TEST_RPC_URL=https://xapi.testnet.fantom.network/lachesis
 - forge script script/Vault.s.sol:VaultScript --rpc-url $FANTOM_TEST_RPC_URL --broadcast --verify -vvvv

Finding contract addresses:
egrep "contractName|contract" ~/dev/zombie_finance/broadcast/Vault.s.sol/4002/run-latest.json

If using proxy contract, then have to inspect for Vault and GMDStake can be found by searching for `"contractName": "Vault"` in ./broadcast/Vault.s.sol/4002/run-latest.json, then find the subsequent `"contractName": "UUPSProxy"`.  This is the proxy contract to share publicily

--

Audit comments:
https://github.com/pashov/audits/blob/master/solo/GMD-security-review.md#recommendations-5 <- Prefer to do this inside the swaptoGLP() call.
---

from txn https://ftmscan.com/tx/0x2f76b43ade5fe5f512f93beaf2a97ef1baa354c90d6f0277e237af55a2e55e40

0xC59b9DB212a247536ecDBcc315A4514822D08fe3
54889508 (-1 from actual)

calling mintAndStakeGlp with:
0x21be370D5312f44cB42ce377BC9b8a0cEF1A4C83
3162471130677443922
0
0

block number
54889507 <-- only 07 works

tx index
2

insufficient funds for gas * price + value: address 0x6D4Cd626053884215bdCC8430e276eD5e14A6ECa have 1087430520897000 want 3253884664884000: invalid transaction simulation


