#!/usr/bin/env node
/**
 * auth-contract BSC 部署入口
 *
 * 用法：
 *   node deploy/deploy.mjs --action deploy [--dry-run]
 *   node deploy/deploy.mjs --action configure [--dry-run]
 *   node deploy/deploy.mjs --action upgrade [--dry-run]
 *   node deploy/deploy.mjs --action upgrade-and-migrate [--dry-run]
 *
 * 部署流程（deploy）：
 *   1. 解锁 keystore 钱包
 *   2. forge script Deploy.s.sol — 部署 implementation + ERC1967Proxy
 *   3. forge script PostDeployConfigure.s.sol — 配置 BSC 支付代币 + 试用
 *   4. 持久化部署地址到 deployments/<network>.json
 */
import {
    loadEnv,
    primeFoundryPrivateKey,
    resolveBscNetwork,
    unlockWallet,
    runForgeScript,
    readDeploymentState,
    writeDeploymentState,
    extractBroadcastAddresses,
    requireEnv,
    readClean,
    checkDeployerBalance,
    readMinDeployerBnb,
    readDeployConfigFromEnv,
    encodeProxyConstructorArgs,
    verifyContract,
} from './shared.mjs';

// ---------------------------------------------------------------------------
// Action handlers
// ---------------------------------------------------------------------------

function shouldConfigureBscPaymentTokens(network) {
    const explicit = readClean(process.env.CONFIGURE_BSC_PAYMENT_TOKENS);
    if (explicit) {
        const normalized = explicit.toLowerCase();
        if (normalized === 'true' || normalized === '1' || normalized === 'yes') {
            return true;
        }
        if (normalized === 'false' || normalized === '0' || normalized === 'no') {
            return false;
        }
        throw new Error(`Invalid CONFIGURE_BSC_PAYMENT_TOKENS value: ${explicit}`);
    }

    if (network.chainId !== 56) {
        console.log(
            '[deploy] CONFIGURE_BSC_PAYMENT_TOKENS not set; auto-skipping mainnet token/oracle profile on non-mainnet BSC',
        );
        process.env.CONFIGURE_BSC_PAYMENT_TOKENS = 'false';
        return false;
    }

    return true;
}

function captureDeployStateConfig(state) {
    const deployConfig = readDeployConfigFromEnv();
    if (deployConfig.owner) state.owner = deployConfig.owner;
    if (deployConfig.bnbUsdOracle) state.bnbUsdOracle = deployConfig.bnbUsdOracle;
    if (deployConfig.maxOracleDelay) state.maxOracleDelay = String(deployConfig.maxOracleDelay);
    return state;
}

function resolveProxyVerifyConstructorArgs(state) {
    const implementation = state.implementation;
    const owner = state.owner || readClean(process.env.OWNER);
    const bnbUsdOracle = state.bnbUsdOracle || readClean(process.env.BNB_USD_ORACLE);
    const maxOracleDelay = state.maxOracleDelay || readClean(process.env.MAX_ORACLE_DELAY);

    if (!implementation || !owner || !bnbUsdOracle || !maxOracleDelay) {
        return null;
    }

    return encodeProxyConstructorArgs(implementation, owner, bnbUsdOracle, maxOracleDelay);
}

async function actionDeploy(dryRun) {
    requireEnv('OWNER', 'BNB_USD_ORACLE', 'MAX_ORACLE_DELAY');
    const network = resolveBscNetwork();

    const wallet = await unlockWallet();
    if (!dryRun) {
        checkDeployerBalance(wallet.address, { rpcUrl: network.rpcUrl, minBnb: readMinDeployerBnb() });
    }

    // Step 1: Deploy implementation + proxy
    console.log(`[deploy] step 1/3 — Deploy implementation + proxy on ${network.label} (chainId=${network.chainId})`);
    runForgeScript('script/Deploy.s.sol', {
        privateKey: wallet.privateKey,
        rpcUrl: network.rpcUrl,
        dryRun,
        extraArgs: [
            '--sig', 'run()',
        ],
    });

    if (!dryRun) {
        // Extract addresses from broadcast
        const broadcast = extractBroadcastAddresses('Deploy.s.sol', network);
        if (broadcast && broadcast.transactions) {
            const state = readDeploymentState(network);
            // last two contract creations: implementation, then proxy
            const creations = broadcast.transactions.filter(tx => tx.contractName || tx.transactionType === 'CREATE');
            if (creations.length >= 2) {
                state.implementation = creations[creations.length - 2].contractAddress || creations[creations.length - 2].hash;
                state.proxy = creations[creations.length - 1].contractAddress || creations[creations.length - 1].hash;
            }
            state.deployer = wallet.address;
            state.chainId = network.chainId;
            state.network = network.label;
            state.deployedAt = new Date().toISOString();
            captureDeployStateConfig(state);
            writeDeploymentState(state, network);
            console.log(`[deploy] proxy: ${state.proxy}`);
            console.log(`[deploy] impl:  ${state.implementation}`);
        }
    }

    // Step 2: Post-deploy configure (auto)
    if (shouldConfigureBscPaymentTokens(network)) {
        console.log('[deploy] step 2/3 — PostDeployConfigure');
        const proxyAddress = dryRun ? '0x0000000000000000000000000000000000000000' : readDeploymentState(network).proxy;
        if (!proxyAddress && !dryRun) {
            console.warn('[deploy] WARNING: no proxy address found, skipping PostDeployConfigure');
        } else {
            process.env.PROXY_ADDRESS = proxyAddress;
            runForgeScript('script/PostDeployConfigure.s.sol', {
                privateKey: wallet.privateKey,
                rpcUrl: network.rpcUrl,
                dryRun,
                extraArgs: ['--sig', 'run()'],
            });
        }
    } else {
        console.log('[deploy] step 2/3 — PostDeployConfigure skipped (CONFIGURE_BSC_PAYMENT_TOKENS=false)');
    }

    // Step 3: Optional executor setup
    if (readClean(process.env.EXECUTOR)) {
        console.log('[deploy] step 3/3 — SetExecutor');
        const proxyAddress = dryRun ? '0x0000000000000000000000000000000000000000' : readDeploymentState(network).proxy;
        if (!proxyAddress && !dryRun) {
            console.warn('[deploy] WARNING: no proxy address found, skipping SetExecutor');
            return;
        }
        process.env.PROXY_ADDRESS = proxyAddress;
        runForgeScript('script/SetExecutor.s.sol', {
            privateKey: wallet.privateKey,
            rpcUrl: network.rpcUrl,
            dryRun,
            extraArgs: ['--sig', 'run()'],
        });
    } else {
        console.log('[deploy] step 3/3 — SetExecutor skipped (EXECUTOR not set)');
    }
}

