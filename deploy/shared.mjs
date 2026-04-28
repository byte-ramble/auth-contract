import path from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';
import fs from 'node:fs';
import { execFileSync } from 'node:child_process';
import {
    readCleanValue,
    readConfiguredDeployPrivateKey,
    readConfiguredKeystorePath,
    resolveDeployerIdentity,
} from './deployer-unlock.mjs';

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);
const PROJECT_ROOT = path.resolve(__dirname, '..');
const MONOREPO_ROOT = path.resolve(PROJECT_ROOT, '../../..');

const BSC_MAINNET_CHAIN_ID = 56;
const BSC_TESTNET_CHAIN_ID = 97;
const BSC_NETWORKS = new Map([
    [BSC_MAINNET_CHAIN_ID, { chainId: BSC_MAINNET_CHAIN_ID, label: 'bsc', deploymentFile: 'bsc.json', verifyChain: 'bsc' }],
    [
        BSC_TESTNET_CHAIN_ID,
        { chainId: BSC_TESTNET_CHAIN_ID, label: 'bsc-testnet', deploymentFile: 'bsc-testnet.json', verifyChain: 'bsc-testnet' },
    ],
]);

let cachedResolvedNetwork = null;

// ---------------------------------------------------------------------------
// Env loading
// ---------------------------------------------------------------------------

export async function loadEnv() {
    const dotenvPath = path.join(MONOREPO_ROOT, 'node_modules', 'dotenv', 'lib', 'main.js');
    if (!fs.existsSync(dotenvPath)) {
        throw new Error(`dotenv not found at ${dotenvPath}`);
    }
    const dotenv = await import(pathToFileURL(dotenvPath).href);

    // Project .env first, then monorepo root as fallback
    dotenv.config({ path: path.join(PROJECT_ROOT, '.env') });
    dotenv.config({ path: path.join(MONOREPO_ROOT, '.env') });
}

// ---------------------------------------------------------------------------
// Deployer identity
// ---------------------------------------------------------------------------

export function readClean(value) {
    return readCleanValue(value);
}

export async function unlockWallet() {
    const wallet = await resolveDeployerIdentity({ env: process.env });
    if (!wallet) {
        throw new Error(
            'No deployer wallet configured. Set AUTH_DEPLOY_KEYSTORE_PATH/AUTH_DEPLOY_PRIVATE_KEY, DEPLOY_KEYSTORE_PATH/DEPLOY_PRIVATE_KEY, or OMNIX_DEPLOY_KEYSTORE_PATH/OMNIX_DEPLOY_PRIVATE_KEY in .env',
        );
    }

    if (wallet.mode === 'keystore') {
        console.log(`[deploy] using keystore signer ${wallet.address}`);
    } else if (readConfiguredDeployPrivateKey(process.env)) {
        console.log(`[deploy] using direct key for ${wallet.address}`);
    }

    return wallet;
}

export function getRpcUrl() {
    const rpcUrl = readClean(process.env.BSC_RPC_URL) || readClean(process.env.RPC_URL);
    if (!rpcUrl) {
        throw new Error('BSC_RPC_URL not set');
    }
    return rpcUrl;
}

function detectChainId(rpcUrl) {
    const result = execFileSync('cast', ['chain-id', '--rpc-url', rpcUrl], {
        cwd: PROJECT_ROOT,
        encoding: 'utf8',
        timeout: 15_000,
    }).trim();
    const chainId = Number(result);
    if (!Number.isInteger(chainId) || chainId <= 0) {
        throw new Error(`Invalid chain id returned by RPC: ${result}`);
    }
    return chainId;
}

export function resolveBscNetwork() {
    const rpcUrl = getRpcUrl();
    if (cachedResolvedNetwork && cachedResolvedNetwork.rpcUrl === rpcUrl) {
        return cachedResolvedNetwork;
    }

    const chainId = detectChainId(rpcUrl);
    const network = BSC_NETWORKS.get(chainId);
    if (!network) {
        throw new Error(`Unsupported BSC deployment chain id: ${chainId}. Expected 56 (mainnet) or 97 (testnet).`);
    }

    cachedResolvedNetwork = {
        ...network,
        rpcUrl,
        deploymentFilePath: path.join(PROJECT_ROOT, 'deployments', network.deploymentFile),
    };
    return cachedResolvedNetwork;
}

