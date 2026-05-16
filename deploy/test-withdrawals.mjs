#!/usr/bin/env node
import { setTimeout as sleep } from "node:timers/promises";

import { Contract, Wallet, ethers } from "ethers";

import {
    loadEnv,
    readClean,
    readDeploymentState,
    resolveBscNetwork,
} from "./shared.mjs";
import {
    loadWalletFromKeystore,
    resolveDeployerIdentity,
    unlockDeployerWalletOnce,
} from "./deployer-unlock.mjs";

const DEFAULT_ERC20_TOKEN = "0x55d398326f99059fF775485246999027B3197955"; // BSC USDT
const ZERO_ADDRESS = "0x0000000000000000000000000000000000000000";
const KNOWN_ERC20_TOKENS = Object.freeze([
    { symbol: "WETH", token: "0x2170Ed0880ac9A755fd29B2688956BD959F933F8" },
    { symbol: "USDT", token: "0x55d398326f99059fF775485246999027B3197955" },
    { symbol: "USDC", token: "0x8AC76a51cc950d9822D68b83fE1Ad97B32Cd580d" },
    { symbol: "WBNB", token: "0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c" },
    { symbol: "BTCB", token: "0x7130d2A12B9BCbFAe4f2634d864A1Ee1Ce3Ead9c" },
    { symbol: "RAMBLE", token: "0x1A8C391f6c603894108fcE14A52E9Bf804c67777" },
    { symbol: "BUSD", token: "0xe9e7CEA3DedcA5984780Bafc599bD69ADd087D56" },
    { symbol: "FDUSD", token: "0xc5f0f7b66764F6ec8C8Dff7BA683102295E16409" },
    { symbol: "CAKE", token: "0x0E09FaBB73Bd3Ade0a17ECC321fD13a19e81cE82" },
    { symbol: "DAI", token: "0x1AF3F329e8BE154074D8769D1FFa4eE058B1DBc3" },
    { symbol: "TUSD", token: "0x14016E85a25aeb13065688cAFB43044C2ef86784" },
]);

const AUTH_ABI = [
    "function owner() view returns (address)",
    "function getExecutor() view returns (address)",
    "function withdrawNative(address recipient,uint256 amount)",
    "function withdrawERC20(address token,address recipient,uint256 amount)",
];

const ERC20_ABI = [
    "function balanceOf(address account) view returns (uint256)",
    "function decimals() view returns (uint8)",
    "function symbol() view returns (string)",
];

function parseArgs(argv) {
    const args = {
        dryRun: false,
        wait: false,
        sweepKnown: false,
        nativeOnly: false,
        erc20Only: false,
        help: false,
        erc20Tokens: [],
    };

    for (let index = 0; index < argv.length; index += 1) {
        const cur = argv[index];
        const next = () => {
            index += 1;
            if (index >= argv.length) throw new Error(`Missing value for ${cur}`);
            return argv[index];
        };

        if (cur === "--help" || cur === "-h") args.help = true;
        else if (cur === "--dry-run" || cur === "--check-only") args.dryRun = true;
        else if (cur === "--wait") args.wait = true;
        else if (cur === "--sweep-known" || cur === "--sweep" || cur === "--withdraw-all") args.sweepKnown = true;
        else if (cur === "--native-only") args.nativeOnly = true;
        else if (cur === "--erc20-only") args.erc20Only = true;
        else if (cur === "--proxy") args.proxy = next();
        else if (cur === "--recipient") args.recipient = next();
        else if (cur === "--native-amount") args.nativeAmount = next();
        else if (cur === "--erc20-token" || cur === "--token") args.erc20Tokens.push(...next().split(","));
        else if (cur === "--erc20-amount" || cur === "--token-amount") args.erc20Amount = next();
        else if (cur === "--wait-seconds") args.waitSeconds = next();
        else if (cur === "--poll-seconds") args.pollSeconds = next();
        else throw new Error(`Unknown argument: ${cur}`);
    }

    if (args.nativeOnly && args.erc20Only) {
        throw new Error("--native-only and --erc20-only cannot be used together");
    }

    return args;
}

