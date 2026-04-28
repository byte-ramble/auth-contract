import test from 'node:test';
import assert from 'node:assert/strict';
import { ethers } from 'ethers';
import { buildForgeScriptArgs } from './shared.mjs';
import {
    primeDeployerPrivateKey as primeOmnixDeployerPrivateKey,
    resetDeployerUnlockCache as resetOmnixDeployerUnlockCache,
} from '../../osw-contract/scripts/omnix/shared/deployer-unlock.mjs';
import {
    deployActionNeedsSigner,
    primeDeployerPrivateKey,
    readConfiguredKeystorePath,
    resetDeployerUnlockCache,
    unlockDeployerWalletOnce,
} from './deployer-unlock.mjs';

test.afterEach(() => {
    resetDeployerUnlockCache();
    resetOmnixDeployerUnlockCache();
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
        keystorePath: '/Users/maning/.keystore/keystore-0xC8d52A5245aF5F2B095223F0Cd7468A7E670F22A.json',
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
        '/Users/maning/.keystore/keystore-0xC8d52A5245aF5F2B095223F0Cd7468A7E670F22A.json',
        '--sig',
        'run()',
    ]);
});

test('deployActionNeedsSigner only unlocks for deploy actions', () => {
    assert.equal(deployActionNeedsSigner('deploy'), true);
    assert.equal(deployActionNeedsSigner('upgrade-and-migrate'), true);
    assert.equal(deployActionNeedsSigner('set-executor'), true);
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

test('auth and osw deployers resolve the same address from the same keystore', async () => {
    const sharedWallet = ethers.Wallet.createRandom();
    const authEnv = {
        OMNIX_DEPLOY_KEYSTORE_PATH: '/tmp/shared-keystore.json',
    };
    const oswEnv = {
        OMNIX_DEPLOY_KEYSTORE_PATH: '/tmp/shared-keystore.json',
    };

    const authPrimed = await primeDeployerPrivateKey({
        action: 'deploy',
        env: authEnv,
        loadWalletFromKeystore: async () => sharedWallet,
        log: () => {},
    });
    const oswPrimed = await primeOmnixDeployerPrivateKey({
        action: 'all',
        env: oswEnv,
        loadWalletFromKeystore: async () => sharedWallet,
        log: () => {},
    });

    assert.equal(authPrimed.address, sharedWallet.address);
    assert.equal(oswPrimed.address, sharedWallet.address);
    assert.equal(authPrimed.address, oswPrimed.address);
});
