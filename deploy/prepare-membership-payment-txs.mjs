#!/usr/bin/env node
import fs from "node:fs";
import path from "node:path";
import { execFileSync } from "node:child_process";
import { fileURLToPath } from "node:url";

import { loadEnv, readClean, readDeploymentState, resolveBscNetwork } from "./shared.mjs";

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);
const PROJECT_ROOT = path.resolve(__dirname, "..");

const ZERO_ADDRESS = "0x0000000000000000000000000000000000000000";
const ZERO_BYTES32 = `0x${"00".repeat(32)}`;
const BSC_MAINNET_CHAIN_ID = 56;

const BSC_MAINNET = Object.freeze({
    bnbUsdOracle: "0x0567F2323251f0Aab15c8dFb1967E4e8A7D42aeE",
    maxOracleDelay: "3600",
    ramble: "0x1A8C391f6c603894108fcE14A52E9Bf804c67777",
    rambleWbnbPair: "0x185e706a55d04815e7e10b506A5a4d8d1153aeAD",
    tokens: [
        {
            id: "ETH",
            symbol: "WETH",
            label: "ETH payments via BSC WETH",
            token: "0x2170Ed0880ac9A755fd29B2688956BD959F933F8",
            oracle: "0x9ef1B8c0E4F7dc8bF5719Ea496883DC6401d5b2e",
            oracleLabel: "ETH/USD",
        },
        {
            id: "USDT",
            symbol: "USDT",
            label: "USDT",
            token: "0x55d398326f99059fF775485246999027B3197955",
            oracle: "0xB97Ad0E74fa7d920791E90258A6E2085088b4320",
            oracleLabel: "USDT/USD",
        },
        {
            id: "USDC",
            symbol: "USDC",
            label: "USDC",
            token: "0x8AC76a51cc950d9822D68b83fE1Ad97B32Cd580d",
            oracle: "0x51597f405303C4377E36123cBc172b13269EA163",
            oracleLabel: "USDC/USD",
        },
        {
            id: "WBNB",
            symbol: "WBNB",
            label: "WBNB",
            token: "0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c",
            oracle: "0x0567F2323251f0Aab15c8dFb1967E4e8A7D42aeE",
            oracleLabel: "BNB/USD",
        },
        {
            id: "BTCB",
            symbol: "BTCB",
            label: "BTCB",
            token: "0x7130d2A12B9BCbFAe4f2634d864A1Ee1Ce3Ead9c",
            oracle: "0x264990fbd0A4796A3E3d8E37C4d5F87a3aCa5Ebf",
            oracleLabel: "BTC/USD",
        },
    ],
});

const METHODS = Object.freeze({
    upgradeToAndCall: {
        name: "upgradeToAndCall",
        inputs: [
            { internalType: "address", name: "newImplementation", type: "address" },
            { internalType: "bytes", name: "data", type: "bytes" },
        ],
        payable: false,
    },
    setOracleConfig: {
        name: "setOracleConfig",
        inputs: [
            { internalType: "address", name: "bnbUsdOracle_", type: "address" },
            { internalType: "uint256", name: "maxOracleDelay_", type: "uint256" },
        ],
        payable: false,
    },
    setPaymentToken: {
        name: "setPaymentToken",
        inputs: [
            { internalType: "address", name: "token", type: "address" },
            { internalType: "bool", name: "enabled", type: "bool" },
            { internalType: "address", name: "usdOracle", type: "address" },
        ],
        payable: false,
    },
    setRamblePair: {
        name: "setRamblePair",
        inputs: [{ internalType: "address", name: "rambleWbnbPair_", type: "address" }],
        payable: false,
    },
    setTopicPaymentToken: {
        name: "setTopicPaymentToken",
        inputs: [
            { internalType: "bytes32", name: "topicId", type: "bytes32" },
            { internalType: "address", name: "payToken", type: "address" },
            { internalType: "bool", name: "allowed", type: "bool" },
        ],
        payable: false,
    },
});

function parseArgs(argv) {
    const args = {
        output: undefined,
        stdout: false,
        noWrite: false,
        help: false,
    };

    for (let i = 0; i < argv.length; ++i) {
        const cur = argv[i];
        const next = argv[i + 1];
        if (cur === "--output" && next) {
            args.output = next;
            i += 1;
            continue;
        }
        if (cur === "--stdout") {
            args.stdout = true;
            continue;
        }
        if (cur === "--no-write") {
            args.noWrite = true;
            continue;
        }
        if (cur === "--help" || cur === "-h") {
            args.help = true;
        }
    }

    return args;
}

