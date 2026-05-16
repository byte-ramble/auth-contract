import test from 'node:test';
import assert from 'node:assert/strict';
import { ethers } from 'ethers';
import { buildForgeScriptArgs } from './shared.mjs';
import {
    deployActionNeedsSigner,
    normalizeKeystorePathForForge,
    maybePrimeSingleUnlock,
    primeDeployerPrivateKey,
    readConfiguredKeystorePath,
    readKeystoreJsonObject,
    readSingleUnlockEnabled,
    resetDeployerUnlockCache,
    resolveDeployerIdentity,
    unlockDeployerWalletOnce,
} from './deployer-unlock.mjs';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';

test.afterEach(() => {
    resetDeployerUnlockCache();
});

test('buildForgeScriptArgs binds sender and private key for broadcast signing', () => {
    const args = buildForgeScriptArgs('script/Deploy.s.sol', {
        privateKey: '0x' + '11'.repeat(32),
        rpcUrl: 'https://bsc-dataseed.binance.org',
        sender: '0xC8d52A5245aF5F2B095223F0Cd7468A7E670F22A',
        extraArgs: ['--sig', 'run()'],
    });

    assert.deepEqual(args, [
        'script',
        'script/Deploy.s.sol',
        '--rpc-url',
        'https://bsc-dataseed.binance.org',
        '--broadcast',
        '--sender',
        '0xC8d52A5245aF5F2B095223F0Cd7468A7E670F22A',
        '--private-key',
        '0x' + '11'.repeat(32),
        '--sig',
        'run()',
    ]);
});

test('buildForgeScriptArgs prefers keystore signing without exposing private key', () => {
    const args = buildForgeScriptArgs('script/Deploy.s.sol', {
        keystorePath: '/tmp/keystore-0xC8d52A5245aF5F2B095223F0Cd7468A7E670F22A.json',
        rpcUrl: 'https://bsc-dataseed.binance.org',
        sender: '0xC8d52A5245aF5F2B095223F0Cd7468A7E670F22A',
        extraArgs: ['--sig', 'run()'],
    });

    assert.deepEqual(args, [
        'script',
        'script/Deploy.s.sol',
        '--rpc-url',
        'https://bsc-dataseed.binance.org',
        '--broadcast',
        '--sender',
        '0xC8d52A5245aF5F2B095223F0Cd7468A7E670F22A',
        '--keystore',
        '/tmp/keystore-0xC8d52A5245aF5F2B095223F0Cd7468A7E670F22A.json',
        '--sig',
        'run()',
    ]);
});

test('double-encoded keystore JSON is readable and normalized for forge', async () => {
    const tempDir = fs.mkdtempSync(path.join(os.tmpdir(), 'auth-keystore-'));
    const keystorePath = path.join(tempDir, 'wrapped-keystore.json');
    const cacheDir = path.join(tempDir, 'cache');
    const wallet = ethers.Wallet.createRandom();
    const keystore = {
        address: wallet.address.slice(2).toLowerCase(),
        version: 3,
        crypto: {
            cipher: 'aes-128-ctr',
            cipherparams: { iv: '00'.repeat(16) },
            ciphertext: '00'.repeat(32),
            kdf: 'scrypt',
            kdfparams: { salt: '11'.repeat(32), n: 2, dklen: 32, p: 1, r: 8 },
            mac: '22'.repeat(32),
        },
    };
    fs.writeFileSync(keystorePath, JSON.stringify(JSON.stringify(keystore)));

    const parsed = readKeystoreJsonObject(keystorePath);
    const identity = await resolveDeployerIdentity({
        env: { AUTH_DEPLOY_KEYSTORE_PATH: keystorePath },
    });
    const normalized = normalizeKeystorePathForForge(keystorePath, { cacheDir });

    assert.equal(parsed.wasJsonString, true);
    assert.equal(identity.address, wallet.address);
    assert.equal(normalized.normalized, true);
    assert.equal(normalized.keystorePath.startsWith(cacheDir), true);
    assert.deepEqual(JSON.parse(fs.readFileSync(normalized.keystorePath, 'utf8')), keystore);
    assert.equal((fs.statSync(normalized.keystorePath).mode & 0o777), 0o600);
});

test('deployActionNeedsSigner only unlocks for deploy actions', () => {
    assert.equal(deployActionNeedsSigner('deploy'), true);
    assert.equal(deployActionNeedsSigner('deploy-implementation'), true);
    assert.equal(deployActionNeedsSigner('upgrade-and-migrate'), true);
    assert.equal(deployActionNeedsSigner('set-executor'), true);
    assert.equal(deployActionNeedsSigner('setup-topic-expiry'), true);
    assert.equal(deployActionNeedsSigner('verify'), false);
    assert.equal(deployActionNeedsSigner('wallet-address'), false);
});