async function actionConfigure(dryRun) {
    requireEnv('PROXY_ADDRESS');
    const network = resolveBscNetwork();
    const wallet = await unlockWallet();

    if (shouldConfigureBscPaymentTokens(network) || readClean(process.env.GLOBAL_TRIAL_ENDS_AT) || readClean(process.env.TOPIC_TRIAL_KEYS)) {
        console.log(`[configure] PostDeployConfigure on ${network.label} (chainId=${network.chainId})`);
        runForgeScript('script/PostDeployConfigure.s.sol', {
            privateKey: wallet.privateKey,
            rpcUrl: network.rpcUrl,
            dryRun,
            extraArgs: ['--sig', 'run()'],
        });
    } else {
        console.log('[configure] PostDeployConfigure skipped (no active payment-token or trial configuration)');
    }

    if (readClean(process.env.EXECUTOR)) {
        console.log('[configure] SetExecutor');
        runForgeScript('script/SetExecutor.s.sol', {
            privateKey: wallet.privateKey,
            rpcUrl: network.rpcUrl,
            dryRun,
            extraArgs: ['--sig', 'run()'],
        });
    }
}

async function actionSetExecutor(dryRun) {
    requireEnv('PROXY_ADDRESS', 'EXECUTOR');
    const network = resolveBscNetwork();
    const wallet = await unlockWallet();

    console.log(`[set-executor] update executor on ${network.label} (chainId=${network.chainId})`);
    runForgeScript('script/SetExecutor.s.sol', {
        privateKey: wallet.privateKey,
        rpcUrl: network.rpcUrl,
        dryRun,
        extraArgs: ['--sig', 'run()'],
    });
}

async function actionUpgrade(dryRun) {
    requireEnv('PROXY_ADDRESS');
    const network = resolveBscNetwork();
    const wallet = await unlockWallet();

    console.log(`[upgrade] deploy new implementation + upgradeToAndCall on ${network.label} (chainId=${network.chainId})`);
    runForgeScript('script/Upgrade.s.sol', {
        privateKey: wallet.privateKey,
        rpcUrl: network.rpcUrl,
        dryRun,
        extraArgs: ['--sig', 'run()'],
    });

    if (!dryRun) {
        const broadcast = extractBroadcastAddresses('Upgrade.s.sol', network);
        if (broadcast && broadcast.transactions) {
            const state = readDeploymentState(network);
            const creations = broadcast.transactions.filter(tx => tx.transactionType === 'CREATE');
            if (creations.length >= 1) {
                state.implementation = creations[creations.length - 1].contractAddress;
                state.upgradedAt = new Date().toISOString();
                state.chainId = network.chainId;
                state.network = network.label;
                writeDeploymentState(state, network);
                console.log(`[upgrade] new impl: ${state.implementation}`);
            }
        }
    }
}

async function actionUpgradeAndMigrate(dryRun) {
    requireEnv('PROXY_ADDRESS');
    const network = resolveBscNetwork();
    const wallet = await unlockWallet();

    console.log(
        `[upgrade-and-migrate] deploy new implementation + upgrade + migrate legacy stables on ${network.label} (chainId=${network.chainId})`,
    );
    runForgeScript('script/UpgradeAndMigrate.s.sol', {
        privateKey: wallet.privateKey,
        rpcUrl: network.rpcUrl,
        dryRun,
        extraArgs: ['--sig', 'run()'],
    });

    if (!dryRun) {
        const broadcast = extractBroadcastAddresses('UpgradeAndMigrate.s.sol', network);
        if (broadcast && broadcast.transactions) {
            const state = readDeploymentState(network);
            const creations = broadcast.transactions.filter(tx => tx.transactionType === 'CREATE');
            if (creations.length >= 1) {
                state.implementation = creations[creations.length - 1].contractAddress;
                state.upgradedAt = new Date().toISOString();
                state.chainId = network.chainId;
                state.network = network.label;
                writeDeploymentState(state, network);
                console.log(`[upgrade-and-migrate] new impl: ${state.implementation}`);
            }
        }
    }
}