function printHelp() {
    console.log(`
Prepare owner transactions for membership payments.

Usage:
  node deploy/prepare-membership-payment-txs.mjs [--output <file>] [--stdout] [--no-write]

Environment:
  BSC_RPC_URL              RPC used for read-only state checks
  PROXY_ADDRESS            Optional override; defaults to deployments/<network>.json
  OWNER                    Optional expected owner check
  BNB_USD_ORACLE           Optional desired BNB/USD oracle; defaults to BSC mainnet Chainlink
  MAX_ORACLE_DELAY         Optional desired oracle max delay; defaults to 3600
  NEW_IMPLEMENTATION       Optional implementation address to include upgradeToAndCall
  RAMBLE_WBNB_PAIR         Optional RAMBLE/WBNB pair override; defaults to BSC mainnet pair
  MEMBERSHIP_TX_OUTPUT     Optional output file path

Notes:
  ETH means the BSC WETH ERC20 payment token. Native BNB already works through address(0).
  RAMBLE is not registered with setPaymentToken; it uses the contract RAMBLE constant plus RAMBLE/WBNB pair.
`);
}

function sameAddress(left, right) {
    return Boolean(left && right && left.toLowerCase() === right.toLowerCase());
}

function isAddress(value) {
    return /^0x[a-fA-F0-9]{40}$/.test(String(value || ""));
}

function requireAddress(value, label) {
    if (!isAddress(value)) {
        throw new Error(`Invalid ${label}: ${value}`);
    }
    return value;
}

function callContract(rpcUrl, target, signature, args = []) {
    try {
        const stdout = execFileSync("cast", ["call", target, signature, ...args.map(String), "--rpc-url", rpcUrl], {
            cwd: PROJECT_ROOT,
            encoding: "utf8",
            stdio: ["ignore", "pipe", "pipe"],
            timeout: 20_000,
        }).trim();

        return { ok: true, stdout, lines: stdout.split(/\r?\n/).map(line => line.trim()).filter(Boolean) };
    } catch (err) {
        const stderr = String(err.stderr || err.message || "").trim();
        return {
            ok: false,
            stdout: String(err.stdout || "").trim(),
            stderr,
            emptyRevert: /data:\s*"0x"/.test(stderr),
        };
    }
}

function encodeCalldata(signature, args = []) {
    return execFileSync("cast", ["calldata", signature, ...args.map(String)], {
        cwd: PROJECT_ROOT,
        encoding: "utf8",
        stdio: ["ignore", "pipe", "pipe"],
        timeout: 15_000,
    }).trim();
}

function boolFromLine(line) {
    return String(line).trim().toLowerCase() === "true";
}

function addTransaction(transactions, { to, name, description, signature, args, method, inputValues }) {
    transactions.push({
        name,
        description,
        to,
        value: "0",
        data: encodeCalldata(signature, args),
        signature,
        args: args.map(String),
        contractMethod: method,
        contractInputsValues: inputValues,
    });
}

function buildSafeTransactionBuilder({ chainId, owner, transactions }) {
    return {
        version: "1.0",
        chainId: String(chainId),
        createdAt: Date.now(),
        meta: {
            name: "Opland membership payment setup",
            description: "Owner transactions for WETH, USDT, USDC, WBNB, BTCB, RAMBLE payment enablement",
            txBuilderVersion: "1.18.0",
            createdFromSafeAddress: owner || "",
            createdFromOwnerAddress: "",
            checksum: "",
        },
        transactions: transactions.map(tx => ({
            to: tx.to,
            value: tx.value,
            data: tx.data,
            contractMethod: tx.contractMethod,
            contractInputsValues: tx.contractInputsValues,
        })),
    };
}

function readPaymentTokenConfig(rpcUrl, proxy, token) {
    const result = callContract(rpcUrl, proxy, "getPaymentTokenConfig(address)(bool,uint8,address,uint8)", [token]);
    if (!result.ok || result.lines.length < 4) {
        return { supported: false, error: result.stderr || result.stdout || "call failed" };
    }

    return {
        supported: true,
        enabled: boolFromLine(result.lines[0]),
        tokenDecimals: Number(result.lines[1]),
        usdOracle: result.lines[2],
        oracleDecimals: Number(result.lines[3]),
    };
}