function printHelp() {
    console.log(`
Test auth-contract owner/executor withdrawal path.

Usage:
  node deploy/test-withdrawals.mjs [--dry-run] [--wait]

Options:
  --dry-run              Print funding requirements and estimate calls; do not send txs
  --wait                 Wait for required deposits before sending withdrawals
  --sweep-known          Withdraw full native balance and all non-zero known ERC20s
  --proxy <address>      Auth proxy; defaults to PROXY_ADDRESS or deployments/<network>.json
  --recipient <address>  Withdrawal recipient; defaults to signer address
  --native-amount <bnb>  Native BNB amount to withdraw; defaults to 0.0001
  --erc20-token <addr>   ERC20 token to withdraw; repeat or comma-separate with --sweep-known
  --erc20-amount <amt>   ERC20 amount in token units; defaults to 0.1; use max for full balance
  --native-only          Only test withdrawNative
  --erc20-only           Only test withdrawERC20
  --wait-seconds <n>     Max wait time when --wait is used; defaults to 600
  --poll-seconds <n>     Poll interval when --wait is used; defaults to 10

Environment:
  BSC_RPC_URL
  PROXY_ADDRESS
  AUTH_DEPLOY_KEYSTORE_PATH / DEPLOY_KEYSTORE_PATH / OMNIX_DEPLOY_KEYSTORE_PATH
  AUTH_DEPLOY_PRIVATE_KEY / DEPLOY_PRIVATE_KEY / OMNIX_DEPLOY_PRIVATE_KEY
  WITHDRAW_TEST_RECIPIENT
  WITHDRAW_TEST_NATIVE_AMOUNT
  WITHDRAW_TEST_ERC20_TOKEN
  WITHDRAW_TEST_ERC20_AMOUNT
`);
}

function readFirstEnv(...keys) {
    for (const key of keys) {
        const value = readClean(process.env[key]);
        if (value) return value;
    }
    return undefined;
}

function normalizeAddress(value, label) {
    try {
        return ethers.utils.getAddress(value);
    } catch {
        throw new Error(`Invalid ${label}: ${value}`);
    }
}

function sameAddress(left, right) {
    return String(left || "").toLowerCase() === String(right || "").toLowerCase();
}

function resolveProxyAddress(args, network) {
    const state = readDeploymentState(network);
    const raw = args.proxy || readClean(process.env.PROXY_ADDRESS) || state.proxy;
    if (!raw) {
        throw new Error("Missing proxy address. Set PROXY_ADDRESS or pass --proxy.");
    }
    return normalizeAddress(raw, "proxy");
}

function parsePositiveSeconds(raw, fallback, label) {
    if (raw === undefined || raw === null || raw === "") return fallback;
    const value = Number(raw);
    if (!Number.isFinite(value) || value <= 0) {
        throw new Error(`Invalid ${label}: ${raw}`);
    }
    return value;
}

function formatNative(value) {
    return `${ethers.utils.formatEther(value)} BNB`;
}

function formatToken(value, decimals, symbol) {
    return `${ethers.utils.formatUnits(value, decimals)} ${symbol}`;
}

function isEnough(balance, required) {
    return balance.gte(required);
}

function uniqueAddresses(values) {
    const seen = new Set();
    const addresses = [];
    for (const value of values) {
        const clean = readClean(value);
        if (!clean) continue;
        const address = normalizeAddress(clean, "erc20 token");
        const key = address.toLowerCase();
        if (seen.has(key)) continue;
        seen.add(key);
        addresses.push(address);
    }
    return addresses;
}

async function readTokenInfo(provider, token) {
    const erc20 = new Contract(token, ERC20_ABI, provider);
    const [decimals, symbolRaw, balance] = await Promise.all([
        erc20.decimals(),
        erc20.symbol().catch(() => "ERC20"),
        Promise.resolve(null),
    ]);
    return {
        erc20,
        token,
        decimals,
        symbol: String(symbolRaw || "ERC20"),
        balance,
    };
}

async function buildSingleTokenPlan({ provider, proxy, token, amountText }) {
    const info = await readTokenInfo(provider, token);
    const balance = await info.erc20.balanceOf(proxy);
    const amount = String(amountText || "").trim().toLowerCase() === "max"
        ? balance
        : ethers.utils.parseUnits(amountText, info.decimals);
    return { ...info, balance, amount };
}

