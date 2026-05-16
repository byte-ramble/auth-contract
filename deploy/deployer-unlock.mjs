import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';
import readlineSync from 'readline-sync';
import { Wallet, utils } from 'ethers';

const SIGNER_ACTIONS = new Set([
    'deploy',
    'configure',
    'deploy-implementation',
    'upgrade',
    'upgrade-and-migrate',
    'set-executor',
    'setup-topic-expiry',
]);

let cachedUnlockedWallet = null;
let cachedKeystorePath = null;

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

function extractAddressFromKeystoreJson(keystorePath, getAddress) {
    if (!fs.existsSync(keystorePath)) {
        throw new Error(`Keystore not found: ${keystorePath}`);
    }

    const parsed = readKeystoreJsonObject(keystorePath).keystore;
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

export function readKeystoreJsonObject(keystorePath) {
    if (!fs.existsSync(keystorePath)) {
        throw new Error(`Keystore not found: ${keystorePath}`);
    }

    const raw = fs.readFileSync(keystorePath, 'utf8');
    let parsed = JSON.parse(raw);
    const wasJsonString = typeof parsed === 'string';
    if (wasJsonString) {
        parsed = JSON.parse(parsed);
    }
    if (!parsed || typeof parsed !== 'object' || Array.isArray(parsed)) {
        throw new Error(`Invalid keystore JSON object: ${keystorePath}`);
    }
    return { keystore: parsed, wasJsonString };
}

export function normalizeKeystorePathForForge(keystorePath, { cacheDir } = {}) {
    if (!keystorePath) return { keystorePath, normalized: false };

    const result = readKeystoreJsonObject(keystorePath);
    if (!result.wasJsonString) {
        return { keystorePath, normalized: false };
    }

    const outputDir = cacheDir || path.join(path.dirname(keystorePath), '.normalized-keystores');
    fs.mkdirSync(outputDir, { recursive: true, mode: 0o700 });

    const hash = crypto
        .createHash('sha256')
        .update(path.resolve(keystorePath))
        .digest('hex')
        .slice(0, 12);
    const basename = path.basename(keystorePath).replace(/[^A-Za-z0-9_.-]/g, '_');
    const outputPath = path.join(outputDir, `${hash}-${basename}`);
    fs.writeFileSync(outputPath, `${JSON.stringify(result.keystore, null, 2)}\n`, { mode: 0o600 });
    fs.chmodSync(outputPath, 0o600);

    return { keystorePath: outputPath, normalized: true, originalKeystorePath: keystorePath };
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

export function readSingleUnlockEnabled(env = process.env) {
    const raw = readCleanValue(env.AUTH_SINGLE_UNLOCK || env.DEPLOY_SINGLE_UNLOCK);
    if (!raw) return false;
    return /^(1|true|yes|on)$/i.test(raw);
}

export function readConfiguredKeystorePath(env = process.env) {
    return (
        readCleanValue(env.AUTH_DEPLOY_KEYSTORE_PATH)
        || readCleanValue(env.DEPLOY_KEYSTORE_PATH)
        || readCleanValue(env.OMNIX_DEPLOY_KEYSTORE_PATH)
    );
}

export async function resolveDeployerIdentity({ env = process.env } = {}) {
    const getAddress = utils.getAddress;
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

export async function loadWalletFromKeystore(keystorePath, { readPassword } = {}) {
    if (!keystorePath) {
        throw new Error('Missing keystore path');
    }

    const { keystore } = readKeystoreJsonObject(keystorePath);
    const passwordReader = readPassword || (() => readlineSync.question('keystore password: ', {
        hideEchoBack: true,
    }));
    const password = passwordReader();

    try {
        return await Wallet.fromEncryptedJson(JSON.stringify(keystore), password);
    } catch (error) {
        throw new Error(`Unable to decrypt keystore ${keystorePath}: ${error.message}`);
    }
}

export async function maybePrimeSingleUnlock({
    action,
    env = process.env,
    setEnv = (key, value) => {
        env[key] = value;
    },
    log = console.log,
    readPassword,
} = {}) {
    if (!readSingleUnlockEnabled(env)) {
        return { primed: false, reason: 'single-unlock-disabled' };
    }

    return primeDeployerPrivateKey({
        action,
        env,
        setEnv,
        loadWalletFromKeystore: (keystorePath) => loadWalletFromKeystore(keystorePath, { readPassword }),
        log,
    });
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
