import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);
const PROJECT_ROOT = path.resolve(__dirname, '..');
const MONOREPO_ROOT = path.resolve(PROJECT_ROOT, '../..');

const SIGNER_ACTIONS = new Set(['deploy', 'configure', 'upgrade', 'upgrade-and-migrate', 'set-executor']);

let cachedUnlockedWallet = null;
let cachedKeystorePath = null;
let cachedWalletModule = null;

export function readCleanValue(value) {
    if (value === undefined || value === null) return undefined;
    let text = String(value).trim();
    if (!text) return undefined;

    const slashCommentMatch = text.match(/\s+\/\/.*$/);
    if (slashCommentMatch && slashCommentMatch.index !== undefined) {
        text = text.slice(0, slashCommentMatch.index).trim();
    }

    const hashCommentMatch = text.match(/\s+#.*$/);
    if (hashCommentMatch && hashCommentMatch.index !== undefined) {
        text = text.slice(0, hashCommentMatch.index).trim();
    }

    if (text.endsWith(';')) {
        text = text.slice(0, -1).trim();
    }
    if (
        (text.startsWith("'") && text.endsWith("'")) ||
        (text.startsWith('"') && text.endsWith('"'))
    ) {
        text = text.slice(1, -1).trim();
    }

    return text || undefined;
}

async function getWalletModule() {
    if (cachedWalletModule) return cachedWalletModule;

    const mod = await import(pathToFileURL(path.join(MONOREPO_ROOT, 'node_modules/ethers/lib/ethers.js')).href);
    cachedWalletModule = { Wallet: mod.Wallet, getAddress: mod.utils.getAddress };
    return cachedWalletModule;
}

function extractAddressFromKeystoreJson(keystorePath, getAddress) {
    if (!fs.existsSync(keystorePath)) {
        throw new Error(`Keystore not found: ${keystorePath}`);
    }

    const parsed = JSON.parse(fs.readFileSync(keystorePath, 'utf8'));
    const rawAddress = readCleanValue(parsed?.address) || readCleanValue(parsed?.Address);
    if (rawAddress) {
        return getAddress(rawAddress.startsWith('0x') ? rawAddress : `0x${rawAddress}`);
    }

    const basename = path.basename(keystorePath);
    const match = basename.match(/0x[a-fA-F0-9]{40}|[a-fA-F0-9]{40}/);
    if (match) {
        const candidate = match[0].startsWith('0x') ? match[0] : `0x${match[0]}`;
        return getAddress(candidate);
    }

    throw new Error(`Could not determine wallet address from keystore: ${keystorePath}`);
}

function normalizeAction(action) {
    return String(action || 'deploy')
        .trim()
        .toLowerCase();
}

export function deployActionNeedsSigner(action) {
    return SIGNER_ACTIONS.has(normalizeAction(action));
}

export function readConfiguredDeployPrivateKey(env = process.env) {
    return (
        readCleanValue(env.AUTH_DEPLOY_PRIVATE_KEY)
        || readCleanValue(env.DEPLOY_PRIVATE_KEY)
        || readCleanValue(env.OMNIX_DEPLOY_PRIVATE_KEY)
    );
}

export function readConfiguredKeystorePath(env = process.env) {
    return (
        readCleanValue(env.AUTH_DEPLOY_KEYSTORE_PATH)
        || readCleanValue(env.DEPLOY_KEYSTORE_PATH)
        || readCleanValue(env.OMNIX_DEPLOY_KEYSTORE_PATH)
    );
}

export async function resolveDeployerIdentity({ env = process.env } = {}) {
    const { Wallet, getAddress } = await getWalletModule();
    const keystorePath = readConfiguredKeystorePath(env);
    if (keystorePath) {
        return {
            mode: 'keystore',
            keystorePath,
            address: extractAddressFromKeystoreJson(keystorePath, getAddress),
        };
    }

    const directPrivateKey = readConfiguredDeployPrivateKey(env);
    if (directPrivateKey) {
        const wallet = new Wallet(directPrivateKey);
        return {
            mode: 'private-key',
            privateKey: wallet.privateKey,
            address: wallet.address,
        };
    }

    return null;
}

function normalizeWallet(wallet, Wallet) {
    if (wallet instanceof Wallet) {
        return wallet;
    }

    const privateKey = readCleanValue(wallet?.privateKey);
    if (!privateKey) {
        throw new Error('Keystore unlock did not return a wallet with a privateKey');
    }

    return new Wallet(privateKey);
}

export async function unlockDeployerWalletOnce({ env = process.env, loadWalletFromKeystore }) {
    const { Wallet } = await getWalletModule();
    const keystorePath = readConfiguredKeystorePath(env);
    if (keystorePath) {
        if (typeof loadWalletFromKeystore !== 'function') {
            throw new Error('unlockDeployerWalletOnce requires loadWalletFromKeystore');
        }

        if (cachedUnlockedWallet && cachedKeystorePath === keystorePath) {
            return cachedUnlockedWallet;
        }

        const wallet = normalizeWallet(await loadWalletFromKeystore(keystorePath), Wallet);
        cachedUnlockedWallet = wallet;
        cachedKeystorePath = keystorePath;
        return wallet;
    }

    const directPrivateKey = readConfiguredDeployPrivateKey(env);
    if (directPrivateKey) {
        return new Wallet(directPrivateKey);
    }

    return null;
}

export async function primeDeployerPrivateKey({
    action,
    env = process.env,
    setEnv = (key, value) => {
        env[key] = value;
    },
    loadWalletFromKeystore,
    log = console.log,
}) {
    if (!deployActionNeedsSigner(action)) {
        return { primed: false, reason: 'action-does-not-require-signer' };
    }

    const keystorePath = readConfiguredKeystorePath(env);
    if (keystorePath) {
        const wallet = await unlockDeployerWalletOnce({ env, loadWalletFromKeystore });
        setEnv('AUTH_DEPLOY_PRIVATE_KEY', wallet.privateKey);

        if (typeof log === 'function') {
            log(`[deploy] unlocked deployer ${wallet.address} from keystore`);
        }

        return {
            primed: true,
            reason: 'keystore-unlocked',
            address: wallet.address,
            keystorePath,
        };
    }

    const directPrivateKey = readConfiguredDeployPrivateKey(env);
    if (directPrivateKey) {
        return { primed: false, reason: 'private-key-already-configured' };
    }

    return { primed: false, reason: 'no-keystore-path-configured' };
}

export function resetDeployerUnlockCache() {
    cachedUnlockedWallet = null;
    cachedKeystorePath = null;
}