async function buildSweepTokenPlans({ provider, proxy, extraTokens }) {
    const tokenAddresses = uniqueAddresses([
        ...KNOWN_ERC20_TOKENS.map((item) => item.token),
        ...extraTokens,
    ]);
    const plans = [];
    const checked = [];
    for (const token of tokenAddresses) {
        const info = await readTokenInfo(provider, token);
        const balance = await info.erc20.balanceOf(proxy);
        checked.push({ ...info, balance });
        if (balance.gt(0)) {
            plans.push({ ...info, balance, amount: balance });
        }
    }
    return { plans, checked };
}

async function readBalances({ provider, erc20, proxy }) {
    const [nativeBalance, erc20Balance] = await Promise.all([
        provider.getBalance(proxy),
        erc20.balanceOf(proxy),
    ]);
    return { nativeBalance, erc20Balance };
}

function printFundingInstructions({ proxy, needNative, needErc20, nativeAmount, erc20Amount, erc20Decimals, erc20Symbol, erc20Token }) {
    console.log("[withdraw-test] fund this auth proxy address:");
    console.log(`[withdraw-test]   ${proxy}`);
    if (needNative) {
        console.log(`[withdraw-test] native: send at least ${formatNative(nativeAmount)} to the proxy`);
    }
    if (needErc20) {
        console.log(`[withdraw-test] erc20:  send at least ${formatToken(erc20Amount, erc20Decimals, erc20Symbol)} to the proxy`);
        console.log(`[withdraw-test] token:  ${erc20Symbol} ${erc20Token}`);
    }
}

function printBalanceStatus({ balances, needNative, needErc20, nativeAmount, erc20Amount, erc20Decimals, erc20Symbol }) {
    console.log(`[withdraw-test] proxy native balance: ${formatNative(balances.nativeBalance)}`);
    console.log(`[withdraw-test] proxy ${erc20Symbol} balance: ${formatToken(balances.erc20Balance, erc20Decimals, erc20Symbol)}`);
    if (needNative && !isEnough(balances.nativeBalance, nativeAmount)) {
        console.log(`[withdraw-test] missing native: ${formatNative(nativeAmount.sub(balances.nativeBalance))}`);
    }
    if (needErc20 && !isEnough(balances.erc20Balance, erc20Amount)) {
        console.log(`[withdraw-test] missing ${erc20Symbol}: ${formatToken(erc20Amount.sub(balances.erc20Balance), erc20Decimals, erc20Symbol)}`);
    }
}

function hasRequiredBalances({ balances, needNative, needErc20, nativeAmount, erc20Amount }) {
    return (!needNative || isEnough(balances.nativeBalance, nativeAmount))
        && (!needErc20 || isEnough(balances.erc20Balance, erc20Amount));
}

async function waitForRequiredBalances({ provider, erc20, proxy, needNative, needErc20, nativeAmount, erc20Amount, erc20Decimals, erc20Symbol, waitSeconds, pollSeconds }) {
    const deadline = Date.now() + waitSeconds * 1000;
    while (Date.now() <= deadline) {
        const balances = await readBalances({ provider, erc20, proxy });
        printBalanceStatus({ balances, needNative, needErc20, nativeAmount, erc20Amount, erc20Decimals, erc20Symbol });
        if (hasRequiredBalances({ balances, needNative, needErc20, nativeAmount, erc20Amount })) {
            return balances;
        }
        console.log(`[withdraw-test] waiting ${pollSeconds}s for deposits...`);
        await sleep(pollSeconds * 1000);
    }
    throw new Error(`Timed out waiting for required deposits after ${waitSeconds}s`);
}

async function estimateWithdrawalGas({ provider, iface, from, proxy, recipient, erc20Token, needNative, needErc20, nativeAmount, erc20Amount }) {
    if (needNative) {
        const data = iface.encodeFunctionData("withdrawNative", [recipient, nativeAmount]);
        const gas = await provider.estimateGas({ from, to: proxy, data });
        console.log(`[withdraw-test] estimated gas withdrawNative: ${gas.toString()}`);
    }
    if (needErc20) {
        const data = iface.encodeFunctionData("withdrawERC20", [erc20Token, recipient, erc20Amount]);
        const gas = await provider.estimateGas({ from, to: proxy, data });
        console.log(`[withdraw-test] estimated gas withdrawERC20: ${gas.toString()}`);
    }
}