async function actionVerify() {
    const network = resolveBscNetwork();
    const state = readDeploymentState(network);
    if (!state.implementation) {
        throw new Error('No implementation address found in deployment state. Deploy first.');
    }

    console.log(`[verify] verifying contracts on ${network.label} (chainId=${network.chainId})`);
    verifyContract(
        state.implementation,
        'src/TopicAccessManagerUpgradeable.sol:TopicAccessManagerUpgradeable',
        { network },
    );

    if (state.proxy) {
        console.log('[verify] verifying proxy contract');
        const constructorArgs = resolveProxyVerifyConstructorArgs(state);
        if (!constructorArgs) {
            console.warn(
                '[verify] WARNING: missing deploy config for proxy constructor args; set OWNER/BNB_USD_ORACLE/MAX_ORACLE_DELAY or redeploy with the updated state writer',
            );
            return;
        }
        verifyContract(state.proxy, 'lib/openzeppelin-contracts/proxy/ERC1967/ERC1967Proxy.sol:ERC1967Proxy', {
            network,
            constructorArgs: [constructorArgs],
        });
    }
}

async function actionWalletAddress() {
    const wallet = await unlockWallet();
    console.log(`[deploy] wallet address: ${wallet.address}`);
}

// ---------------------------------------------------------------------------
// CLI
// ---------------------------------------------------------------------------

function parseArgs(argv) {
    const args = { action: 'deploy', dryRun: false };
    for (let i = 0; i < argv.length; i++) {
        const cur = argv[i];
        const next = argv[i + 1];
        if (cur === '--action' && next) { args.action = next; i++; continue; }
        if (cur === '--dry-run') { args.dryRun = true; continue; }
        if (cur === '--help' || cur === '-h') { args.help = true; }
    }
    return args;
}

function printHelp() {
    console.log(`
auth-contract BSC deployer

Usage:
  node deploy/deploy.mjs --action <action> [--dry-run]

Actions:
  deploy              Deploy implementation + proxy + auto-configure (default)
  configure           Run PostDeployConfigure on existing proxy
  set-executor        Set executor on existing proxy
  upgrade             Upgrade to new implementation
  upgrade-and-migrate Upgrade + migrate legacy stable tokens
  verify              Verify deployed contracts on BSCScan
  wallet-address      Print the deployer wallet address resolved from keystore/private key

Options:
  --dry-run           Print forge commands without executing
  --help, -h          Show this help

Required .env vars:
  BSC_RPC_URL         BSC mainnet or BSC testnet RPC endpoint
  AUTH_DEPLOY_KEYSTORE_PATH or AUTH_DEPLOY_PRIVATE_KEY
                    (DEPLOY_KEYSTORE_PATH / DEPLOY_PRIVATE_KEY / OMNIX_DEPLOY_KEYSTORE_PATH / OMNIX_DEPLOY_PRIVATE_KEY are accepted as fallback)
  OWNER               Contract owner address (for deploy)
  BNB_USD_ORACLE      Chainlink BNB/USD oracle address (for deploy)
  MAX_ORACLE_DELAY    Max oracle staleness in seconds (for deploy)
  PROXY_ADDRESS       Deployed proxy address (for configure/upgrade)
  EXECUTOR            Optional executor address (for deploy/configure/set-executor)
  BSCSCAN_API_KEY     BSCScan API key (for verify)

Notes:
  On BSC testnet, CONFIGURE_BSC_PAYMENT_TOKENS defaults to false unless you set it explicitly.
`);
}

async function main() {
    const args = parseArgs(process.argv.slice(2));
    if (args.help) { printHelp(); return; }

    await loadEnv();

    const handlers = {
        deploy: actionDeploy,
        configure: actionConfigure,
        'set-executor': actionSetExecutor,
        upgrade: actionUpgrade,
        'upgrade-and-migrate': actionUpgradeAndMigrate,
        verify: actionVerify,
        'wallet-address': actionWalletAddress,
    };

    const handler = handlers[args.action];
    if (!handler) {
        console.error(`Unknown action: ${args.action}`);
        console.error(`Valid actions: ${Object.keys(handlers).join(', ')}`);
        process.exit(1);
    }

    console.log(`[deploy] action=${args.action} dryRun=${args.dryRun}`);
    await primeFoundryPrivateKey(args.action);
    await handler(args.dryRun);
    console.log('[deploy] done');
}

main().catch(err => {
    console.error(`[deploy] FATAL: ${err.message}`);
    process.exit(1);
});