test('readConfiguredKeystorePath trims inline comments and prefers repo-specific env', () => {
    const env = {
        AUTH_DEPLOY_KEYSTORE_PATH: " '/tmp/auth-deployer.json' // shared wallet ",
        DEPLOY_KEYSTORE_PATH: '/tmp/fallback.json',
        OMNIX_DEPLOY_KEYSTORE_PATH: '/tmp/osw.json',
    };

    assert.equal(readConfiguredKeystorePath(env), '/tmp/auth-deployer.json');
});

test('auth deployer also accepts OMNIX keystore env for shared-wallet workflows', () => {
    const env = {
        OMNIX_DEPLOY_KEYSTORE_PATH: " '/tmp/osw-shared.json' # shared deployer ",
    };

    assert.equal(readConfiguredKeystorePath(env), '/tmp/osw-shared.json');
});

test('primeDeployerPrivateKey unlocks keystore once and injects private key into env', async () => {
    const wallet = ethers.Wallet.createRandom();
    const env = {
        AUTH_DEPLOY_KEYSTORE_PATH: '/tmp/deployer.json',
    };
    let unlockCalls = 0;

    const first = await primeDeployerPrivateKey({
        action: 'deploy',
        env,
        loadWalletFromKeystore: async () => {
            unlockCalls += 1;
            return wallet;
        },
        log: () => {},
    });

    const secondWallet = await unlockDeployerWalletOnce({
        env: {
            AUTH_DEPLOY_KEYSTORE_PATH: '/tmp/deployer.json',
            AUTH_DEPLOY_PRIVATE_KEY: env.AUTH_DEPLOY_PRIVATE_KEY,
        },
        loadWalletFromKeystore: async () => {
            unlockCalls += 1;
            return wallet;
        },
    });

    assert.equal(first.primed, true);
    assert.equal(env.AUTH_DEPLOY_PRIVATE_KEY, wallet.privateKey);
    assert.equal(secondWallet.address, wallet.address);
    assert.equal(unlockCalls, 1);
});

test('keystore path remains higher priority than direct private key when both are present', async () => {
    const keystoreWallet = ethers.Wallet.createRandom();
    const directWallet = ethers.Wallet.createRandom();

    const unlocked = await unlockDeployerWalletOnce({
        env: {
            AUTH_DEPLOY_KEYSTORE_PATH: '/tmp/deployer.json',
            AUTH_DEPLOY_PRIVATE_KEY: directWallet.privateKey,
        },
        loadWalletFromKeystore: async () => keystoreWallet,
    });

    assert.equal(unlocked.address, keystoreWallet.address);
});

test('single unlock decrypts keystore once and primes private key env', async () => {
    const tempDir = fs.mkdtempSync(path.join(os.tmpdir(), 'auth-keystore-'));
    const wallet = ethers.Wallet.createRandom();
    const keystorePath = path.join(tempDir, 'keystore.json');
    fs.writeFileSync(keystorePath, JSON.stringify(await wallet.encrypt('pw')));
    const env = {
        AUTH_SINGLE_UNLOCK: 'true',
        AUTH_DEPLOY_KEYSTORE_PATH: keystorePath,
    };
    let passwordReads = 0;

    const result = await maybePrimeSingleUnlock({
        action: 'deploy',
        env,
        readPassword: () => {
            passwordReads += 1;
            return 'pw';
        },
        log: () => {},
    });

    assert.equal(readSingleUnlockEnabled(env), true);
    assert.equal(result.primed, true);
    assert.equal(result.address, wallet.address);
    assert.equal(env.AUTH_DEPLOY_PRIVATE_KEY, wallet.privateKey);
    assert.equal(passwordReads, 1);
});

test('single unlock stays disabled unless explicitly enabled', async () => {
    const wallet = ethers.Wallet.createRandom();
    const env = {
        AUTH_DEPLOY_KEYSTORE_PATH: '/tmp/deployer.json',
    };
    const result = await maybePrimeSingleUnlock({
        action: 'deploy',
        env,
        readPassword: () => {
            throw new Error('password should not be read');
        },
        log: () => {},
    });

    assert.equal(readSingleUnlockEnabled(env), false);
    assert.equal(result.primed, false);
    assert.equal(result.reason, 'single-unlock-disabled');
    assert.equal(env.AUTH_DEPLOY_PRIVATE_KEY, undefined);
    assert.ok(wallet.address);
});