async function estimateWithdrawalPlanGas({ provider, iface, from, proxy, recipient, nativeAmount, tokenPlans }) {
    if (nativeAmount.gt(0)) {
        const data = iface.encodeFunctionData("withdrawNative", [recipient, nativeAmount]);
        const gas = await provider.estimateGas({ from, to: proxy, data });
        console.log(`[withdraw-test] estimated gas withdrawNative ${formatNative(nativeAmount)}: ${gas.toString()}`);
    }
    for (const plan of tokenPlans) {
        const data = iface.encodeFunctionData("withdrawERC20", [plan.token, recipient, plan.amount]);
        const gas = await provider.estimateGas({ from, to: proxy, data });
        console.log(`[withdraw-test] estimated gas withdrawERC20 ${formatToken(plan.amount, plan.decimals, plan.symbol)}: ${gas.toString()}`);
    }
}

async function sendAndWait(label, txPromise) {
    const tx = await txPromise;
    console.log(`[withdraw-test] ${label} tx: ${tx.hash}`);
    const receipt = await tx.wait(1);
    if (receipt.status !== 1) {
        throw new Error(`${label} transaction failed: ${tx.hash}`);
    }
    console.log(`[withdraw-test] ${label} confirmed in block ${receipt.blockNumber}`);
    return receipt;
}

