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
 *   4. 持久化部署地址到 deployments/bsc.json
 */
import {
    loadEnv,
    unlockWallet,
    runForgeScript,
    readDeploymentState,
    writeDeploymentState,
    extractBroadcastAddresses,
    requireEnv,
    readClean,
} from './shared.mjs';

// ---------------------------------------------------------------------------
// Action handlers
// ---------------------------------------------------------------------------

async function actionDeploy(dryRun) {
    requireEnv('OWNER', 'BNB_USD_ORACLE', 'MAX_ORACLE_DELAY');

    const wallet = await unlockWallet();

    // Step 1: Deploy implementation + proxy
    console.log('[deploy] step 1/2 — Deploy implementation + proxy');
    runForgeScript('script/Deploy.s.sol', {
        privateKey: wallet.privateKey,
        dryRun,
        extraArgs: [
            '--sig', 'run()',
        ],
    });

    if (!dryRun) {
        // Extract addresses from broadcast
        const broadcast = extractBroadcastAddresses('Deploy.s.sol');
        if (broadcast && broadcast.transactions) {
            const state = readDeploymentState();
            // last two contract creations: implementation, then proxy
            const creations = broadcast.transactions.filter(tx => tx.contractName || tx.transactionType === 'CREATE');
            if (creations.length >= 2) {
                state.implementation = creations[creations.length - 2].contractAddress || creations[creations.length - 2].hash;
                state.proxy = creations[creations.length - 1].contractAddress || creations[creations.length - 1].hash;
            }
            state.deployer = wallet.address;
            state.deployedAt = new Date().toISOString();
            writeDeploymentState(state);
            console.log(`[deploy] proxy: ${state.proxy}`);
            console.log(`[deploy] impl:  ${state.implementation}`);
        }
    }

    // Step 2: Post-deploy configure (auto)
    if (readClean(process.env.CONFIGURE_BSC_PAYMENT_TOKENS) !== 'false') {
        console.log('[deploy] step 2/2 — PostDeployConfigure');
        const proxyAddress = dryRun ? '0x0000000000000000000000000000000000000000' : readDeploymentState().proxy;
        if (!proxyAddress && !dryRun) {
            console.warn('[deploy] WARNING: no proxy address found, skipping PostDeployConfigure');
            return;
        }
        process.env.PROXY_ADDRESS = proxyAddress;
        runForgeScript('script/PostDeployConfigure.s.sol', {
            privateKey: wallet.privateKey,
            dryRun,
            extraArgs: ['--sig', 'run()'],
        });
    } else {
        console.log('[deploy] step 2/2 — PostDeployConfigure skipped (CONFIGURE_BSC_PAYMENT_TOKENS=false)');
    }
}

async function actionConfigure(dryRun) {
    requireEnv('PROXY_ADDRESS');
    const wallet = await unlockWallet();

    console.log('[configure] PostDeployConfigure');
    runForgeScript('script/PostDeployConfigure.s.sol', {
        privateKey: wallet.privateKey,
        dryRun,
        extraArgs: ['--sig', 'run()'],
    });
}

async function actionUpgrade(dryRun) {
    requireEnv('PROXY_ADDRESS');
    const wallet = await unlockWallet();

    console.log('[upgrade] deploy new implementation + upgradeToAndCall');
    runForgeScript('script/Upgrade.s.sol', {
        privateKey: wallet.privateKey,
        dryRun,
        extraArgs: ['--sig', 'run()'],
    });

    if (!dryRun) {
        const broadcast = extractBroadcastAddresses('Upgrade.s.sol');
        if (broadcast && broadcast.transactions) {
            const state = readDeploymentState();
            const creations = broadcast.transactions.filter(tx => tx.transactionType === 'CREATE');
            if (creations.length >= 1) {
                state.implementation = creations[creations.length - 1].contractAddress;
                state.upgradedAt = new Date().toISOString();
                writeDeploymentState(state);
                console.log(`[upgrade] new impl: ${state.implementation}`);
            }
        }
    }
}

async function actionUpgradeAndMigrate(dryRun) {
    requireEnv('PROXY_ADDRESS');
    const wallet = await unlockWallet();

    console.log('[upgrade-and-migrate] deploy new implementation + upgrade + migrate legacy stables');
    runForgeScript('script/UpgradeAndMigrate.s.sol', {
        privateKey: wallet.privateKey,
        dryRun,
        extraArgs: ['--sig', 'run()'],
    });

    if (!dryRun) {
        const broadcast = extractBroadcastAddresses('UpgradeAndMigrate.s.sol');
        if (broadcast && broadcast.transactions) {
            const state = readDeploymentState();
            const creations = broadcast.transactions.filter(tx => tx.transactionType === 'CREATE');
            if (creations.length >= 1) {
                state.implementation = creations[creations.length - 1].contractAddress;
                state.upgradedAt = new Date().toISOString();
                writeDeploymentState(state);
                console.log(`[upgrade-and-migrate] new impl: ${state.implementation}`);
            }
        }
    }
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
  upgrade             Upgrade to new implementation
  upgrade-and-migrate Upgrade + migrate legacy stable tokens

Options:
  --dry-run           Print forge commands without executing
  --help, -h          Show this help

Required .env vars:
  BSC_RPC_URL         BSC RPC endpoint
  DEPLOY_KEYSTORE_PATH or DEPLOY_PRIVATE_KEY
  OWNER               Contract owner address (for deploy)
  BNB_USD_ORACLE      Chainlink BNB/USD oracle address (for deploy)
  MAX_ORACLE_DELAY    Max oracle staleness in seconds (for deploy)
  PROXY_ADDRESS       Deployed proxy address (for configure/upgrade)
`);
}

async function main() {
    const args = parseArgs(process.argv.slice(2));
    if (args.help) { printHelp(); return; }

    await loadEnv();

    const handlers = {
        deploy: actionDeploy,
        configure: actionConfigure,
        upgrade: actionUpgrade,
        'upgrade-and-migrate': actionUpgradeAndMigrate,
    };

    const handler = handlers[args.action];
    if (!handler) {
        console.error(`Unknown action: ${args.action}`);
        console.error(`Valid actions: ${Object.keys(handlers).join(', ')}`);
        process.exit(1);
    }

    console.log(`[deploy] action=${args.action} dryRun=${args.dryRun}`);
    await handler(args.dryRun);
    console.log('[deploy] done');
}

main().catch(err => {
    console.error(`[deploy] FATAL: ${err.message}`);
    process.exit(1);
});