function readOracleConfig(rpcUrl, proxy) {
    const result = callContract(rpcUrl, proxy, "getOracleConfig()(address,uint256)");
    if (!result.ok || result.lines.length < 2) {
        return { supported: false, error: result.stderr || result.stdout || "call failed" };
    }

    return {
        supported: true,
        bnbUsdOracle: result.lines[0],
        maxOracleDelay: result.lines[1],
    };
}

function readTopicIds(rpcUrl, proxy, warnings) {
    const countResult = callContract(rpcUrl, proxy, "getTopicCount()(uint256)");
    if (!countResult.ok || countResult.lines.length < 1) {
        warnings.push("Could not read getTopicCount(); topic allowlist checks were skipped.");
        return [];
    }

    const count = Number(countResult.lines[0]);
    if (!Number.isSafeInteger(count) || count < 0) {
        warnings.push(`Invalid getTopicCount() result: ${countResult.lines[0]}`);
        return [];
    }

    const topicIds = [];
    for (let i = 0; i < count; ++i) {
        const topicResult = callContract(rpcUrl, proxy, "getTopicAt(uint256)(bytes32,uint256,string,bool)", [String(i)]);
        if (!topicResult.ok || topicResult.lines.length < 1) {
            warnings.push(`Could not read getTopicAt(${i}); topic allowlist checks may be incomplete.`);
            continue;
        }
        topicIds.push(topicResult.lines[0]);
    }

    return topicIds;
}

function detectAnnualSupport(rpcUrl, proxy, topicIds) {
    const topicId = topicIds[0] || ZERO_BYTES32;
    const result = callContract(rpcUrl, proxy, "getTopicAnnualPriceWad(bytes32)(uint256)", [topicId]);
    if (result.ok) {
        return { supported: true, probe: "getTopicAnnualPriceWad" };
    }

    return {
        supported: !result.emptyRevert,
        probe: "getTopicAnnualPriceWad",
        error: result.stderr || result.stdout || "call failed",
    };
}

function prepareTopicAllowlistTransactions({ rpcUrl, proxy, topicIds, paymentTokens, rambleToken, transactions, skipped, warnings }) {
    for (const topicId of topicIds) {
        const enabledResult = callContract(rpcUrl, proxy, "getTopicPaymentAllowlistEnabled(bytes32)(bool)", [topicId]);
        if (!enabledResult.ok || enabledResult.lines.length < 1) {
            warnings.push(`Could not read payment allowlist status for topic ${topicId}; skipped topic payment txs.`);
            continue;
        }
        if (!boolFromLine(enabledResult.lines[0])) {
            skipped.push({
                name: "topicPaymentAllowlist",
                topicId,
                reason: "Topic payment allowlist is disabled; globally enabled payment tokens are allowed.",
            });
            continue;
        }

        const topicPayTokens = [...paymentTokens.map(token => ({ id: token.id, token: token.token })), {
            id: "RAMBLE",
            token: rambleToken,
        }];

        for (const item of topicPayTokens) {
            const allowedResult = callContract(rpcUrl, proxy, "isTopicPaymentTokenAllowed(bytes32,address)(bool)", [
                topicId,
                item.token,
            ]);
            if (allowedResult.ok && boolFromLine(allowedResult.lines[0])) {
                skipped.push({
                    name: "setTopicPaymentToken",
                    topicId,
                    token: item.token,
                    symbol: item.id,
                    reason: "Already allowed for topic.",
                });
                continue;
            }

            addTransaction(transactions, {
                to: proxy,
                name: `Allow ${item.id} for topic ${topicId}`,
                description: `Enable ${item.id} in topic-level payment allowlist.`,
                signature: "setTopicPaymentToken(bytes32,address,bool)",
                args: [topicId, item.token, "true"],
                method: METHODS.setTopicPaymentToken,
                inputValues: { topicId, payToken: item.token, allowed: "true" },
            });
        }
    }
}