export function readMinDeployerBnb() {
    const raw = readClean(process.env.MIN_DEPLOYER_BNB);
    if (!raw) return 0.01;

    const value = Number(raw);
    if (!Number.isFinite(value) || value <= 0) {
        throw new Error(`Invalid MIN_DEPLOYER_BNB: ${raw}`);
    }
    return value;
}

export function readDeployConfigFromEnv() {
    return {
        owner: readClean(process.env.OWNER),
        bnbUsdOracle: readClean(process.env.BNB_USD_ORACLE),
        maxOracleDelay: readClean(process.env.MAX_ORACLE_DELAY),
    };
}

// ---------------------------------------------------------------------------
// Forge script runner
// ---------------------------------------------------------------------------

/**
 * Run a forge script with broadcast.
 * @param {string} scriptPath - relative path from project root, e.g. "script/Deploy.s.sol"
 * @param {object} opts
 * @param {string} [opts.privateKey] - deployer private key
 * @param {string} [opts.keystorePath] - deployer keystore path
 * @param {string} opts.rpcUrl - rpc url
 * @param {string} [opts.sender] - explicit sender address for forge broadcast
 * @param {string[]} [opts.extraArgs] - additional forge script args
 * @param {boolean} [opts.dryRun] - if true, print command without executing
 */
export function buildForgeScriptArgs(scriptPath, { privateKey, keystorePath, rpcUrl, sender, extraArgs = [] }) {
    return [
        'script', scriptPath,
        '--rpc-url', rpcUrl,
        '--broadcast',
        ...(sender ? ['--sender', sender] : []),
        ...(keystorePath ? ['--keystore', keystorePath] : []),
        ...(privateKey ? ['--private-key', privateKey] : []),
        ...extraArgs,
    ];
}

function redactForgeArgsForLog(args) {
    const redacted = [...args];
    for (let i = 0; i < redacted.length; i += 1) {
        if (redacted[i] === '--private-key' && i + 1 < redacted.length) {
            redacted[i + 1] = '[REDACTED_PRIVATE_KEY]';
            i += 1;
        }
    }
    return redacted;
}

export function runForgeScript(scriptPath, { privateKey, keystorePath, rpcUrl, sender, extraArgs = [], dryRun = false }) {
    const args = buildForgeScriptArgs(scriptPath, { privateKey, keystorePath, rpcUrl, sender, extraArgs });

    // Log command without sensitive data
    const cmd = ['forge', ...redactForgeArgsForLog(args)].join(' ');
    console.log(`\n[forge] ${dryRun ? '(dry-run) ' : ''}${cmd}\n`);

    if (dryRun) return;

    try {
        execFileSync('forge', args, {
            cwd: PROJECT_ROOT,
            stdio: 'inherit',
            env: { ...process.env, ...(sender ? { ETH_FROM: sender } : {}) },
        });
    } catch (err) {
        throw new Error(`forge script failed: ${scriptPath}`);
    }
}

// ---------------------------------------------------------------------------
// Deployment state persistence
// ---------------------------------------------------------------------------

const DEPLOYMENTS_DIR = path.join(PROJECT_ROOT, 'deployments');

export function readDeploymentState(network = resolveBscNetwork()) {
    if (!fs.existsSync(network.deploymentFilePath)) return {};
    return JSON.parse(fs.readFileSync(network.deploymentFilePath, 'utf8'));
}

export function writeDeploymentState(state, network = resolveBscNetwork()) {
    if (!fs.existsSync(DEPLOYMENTS_DIR)) {
        fs.mkdirSync(DEPLOYMENTS_DIR, { recursive: true });
    }
    fs.writeFileSync(network.deploymentFilePath, JSON.stringify(state, null, 2) + '\n');
}

/**
 * Parse forge script broadcast output to extract deployed addresses.
 * Reads the latest run-*.json from broadcast/ directory.
 */
