import path from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';
import fs from 'node:fs';
import { execSync } from 'node:child_process';

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);
const PROJECT_ROOT = path.resolve(__dirname, '..');
const MONOREPO_ROOT = path.resolve(PROJECT_ROOT, '../..');
const KEYSTORE_UTIL_PATH = path.resolve(
    MONOREPO_ROOT,
    'packages/lp-manager/src/lib/wallet/walletUtlis.js',
);

// Lazy-loaded ethers (avoid ESM/CJS interop issues)
let _ethers = null;
async function getEthers() {
    if (_ethers) return _ethers;
    // ethers v5 CJS — dynamic import exposes named exports directly
    const mod = await import(pathToFileURL(path.join(MONOREPO_ROOT, 'node_modules/ethers/lib/ethers.js')).href);
    // CJS interop: Wallet is a named export
    _ethers = { Wallet: mod.Wallet };
    return _ethers;
}

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
// Keystore unlock
// ---------------------------------------------------------------------------

export function readClean(value) {
    if (!value) return undefined;
    let text = String(value).trim();
    // strip inline comments
    text = text.replace(/\s+(\/\/|#).*$/, '').trim();
    if (text.endsWith(';')) text = text.slice(0, -1).trim();
    if ((text.startsWith("'") && text.endsWith("'")) || (text.startsWith('"') && text.endsWith('"'))) {
        text = text.slice(1, -1).trim();
    }
    return text || undefined;
}

/**
 * Unlock deployer wallet.
 * Priority: DEPLOY_KEYSTORE_PATH (interactive) > DEPLOY_PRIVATE_KEY (direct)
 */
export async function unlockWallet() {
    const keystorePath = readClean(process.env.DEPLOY_KEYSTORE_PATH);
    const directKey = readClean(process.env.DEPLOY_PRIVATE_KEY);

    if (keystorePath) {
        if (!fs.existsSync(keystorePath)) {
            throw new Error(`Keystore not found: ${keystorePath}`);
        }
        const mod = await import(pathToFileURL(KEYSTORE_UTIL_PATH).href);
        const wallet = await mod.cmdOpen(keystorePath);
        if (!wallet || !wallet.privateKey) {
            throw new Error('Keystore unlock failed — no wallet returned');
        }
        console.log(`[deploy] unlocked ${wallet.address} from keystore`);
        return wallet;
    }

    if (directKey) {
        const ethers = await getEthers();
        const wallet = new ethers.Wallet(directKey);
        console.log(`[deploy] using direct key for ${wallet.address}`);
        return wallet;
    }

    throw new Error('No deployer wallet configured. Set DEPLOY_KEYSTORE_PATH or DEPLOY_PRIVATE_KEY in .env');
}

// ---------------------------------------------------------------------------
// Forge script runner
// ---------------------------------------------------------------------------

/**
 * Run a forge script with broadcast.
 * @param {string} scriptPath - relative path from project root, e.g. "script/Deploy.s.sol"
 * @param {object} opts
 * @param {string} opts.privateKey - deployer private key
 * @param {string[]} [opts.extraArgs] - additional forge script args
 * @param {boolean} [opts.dryRun] - if true, print command without executing
 */
export function runForgeScript(scriptPath, { privateKey, extraArgs = [], dryRun = false }) {
    const rpcUrl = readClean(process.env.BSC_RPC_URL);
    if (!rpcUrl) throw new Error('BSC_RPC_URL not set');

    const args = [
        'forge', 'script', scriptPath,
        '--rpc-url', rpcUrl,
        '--private-key', privateKey,
        '--broadcast',
        '--skip-simulation',
        ...extraArgs,
    ];

    const cmd = args.join(' ');
    console.log(`\n[forge] ${dryRun ? '(dry-run) ' : ''}${cmd}\n`);

    if (dryRun) return;

    try {
        execSync(cmd, {
            cwd: PROJECT_ROOT,
            stdio: 'inherit',
            env: { ...process.env },
        });
    } catch (err) {
        throw new Error(`forge script failed: ${scriptPath}`);
    }
}

// ---------------------------------------------------------------------------
// Deployment state persistence
// ---------------------------------------------------------------------------

const DEPLOYMENTS_DIR = path.join(PROJECT_ROOT, 'deployments');
const DEPLOYMENT_FILE = path.join(DEPLOYMENTS_DIR, 'bsc.json');

export function readDeploymentState() {
    if (!fs.existsSync(DEPLOYMENT_FILE)) return {};
    return JSON.parse(fs.readFileSync(DEPLOYMENT_FILE, 'utf8'));
}

export function writeDeploymentState(state) {
    if (!fs.existsSync(DEPLOYMENTS_DIR)) {
        fs.mkdirSync(DEPLOYMENTS_DIR, { recursive: true });
    }
    fs.writeFileSync(DEPLOYMENT_FILE, JSON.stringify(state, null, 2) + '\n');
}

/**
 * Parse forge script broadcast output to extract deployed addresses.
 * Reads the latest run-*.json from broadcast/ directory.
 */
export function extractBroadcastAddresses(scriptName) {
    const broadcastDir = path.join(PROJECT_ROOT, 'broadcast', scriptName);
    if (!fs.existsSync(broadcastDir)) return null;

    const chainDir = path.join(broadcastDir, '56'); // BSC chain ID
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
// Validation
// ---------------------------------------------------------------------------

export function requireEnv(...keys) {
    const missing = keys.filter(k => !readClean(process.env[k]));
    if (missing.length > 0) {
        throw new Error(`Missing required env vars: ${missing.join(', ')}`);
    }
}
