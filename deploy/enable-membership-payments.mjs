#!/usr/bin/env node
import { execFileSync } from "node:child_process";
import path from "node:path";
import { fileURLToPath } from "node:url";

import { loadEnv, readClean, readDeploymentState, resolveBscNetwork } from "./shared.mjs";
import {
    loadWalletFromKeystore,
    resolveDeployerIdentity,
    unlockDeployerWalletOnce,
} from "./deployer-unlock.mjs";

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);
const PROJECT_ROOT = path.resolve(__dirname, "..");

const PAYMENTS = Object.freeze([
    {
        name: "ETH/WETH",
        token: "0x2170Ed0880ac9A755fd29B2688956BD959F933F8",
        oracle: "0x9ef1B8c0E4F7dc8bF5719Ea496883DC6401d5b2e",
        expectedSymbol: "ETH",
        expectedOracleDescription: "ETH / USD",
    },
    {
        name: "USDT",
        token: "0x55d398326f99059fF775485246999027B3197955",
        oracle: "0xB97Ad0E74fa7d920791E90258A6E2085088b4320",
        expectedSymbol: "USDT",
        expectedOracleDescription: "USDT / USD",
    },
    {
        name: "USDC",
        token: "0x8AC76a51cc950d9822D68b83fE1Ad97B32Cd580d",
        oracle: "0x51597f405303C4377E36123cBc172b13269EA163",
        expectedSymbol: "USDC",
        expectedOracleDescription: "USDC / USD",
    },
    {
        name: "WBNB",
        token: "0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c",
        oracle: "0x0567F2323251f0Aab15c8dFb1967E4e8A7D42aeE",
        expectedSymbol: "WBNB",
        expectedOracleDescription: "BNB / USD",
    },
    {
        name: "BTCB",
        token: "0x7130d2A12B9BCbFAe4f2634d864A1Ee1Ce3Ead9c",
        oracle: "0x264990fbd0A4796A3E3d8E37C4d5F87a3aCa5Ebf",
        expectedSymbol: "BTCB",
        expectedOracleDescription: "BTC / USD",
    },
]);

function parseArgs(argv) {
    return {
        dryRun: argv.includes("--dry-run"),
        help: argv.includes("--help") || argv.includes("-h"),
    };
}

function printHelp() {
    console.log(`
Enable membership payment tokens on BSC.

Usage:
  node deploy/enable-membership-payments.mjs [--dry-run]

Required .env:
  BSC_RPC_URL
  AUTH_DEPLOY_KEYSTORE_PATH / DEPLOY_KEYSTORE_PATH / OMNIX_DEPLOY_KEYSTORE_PATH
  AUTH_DEPLOY_PRIVATE_KEY / DEPLOY_PRIVATE_KEY / OMNIX_DEPLOY_PRIVATE_KEY
  PROXY_ADDRESS       Optional; defaults to deployments/<network>.json

Actions:
  setPaymentToken(WETH, true, ETH/USD)
  setPaymentToken(USDT, true, USDT/USD)
  setPaymentToken(USDC, true, USDC/USD)
  setPaymentToken(WBNB, true, BNB/USD)
  setPaymentToken(BTCB, true, BTC/USD)
`);
}

function cast(args, { input = "ignore" } = {}) {
    return execFileSync("cast", args, {
        cwd: PROJECT_ROOT,
        encoding: "utf8",
        stdio: [input, "pipe", "pipe"],
        timeout: 120_000,
    }).trim();
}

function call(rpcUrl, target, signature, args = []) {
    return cast(["call", target, signature, ...args.map(String), "--rpc-url", rpcUrl])
        .split(/\r?\n/)
        .map(line => line.trim())
        .filter(Boolean);
}

function sameAddress(left, right) {
    return String(left).toLowerCase() === String(right).toLowerCase();
}

function stripQuotes(value) {
    return String(value || "").replace(/^"|"$/g, "");
}

function parseCastInteger(value) {
    return BigInt(String(value).trim().split(/\s+/)[0]);
}

function assertAddress(value, label) {
    if (!/^0x[a-fA-F0-9]{40}$/.test(String(value || ""))) {
        throw new Error(`Invalid ${label}: ${value}`);
    }
}

function assertHasCode(rpcUrl, address, label) {
    const code = cast(["code", address, "--rpc-url", rpcUrl]);
    if (!code || code === "0x") {
        throw new Error(`${label} has no code: ${address}`);
    }
}