export function extractBroadcastAddresses(scriptName, network = resolveBscNetwork()) {
    const broadcastDir = path.join(PROJECT_ROOT, 'broadcast', scriptName);
    if (!fs.existsSync(broadcastDir)) return null;

    const chainDir = path.join(broadcastDir, String(network.chainId));
    if (!fs.existsSync(chainDir)) return null;

    const files = fs.readdirSync(chainDir)
        .filter(f => f.startsWith('run-') && f.endsWith('.json'))
        .sort()
        .reverse();

    if (files.length === 0) return null;

    const latest = JSON.parse(fs.readFileSync(path.join(chainDir, files[0]), 'utf8'));
    return latest;
}

// ---------------------------------------------------------------------------
// Deployer balance check
// ---------------------------------------------------------------------------

/**
 * Check deployer BNB balance before deployment.
 * @param {string} address - deployer address
 * @param {object} opts
 * @param {string} opts.rpcUrl
 * @param {number} [opts.minBnb=0.01] - minimum required BNB balance
 */
export function checkDeployerBalance(address, { rpcUrl, minBnb = 0.01 }) {
    try {
        const result = execFileSync('cast', ['balance', address, '--rpc-url', rpcUrl], {
            cwd: PROJECT_ROOT,
            encoding: 'utf8',
            timeout: 15_000,
        }).trim();

        const balanceWei = BigInt(result);
        const balanceEth = Number(balanceWei) / 1e18;
        console.log(`[deploy] deployer balance: ${balanceEth.toFixed(4)} BNB`);

        if (balanceEth < minBnb) {
            throw new Error(`Deployer balance too low: ${balanceEth.toFixed(4)} BNB < ${minBnb} BNB minimum`);
        }
    } catch (err) {
        if (err.message.includes('too low')) throw err;
        console.warn(`[deploy] WARNING: could not check deployer balance: ${err.message}`);
    }
}

// ---------------------------------------------------------------------------
// Contract verification
// ---------------------------------------------------------------------------

/**
 * Verify contract on BSCScan.
 * @param {string} contractAddress - deployed contract address
 * @param {string} contractPath - e.g. "src/TopicAccessManagerUpgradeable.sol:TopicAccessManagerUpgradeable"
 * @param {object} opts
 * @param {string[]} [constructorArgs] - constructor arguments (if any)
 */
export function verifyContract(contractAddress, contractPath, { constructorArgs = [], network = resolveBscNetwork() } = {}) {
    const apiKey = readClean(process.env.BSCSCAN_API_KEY);
    if (!apiKey) {
        console.warn('[verify] WARNING: BSCSCAN_API_KEY not set, skipping verification');
        return;
    }

    const args = [
        'verify-contract',
        contractAddress,
        contractPath,
        '--chain', network.verifyChain,
        '--etherscan-api-key', apiKey,
        '--watch',
    ];

    if (constructorArgs.length > 0) {
        args.push('--constructor-args', ...constructorArgs);
    }

    const cmd = ['forge', ...args].join(' ');
    console.log(`\n[verify] ${cmd}\n`);

    try {
        execFileSync('forge', args, {
            cwd: PROJECT_ROOT,
            stdio: 'inherit',
            timeout: 120_000,
        });
        console.log(`[verify] ${contractAddress} verified successfully`);
    } catch (err) {
        console.warn(`[verify] WARNING: verification failed for ${contractAddress}: ${err.message}`);
    }
}

export function encodeInitializerCalldata(owner, bnbUsdOracle, maxOracleDelay) {
    return execFileSync(
        'cast',
        ['calldata', 'initialize(address,address,uint256)', owner, bnbUsdOracle, String(maxOracleDelay)],
        {
            cwd: PROJECT_ROOT,
            encoding: 'utf8',
            timeout: 15_000,
        },
    ).trim();
}

export function encodeProxyConstructorArgs(implementation, owner, bnbUsdOracle, maxOracleDelay) {
    const initData = encodeInitializerCalldata(owner, bnbUsdOracle, maxOracleDelay);
    return execFileSync(
        'cast',
        ['abi-encode', 'constructor(address,bytes)', implementation, initData],
        {
            cwd: PROJECT_ROOT,
            encoding: 'utf8',
            timeout: 15_000,
        },
    ).trim();
}

// ---------------------------------------------------------------------------
// Validation
// ---------------------------------------------------------------------------

export function requireEnv(...keys) {
    const missing = keys.filter(k => !readClean(process.env[k]));
    if (missing.length > 0) {
        throw new Error(`Missing required env vars: ${missing.join(', ')}`);
    }
}