async function run() {
    const args = parseArgs(process.argv.slice(2));
    if (args.help) {
        printHelp();
        return;
    }

    await loadEnv();

    const network = resolveBscNetwork();
    const provider = new ethers.providers.JsonRpcProvider(network.rpcUrl, network.chainId);
    const proxy = resolveProxyAddress(args, network);
    const proxyCode = await provider.getCode(proxy);
    if (!proxyCode || proxyCode === "0x") {
        throw new Error(`Auth proxy has no code: ${proxy}`);
    }

    const identity = await resolveDeployerIdentity({ env: process.env });
    if (!identity) {
        throw new Error("Missing signer. Configure a deploy keystore or private key before running withdrawal test.");
    }
    const signerAddress = normalizeAddress(identity.address, "signer");
    const auth = new Contract(proxy, AUTH_ABI, provider);
    const [owner, executorRaw] = await Promise.all([auth.owner(), auth.getExecutor()]);
    const executor = normalizeAddress(executorRaw, "executor");
    const authorized = sameAddress(signerAddress, owner) || (!sameAddress(executor, ZERO_ADDRESS) && sameAddress(signerAddress, executor));
    if (!authorized) {
        throw new Error(`Signer ${signerAddress} is not auth owner ${owner} or executor ${executor}`);
    }

    const recipient = normalizeAddress(
        args.recipient || readFirstEnv("WITHDRAW_TEST_RECIPIENT", "AUTH_WITHDRAW_TEST_RECIPIENT") || signerAddress,
        "recipient",
    );
    const needNative = !args.erc20Only;
    const needErc20 = !args.nativeOnly;
    const nativeBalance = await provider.getBalance(proxy);
    const nativeAmountText = args.nativeAmount || readFirstEnv("WITHDRAW_TEST_NATIVE_AMOUNT", "AUTH_WITHDRAW_TEST_NATIVE_AMOUNT") || "0.0001";
    const nativeAmount = args.sweepKnown && needNative
        ? nativeBalance
        : ethers.utils.parseEther(nativeAmountText);
    const waitSeconds = parsePositiveSeconds(args.waitSeconds || readFirstEnv("WITHDRAW_TEST_WAIT_SECONDS", "AUTH_WITHDRAW_TEST_WAIT_SECONDS"), 600, "wait seconds");
    const pollSeconds = parsePositiveSeconds(args.pollSeconds || readFirstEnv("WITHDRAW_TEST_POLL_SECONDS", "AUTH_WITHDRAW_TEST_POLL_SECONDS"), 10, "poll seconds");

    console.log(`[withdraw-test] network: ${network.label} chainId=${network.chainId}`);
    console.log(`[withdraw-test] proxy: ${proxy}`);
    console.log(`[withdraw-test] signer: ${signerAddress}`);
    console.log(`[withdraw-test] owner: ${owner}`);
    console.log(`[withdraw-test] executor: ${executor}`);
    console.log(`[withdraw-test] recipient: ${recipient}`);

    const iface = new ethers.utils.Interface(AUTH_ABI);

    if (args.sweepKnown) {
        const envToken = readFirstEnv("WITHDRAW_TEST_ERC20_TOKEN", "AUTH_WITHDRAW_TEST_ERC20_TOKEN");
        const extraTokens = [...args.erc20Tokens, ...(envToken ? envToken.split(",") : [])];
        const { plans: tokenPlans, checked } = needErc20
            ? await buildSweepTokenPlans({ provider, proxy, extraTokens })
            : { plans: [], checked: [] };

        console.log(`[withdraw-test] proxy native balance: ${formatNative(nativeBalance)}`);
        for (const token of checked) {
            console.log(`[withdraw-test] proxy ${token.symbol} balance: ${formatToken(token.balance, token.decimals, token.symbol)} (${token.token})`);
        }

        const plannedCount = (needNative && nativeAmount.gt(0) ? 1 : 0) + tokenPlans.length;
        if (plannedCount === 0) {
            console.log("[withdraw-test] sweep-known: no non-zero known balances to withdraw");
            return;
        }

        console.log("[withdraw-test] sweep plan:");
        if (needNative && nativeAmount.gt(0)) {
            console.log(`[withdraw-test] - native ${formatNative(nativeAmount)}`);
        }
        for (const plan of tokenPlans) {
            console.log(`[withdraw-test] - ${formatToken(plan.amount, plan.decimals, plan.symbol)} (${plan.token})`);
        }

        await estimateWithdrawalPlanGas({
            provider,
            iface,
            from: signerAddress,
            proxy,
            recipient,
            nativeAmount: needNative ? nativeAmount : ethers.constants.Zero,
            tokenPlans,
        });

        if (args.dryRun) {
            console.log("[withdraw-test] dry-run: sweep plan is ready; no transaction sent");
            return;
        }

        const wallet = await unlockDeployerWalletOnce({
            env: process.env,
            loadWalletFromKeystore,
        });
        if (!(wallet instanceof Wallet)) {
            throw new Error("Signer unlock failed");
        }
        if (!sameAddress(wallet.address, signerAddress)) {
            throw new Error(`Unlocked wallet ${wallet.address} does not match expected signer ${signerAddress}`);
        }

        const authWithSigner = new Contract(proxy, AUTH_ABI, wallet.connect(provider));
        if (needNative && nativeAmount.gt(0)) {
            const before = await provider.getBalance(proxy);
            await sendAndWait("withdrawNative", authWithSigner.withdrawNative(recipient, nativeAmount));
            const after = await provider.getBalance(proxy);
            console.log(`[withdraw-test] proxy native decreased by ${formatNative(before.sub(after))}`);
        }

        for (const plan of tokenPlans) {
            const recipientBefore = await plan.erc20.balanceOf(recipient);
            const proxyBefore = await plan.erc20.balanceOf(proxy);
            await sendAndWait(`withdrawERC20 ${plan.symbol}`, authWithSigner.withdrawERC20(plan.token, recipient, plan.amount));
            const recipientAfter = await plan.erc20.balanceOf(recipient);
            const proxyAfter = await plan.erc20.balanceOf(proxy);
            console.log(`[withdraw-test] proxy ${plan.symbol} decreased by ${formatToken(proxyBefore.sub(proxyAfter), plan.decimals, plan.symbol)}`);
            console.log(`[withdraw-test] recipient ${plan.symbol} increased by ${formatToken(recipientAfter.sub(recipientBefore), plan.decimals, plan.symbol)}`);
        }

        console.log("[withdraw-test] sweep withdrawal path verified");
        return;
    }

    const erc20Token = normalizeAddress(
        args.erc20Tokens[0] || readFirstEnv("WITHDRAW_TEST_ERC20_TOKEN", "AUTH_WITHDRAW_TEST_ERC20_TOKEN") || DEFAULT_ERC20_TOKEN,
        "erc20 token",
    );
    const erc20AmountText = args.erc20Amount || readFirstEnv("WITHDRAW_TEST_ERC20_AMOUNT", "AUTH_WITHDRAW_TEST_ERC20_AMOUNT") || "0.1";
    const tokenPlan = await buildSingleTokenPlan({ provider, proxy, token: erc20Token, amountText: erc20AmountText });
    const erc20 = tokenPlan.erc20;
    const erc20Decimals = tokenPlan.decimals;
    const erc20Symbol = tokenPlan.symbol;
    const erc20Amount = tokenPlan.amount;

    printFundingInstructions({ proxy, needNative, needErc20, nativeAmount, erc20Amount, erc20Decimals, erc20Symbol, erc20Token });

    let balances = await readBalances({ provider, erc20, proxy });
    printBalanceStatus({ balances, needNative, needErc20, nativeAmount, erc20Amount, erc20Decimals, erc20Symbol });
    let ready = hasRequiredBalances({ balances, needNative, needErc20, nativeAmount, erc20Amount });

    if (!ready && args.wait) {
        balances = await waitForRequiredBalances({
            provider,
            erc20,
            proxy,
            needNative,
            needErc20,
            nativeAmount,
            erc20Amount,
            erc20Decimals,
            erc20Symbol,
            waitSeconds,
            pollSeconds,
        });
        ready = hasRequiredBalances({ balances, needNative, needErc20, nativeAmount, erc20Amount });
    }

    if (!ready) {
        if (args.dryRun) {
            console.log("[withdraw-test] dry-run: deposits are not ready; no transaction will be sent");
            return;
        }
        throw new Error("Proxy does not have enough test deposits. Fund the proxy address above, then rerun with --wait or rerun after deposits confirm.");
    }

    await estimateWithdrawalGas({
        provider,
        iface,
        from: signerAddress,
        proxy,
        recipient,
        erc20Token,
        needNative,
        needErc20,
        nativeAmount,
        erc20Amount,
    });

    if (args.dryRun) {
        console.log("[withdraw-test] dry-run: balances are ready; no transaction sent");
        return;
    }

    const wallet = await unlockDeployerWalletOnce({
        env: process.env,
        loadWalletFromKeystore,
    });
    if (!(wallet instanceof Wallet)) {
        throw new Error("Signer unlock failed");
    }
    if (!sameAddress(wallet.address, signerAddress)) {
        throw new Error(`Unlocked wallet ${wallet.address} does not match expected signer ${signerAddress}`);
    }

    const authWithSigner = new Contract(proxy, AUTH_ABI, wallet.connect(provider));
    if (needNative) {
        const before = await provider.getBalance(proxy);
        await sendAndWait("withdrawNative", authWithSigner.withdrawNative(recipient, nativeAmount));
        const after = await provider.getBalance(proxy);
        const spent = before.sub(after);
        console.log(`[withdraw-test] proxy native decreased by ${formatNative(spent)}`);
    }

    if (needErc20) {
        const recipientBefore = await erc20.balanceOf(recipient);
        const proxyBefore = await erc20.balanceOf(proxy);
        await sendAndWait("withdrawERC20", authWithSigner.withdrawERC20(erc20Token, recipient, erc20Amount));
        const recipientAfter = await erc20.balanceOf(recipient);
        const proxyAfter = await erc20.balanceOf(proxy);
        console.log(`[withdraw-test] proxy ${erc20Symbol} decreased by ${formatToken(proxyBefore.sub(proxyAfter), erc20Decimals, erc20Symbol)}`);
        console.log(`[withdraw-test] recipient ${erc20Symbol} increased by ${formatToken(recipientAfter.sub(recipientBefore), erc20Decimals, erc20Symbol)}`);
    }

    console.log("[withdraw-test] withdrawal path verified");
}

run().catch((error) => {
    console.error(`[withdraw-test] FATAL: ${error.message}`);
    process.exitCode = 1;
});