function assertOracleHealthy(rpcUrl, oracle, expectedDescription) {
    const description = stripQuotes(call(rpcUrl, oracle, "description()(string)")[0]);
    const decimals = call(rpcUrl, oracle, "decimals()(uint8)")[0];
    const latest = call(rpcUrl, oracle, "latestRoundData()(uint80,int256,uint256,uint256,uint80)");
    const price = parseCastInteger(latest[1]);
    const updatedAt = parseCastInteger(latest[3]);

    if (description !== expectedDescription) {
        throw new Error(`Unexpected oracle description for ${oracle}: ${description}`);
    }
    if (price <= 0n) {
        throw new Error(`Oracle price is not positive for ${oracle}: ${price}`);
    }
    if (updatedAt === 0n) {
        throw new Error(`Oracle updatedAt is zero for ${oracle}`);
    }

    return { description, decimals, price: price.toString(), updatedAt: updatedAt.toString() };
}

function readCurrentPaymentConfig(rpcUrl, proxy, token) {
    const lines = call(rpcUrl, proxy, "getPaymentTokenConfig(address)(bool,uint8,address,uint8)", [token]);
    return {
        enabled: lines[0] === "true",
        tokenDecimals: lines[1],
        usdOracle: lines[2],
        oracleDecimals: lines[3],
    };
}

function sendPaymentTokenTx({ rpcUrl, proxy, privateKey, token, oracle }) {
    return cast([
        "send",
        proxy,
        "setPaymentToken(address,bool,address)",
        token,
        "true",
        oracle,
        "--rpc-url",
        rpcUrl,
        "--private-key",
        privateKey,
        "--confirmations",
        "1",
    ]);
}

async function main() {
    const args = parseArgs(process.argv.slice(2));
    if (args.help) {
        printHelp();
        return;
    }

    await loadEnv();

    const network = resolveBscNetwork();
    if (network.chainId !== 56) {
        throw new Error(`Expected BSC mainnet chainId=56, got ${network.chainId}`);
    }

    const state = readDeploymentState(network);
    const rpcUrl = network.rpcUrl;
    const proxy = readClean(process.env.PROXY_ADDRESS) || state.proxy;

    assertAddress(proxy, "PROXY_ADDRESS/deployment proxy");
    const identity = await resolveDeployerIdentity({ env: process.env });
    if (!identity) {
        throw new Error("Missing signer. Configure a deploy keystore or private key before enabling payment tokens.");
    }

    const signer = identity.address;
    const owner = call(rpcUrl, proxy, "owner()(address)")[0];
    if (!sameAddress(signer, owner)) {
        throw new Error(`Signer ${signer} is not contract owner ${owner}`);
    }

    console.log(`[enable] network=${network.label} chainId=${network.chainId}`);
    console.log(`[enable] proxy=${proxy}`);
    console.log(`[enable] owner=${owner}`);
    console.log(`[enable] mode=${args.dryRun ? "dry-run" : "broadcast"}`);

    let sent = 0;
    let skipped = 0;

    for (const payment of PAYMENTS) {
        assertHasCode(rpcUrl, payment.token, `${payment.name} token`);
        assertHasCode(rpcUrl, payment.oracle, `${payment.name} oracle`);

        const symbol = stripQuotes(call(rpcUrl, payment.token, "symbol()(string)")[0]);
        const tokenDecimals = call(rpcUrl, payment.token, "decimals()(uint8)")[0];
        if (symbol !== payment.expectedSymbol) {
            throw new Error(`Unexpected token symbol for ${payment.token}: ${symbol}`);
        }

        const oracle = assertOracleHealthy(rpcUrl, payment.oracle, payment.expectedOracleDescription);
        const current = readCurrentPaymentConfig(rpcUrl, proxy, payment.token);

        console.log(
            `[enable] ${payment.name}: token=${payment.token} decimals=${tokenDecimals} oracle=${payment.oracle} feed="${oracle.description}" enabled=${current.enabled} currentOracle=${current.usdOracle}`,
        );

        if (current.enabled && sameAddress(current.usdOracle, payment.oracle)) {
            console.log(`[enable] ${payment.name}: already enabled, skip`);
            skipped += 1;
            continue;
        }

        if (args.dryRun) {
            console.log(
                `[dry-run] cast send ${proxy} "setPaymentToken(address,bool,address)" ${payment.token} true ${payment.oracle}`,
            );
            continue;
        }

        const wallet = await unlockDeployerWalletOnce({
            env: process.env,
            loadWalletFromKeystore,
        });
        if (!wallet?.privateKey || !sameAddress(wallet.address, signer)) {
            throw new Error(`Signer unlock failed for ${signer}`);
        }

        const output = sendPaymentTokenTx({
            rpcUrl,
            proxy,
            privateKey: wallet.privateKey,
            token: payment.token,
            oracle: payment.oracle,
        });
        console.log(output);
        sent += 1;

        const after = readCurrentPaymentConfig(rpcUrl, proxy, payment.token);
        if (!after.enabled || !sameAddress(after.usdOracle, payment.oracle)) {
            throw new Error(`${payment.name} verification failed after transaction`);
        }
    }

    console.log(`[enable] done sent=${sent} skipped=${skipped}`);
}

main().catch(error => {
    console.error(`[enable] FATAL: ${error.message}`);
    process.exit(1);
});