async function main() {
    const args = parseArgs(process.argv.slice(2));
    if (args.help) {
        printHelp();
        return;
    }

    await loadEnv();

    const network = resolveBscNetwork();
    const state = readDeploymentState(network);
    const proxy = requireAddress(readClean(process.env.PROXY_ADDRESS) || state.proxy, "PROXY_ADDRESS/deployment proxy");
    const configuredOwner = readClean(process.env.OWNER) || state.owner || "";
    const desiredBnbUsdOracle = requireAddress(
        readClean(process.env.BNB_USD_ORACLE) || state.bnbUsdOracle || BSC_MAINNET.bnbUsdOracle,
        "BNB_USD_ORACLE",
    );
    const desiredMaxOracleDelay = readClean(process.env.MAX_ORACLE_DELAY) || state.maxOracleDelay || BSC_MAINNET.maxOracleDelay;
    const desiredRamblePair = requireAddress(
        readClean(process.env.RAMBLE_WBNB_PAIR) || BSC_MAINNET.rambleWbnbPair,
        "RAMBLE_WBNB_PAIR",
    );
    const newImplementation = readClean(process.env.NEW_IMPLEMENTATION);
    if (newImplementation) {
        requireAddress(newImplementation, "NEW_IMPLEMENTATION");
    }

    const transactions = [];
    const skipped = [];
    const warnings = [];
    const requiredActions = [];
    const current = {};

    const ownerResult = callContract(network.rpcUrl, proxy, "owner()(address)");
    current.owner = ownerResult.ok ? ownerResult.lines[0] : null;
    if (configuredOwner && current.owner && !sameAddress(configuredOwner, current.owner)) {
        warnings.push(`Configured OWNER ${configuredOwner} differs from on-chain owner ${current.owner}.`);
    }

    const topicIds = readTopicIds(network.rpcUrl, proxy, warnings);
    const annualSupport = detectAnnualSupport(network.rpcUrl, proxy, topicIds);
    current.annualMethodsSupported = annualSupport.supported;

    if (!annualSupport.supported) {
        requiredActions.push(
            "Deploy the current TopicAccessManagerUpgradeable implementation, then rerun this script with NEW_IMPLEMENTATION=<deployed implementation>.",
        );
        if (newImplementation) {
            addTransaction(transactions, {
                to: proxy,
                name: "Upgrade membership implementation",
                description: "Upgrade proxy to implementation that supports annual quote/topup methods.",
                signature: "upgradeToAndCall(address,bytes)",
                args: [newImplementation, "0x"],
                method: METHODS.upgradeToAndCall,
                inputValues: { newImplementation, data: "0x" },
            });
        } else {
            warnings.push(
                "Current proxy does not expose annual quote/topup methods. Upgrade tx was not included because NEW_IMPLEMENTATION is not set.",
            );
        }
    }

    const oracleConfig = readOracleConfig(network.rpcUrl, proxy);
    current.oracleConfig = oracleConfig;
    if (
        !oracleConfig.supported
        || !sameAddress(oracleConfig.bnbUsdOracle, desiredBnbUsdOracle)
        || String(oracleConfig.maxOracleDelay) !== String(desiredMaxOracleDelay)
    ) {
        addTransaction(transactions, {
            to: proxy,
            name: "Configure BNB/USD oracle",
            description: "Set global BNB/USD oracle used by BNB and RAMBLE payment valuation.",
            signature: "setOracleConfig(address,uint256)",
            args: [desiredBnbUsdOracle, desiredMaxOracleDelay],
            method: METHODS.setOracleConfig,
            inputValues: { bnbUsdOracle_: desiredBnbUsdOracle, maxOracleDelay_: String(desiredMaxOracleDelay) },
        });
    } else {
        skipped.push({
            name: "setOracleConfig",
            reason: "BNB/USD oracle and max delay already match desired config.",
        });
    }

    current.paymentTokens = {};
    for (const token of BSC_MAINNET.tokens) {
        const config = readPaymentTokenConfig(network.rpcUrl, proxy, token.token);
        current.paymentTokens[token.id] = { ...token, current: config };
        if (config.supported && config.enabled && sameAddress(config.usdOracle, token.oracle)) {
            skipped.push({
                name: "setPaymentToken",
                symbol: token.id,
                token: token.token,
                reason: "Already enabled with desired USD oracle.",
            });
            continue;
        }

        addTransaction(transactions, {
            to: proxy,
            name: `Enable ${token.id} payment`,
            description: `Enable ${token.label} with ${token.oracleLabel} oracle.`,
            signature: "setPaymentToken(address,bool,address)",
            args: [token.token, "true", token.oracle],
            method: METHODS.setPaymentToken,
            inputValues: { token: token.token, enabled: "true", usdOracle: token.oracle },
        });
    }

    const ramblePairResult = callContract(network.rpcUrl, proxy, "getRamblePair()(address)");
    const rambleDiscountResult = callContract(network.rpcUrl, proxy, "getRambleDiscountBps()(uint16)");
    current.ramble = {
        token: BSC_MAINNET.ramble,
        desiredPair: desiredRamblePair,
        currentPair: ramblePairResult.ok ? ramblePairResult.lines[0] : null,
        discountBps: rambleDiscountResult.ok ? rambleDiscountResult.lines[0] : null,
    };

    if (network.chainId !== BSC_MAINNET_CHAIN_ID) {
        warnings.push("RAMBLE payments are only supported on BSC mainnet chainId=56; no RAMBLE pair tx was prepared.");
    } else if (!ramblePairResult.ok || !sameAddress(ramblePairResult.lines[0], desiredRamblePair)) {
        addTransaction(transactions, {
            to: proxy,
            name: "Configure RAMBLE/WBNB pair",
            description: "Set RAMBLE/WBNB Pancake V2 pair used for RAMBLE payment valuation and swap settlement.",
            signature: "setRamblePair(address)",
            args: [desiredRamblePair],
            method: METHODS.setRamblePair,
            inputValues: { rambleWbnbPair_: desiredRamblePair },
        });
    } else {
        skipped.push({
            name: "setRamblePair",
            reason: "RAMBLE/WBNB pair already matches desired config.",
        });
    }

    prepareTopicAllowlistTransactions({
        rpcUrl: network.rpcUrl,
        proxy,
        topicIds,
        paymentTokens: BSC_MAINNET.tokens,
        rambleToken: BSC_MAINNET.ramble,
        transactions,
        skipped,
        warnings,
    });

    const ownerForBuilder = current.owner || configuredOwner || "";
    const plan = {
        version: "1.0",
        generatedAt: new Date().toISOString(),
        network: {
            label: network.label,
            chainId: network.chainId,
        },
        proxy,
        owner: {
            onchain: current.owner,
            configured: configuredOwner || null,
        },
        implementation: {
            activeFromDeploymentState: state.implementation || null,
            annualMethodsSupported: annualSupport.supported,
            newImplementation: newImplementation || null,
            upgradeTransactionIncluded: Boolean(newImplementation && !annualSupport.supported),
        },
        desired: {
            bnbUsdOracle: desiredBnbUsdOracle,
            maxOracleDelay: String(desiredMaxOracleDelay),
            paymentTokens: BSC_MAINNET.tokens,
            ramble: {
                token: BSC_MAINNET.ramble,
                pair: desiredRamblePair,
            },
        },
        current,
        transactions,
        skipped,
        warnings,
        requiredActions,
        safeTransactionBuilder: buildSafeTransactionBuilder({
            chainId: network.chainId,
            owner: ownerForBuilder,
            transactions,
        }),
    };

    const outputPath = path.resolve(
        PROJECT_ROOT,
        args.output || readClean(process.env.MEMBERSHIP_TX_OUTPUT) || `deployments/prepared/membership-payments-${network.label}.json`,
    );

    if (!args.noWrite) {
        fs.mkdirSync(path.dirname(outputPath), { recursive: true });
        fs.writeFileSync(outputPath, `${JSON.stringify(plan, null, 2)}\n`);
    }

    console.log(`[prepare] proxy: ${proxy}`);
    console.log(`[prepare] annual methods supported: ${annualSupport.supported ? "yes" : "no"}`);
    console.log(`[prepare] transactions prepared: ${transactions.length}`);
    if (!args.noWrite) {
        console.log(`[prepare] wrote: ${outputPath}`);
    }
    if (warnings.length > 0) {
        console.log(`[prepare] warnings: ${warnings.length}`);
        for (const warning of warnings) {
            console.log(`- ${warning}`);
        }
    }
    if (requiredActions.length > 0 && !newImplementation) {
        console.log("[prepare] required before full annual support:");
        for (const action of requiredActions) {
            console.log(`- ${action}`);
        }
    }
    if (args.stdout) {
        console.log(JSON.stringify(plan, null, 2));
    }
}

main().catch(err => {
    console.error(`[prepare] FATAL: ${err.message}`);
    process.exit(1);
});
