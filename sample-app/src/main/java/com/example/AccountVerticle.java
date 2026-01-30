package com.example;

import io.micrometer.prometheus.PrometheusConfig;
import io.micrometer.prometheus.PrometheusMeterRegistry;
import io.vertx.core.AbstractVerticle;
import io.vertx.ext.web.Router;
import io.vertx.ext.web.RoutingContext;

import java.math.BigDecimal;
import java.math.RoundingMode;
import java.util.*;
import java.util.concurrent.ConcurrentHashMap;
import java.util.concurrent.atomic.AtomicLong;
import java.util.stream.Collectors;

/**
 * Simulates a bank core accounts / customer service.
 *
 * Profiling characteristics:
 * - Heavy ConcurrentHashMap usage (many small puts/gets)
 * - Stream API for filtering/grouping (different CPU shape from loops)
 * - String formatting for statement generation (allocation heavy)
 * - Interest calculation with BigDecimal iteration
 */
public class AccountVerticle extends AbstractVerticle {

    private final PrometheusMeterRegistry registry;
    private final ConcurrentHashMap<String, Map<String, Object>> accounts = new ConcurrentHashMap<>();
    private final ConcurrentHashMap<String, List<Map<String, Object>>> transactions = new ConcurrentHashMap<>();
    private final AtomicLong acctSeq = new AtomicLong();
    private final Random rng = new Random();

    public AccountVerticle() {
        this(new PrometheusMeterRegistry(PrometheusConfig.DEFAULT));
    }

    public AccountVerticle(PrometheusMeterRegistry registry) {
        this.registry = registry;
        // Seed some accounts
        for (int i = 0; i < 2000; i++) {
            String id = "ACCT-" + acctSeq.incrementAndGet();
            Map<String, Object> acct = new LinkedHashMap<>();
            acct.put("id", id);
            acct.put("name", "Customer " + i);
            acct.put("type", i % 3 == 0 ? "savings" : i % 3 == 1 ? "checking" : "business");
            acct.put("balance", BigDecimal.valueOf(100 + rng.nextInt(999900), 2).toPlainString());
            acct.put("branch", "branch-" + (i % 20));
            acct.put("status", "active");
            acct.put("opened", System.currentTimeMillis() - rng.nextInt(365 * 24 * 3600) * 1000L);
            accounts.put(id, acct);
            transactions.put(id, new ArrayList<>());
        }
    }

    @Override
    public void start() {
        Router router = Router.router(vertx);

        router.get("/health").handler(ctx -> ctx.response().end("OK"));
        router.get("/metrics").handler(ctx ->
                ctx.response().putHeader("content-type", "text/plain").end(registry.scrape()));

        // Open account
        router.get("/account/open").handler(ctx -> handleOpen(ctx));

        // Get balance
        router.get("/account/balance").handler(ctx -> handleBalance(ctx));

        // Deposit / withdraw
        router.get("/account/deposit").handler(ctx -> vertx.executeBlocking(p -> {
            handleDeposit(ctx);
            p.complete();
        }, false, ar -> {}));

        router.get("/account/withdraw").handler(ctx -> vertx.executeBlocking(p -> {
            handleWithdraw(ctx);
            p.complete();
        }, false, ar -> {}));

        // Generate statement — heavy string formatting
        router.get("/account/statement").handler(ctx -> vertx.executeBlocking(p -> {
            handleStatement(ctx);
            p.complete();
        }, false, ar -> {}));

        // Interest calculation — BigDecimal iteration across all accounts
        router.get("/account/interest").handler(ctx -> vertx.executeBlocking(p -> {
            handleInterest(ctx);
            p.complete();
        }, false, ar -> {}));

        // Search accounts — stream API filtering
        router.get("/account/search").handler(ctx -> {
            handleSearch(ctx);
        });

        // Branch summary — group-by aggregation
        router.get("/account/branch-summary").handler(ctx -> vertx.executeBlocking(p -> {
            handleBranchSummary(ctx);
            p.complete();
        }, false, ar -> {}));

        vertx.createHttpServer()
             .requestHandler(router)
             .listen(8080)
             .onSuccess(s -> System.out.println("AccountVerticle HTTP server started on port 8080"));
    }

    private void handleOpen(RoutingContext ctx) {
        String id = "ACCT-" + acctSeq.incrementAndGet();
        String type = ctx.queryParams().get("type");
        if (type == null) type = "checking";

        Map<String, Object> acct = new LinkedHashMap<>();
        acct.put("id", id);
        acct.put("name", "Customer " + id);
        acct.put("type", type);
        acct.put("balance", "0.00");
        acct.put("branch", "branch-" + rng.nextInt(20));
        acct.put("status", "active");
        acct.put("opened", System.currentTimeMillis());
        accounts.put(id, acct);
        transactions.put(id, new ArrayList<>());

        ctx.response().end("Opened " + id + " (" + type + ")");
    }

    private void handleBalance(RoutingContext ctx) {
        String id = ctx.queryParams().get("id");
        if (id == null) {
            // Random account
            List<String> keys = new ArrayList<>(accounts.keySet());
            if (keys.isEmpty()) { ctx.response().end("no accounts"); return; }
            id = keys.get(rng.nextInt(keys.size()));
        }
        Map<String, Object> acct = accounts.get(id);
        if (acct == null) { ctx.response().end("not found"); return; }
        ctx.response().end(id + " balance=" + acct.get("balance") + " (" + acct.get("type") + ")");
    }

    private synchronized void handleDeposit(RoutingContext ctx) {
        String id = pickRandomAccount();
        if (id == null) { ctx.response().end("no accounts"); return; }
        Map<String, Object> acct = accounts.get(id);
        BigDecimal current = new BigDecimal((String) acct.get("balance"));
        BigDecimal amount = BigDecimal.valueOf(100 + rng.nextInt(9900), 2);
        BigDecimal newBal = current.add(amount).setScale(2, RoundingMode.HALF_UP);
        acct.put("balance", newBal.toPlainString());

        recordTransaction(id, "deposit", amount.toPlainString());
        ctx.response().end("Deposit " + amount + " to " + id + " -> " + newBal);
    }

    private synchronized void handleWithdraw(RoutingContext ctx) {
        String id = pickRandomAccount();
        if (id == null) { ctx.response().end("no accounts"); return; }
        Map<String, Object> acct = accounts.get(id);
        BigDecimal current = new BigDecimal((String) acct.get("balance"));
        BigDecimal amount = BigDecimal.valueOf(100 + rng.nextInt(5000), 2);
        if (amount.compareTo(current) > 0) amount = current;
        BigDecimal newBal = current.subtract(amount).setScale(2, RoundingMode.HALF_UP);
        acct.put("balance", newBal.toPlainString());

        recordTransaction(id, "withdrawal", amount.toPlainString());
        ctx.response().end("Withdraw " + amount + " from " + id + " -> " + newBal);
    }

    private void handleStatement(RoutingContext ctx) {
        String id = pickRandomAccount();
        if (id == null) { ctx.response().end("no accounts"); return; }

        Map<String, Object> acct = accounts.get(id);
        List<Map<String, Object>> txns = transactions.getOrDefault(id, Collections.emptyList());

        StringBuilder sb = new StringBuilder();
        sb.append(String.format("=== STATEMENT FOR %s ===\n", id));
        sb.append(String.format("Name: %s\n", acct.get("name")));
        sb.append(String.format("Type: %s\n", acct.get("type")));
        sb.append(String.format("Branch: %s\n", acct.get("branch")));
        sb.append(String.format("Current Balance: %s\n", acct.get("balance")));
        sb.append(String.format("Transactions: %d\n", txns.size()));
        sb.append("---\n");

        int shown = 0;
        for (Map<String, Object> txn : txns) {
            sb.append(String.format("  %s | %s | %s\n",
                    txn.get("type"), txn.get("amount"), new Date((Long) txn.get("timestamp"))));
            shown++;
            if (shown >= 100) break;
        }

        ctx.response().end("Statement: " + sb.length() + " bytes, " + shown + " transactions");
    }

    private void handleInterest(RoutingContext ctx) {
        BigDecimal rate = new BigDecimal("0.0425"); // 4.25% APY
        BigDecimal dailyRate = rate.divide(BigDecimal.valueOf(365), 10, RoundingMode.HALF_UP);
        int totalAccounts = 0;
        BigDecimal totalInterest = BigDecimal.ZERO;

        for (Map<String, Object> acct : accounts.values()) {
            if (!"savings".equals(acct.get("type"))) continue;
            BigDecimal balance = new BigDecimal((String) acct.get("balance"));
            // Compound daily for 30 days
            BigDecimal compounded = balance;
            for (int day = 0; day < 30; day++) {
                compounded = compounded.add(compounded.multiply(dailyRate, new java.math.MathContext(10)))
                        .setScale(2, RoundingMode.HALF_UP);
            }
            BigDecimal interest = compounded.subtract(balance);
            totalInterest = totalInterest.add(interest);
            totalAccounts++;
        }

        ctx.response().end(String.format("Interest: %d savings accounts, total interest=%s",
                totalAccounts, totalInterest.toPlainString()));
    }

    private void handleSearch(RoutingContext ctx) {
        String type = ctx.queryParams().get("type");
        String branch = ctx.queryParams().get("branch");
        if (type == null) type = "checking";
        if (branch == null) branch = "branch-" + rng.nextInt(20);

        String filterType = type;
        String filterBranch = branch;

        List<Map<String, Object>> results = accounts.values().stream()
                .filter(a -> filterType.equals(a.get("type")))
                .filter(a -> filterBranch.equals(a.get("branch")))
                .sorted(Comparator.comparing(a -> (String) a.get("id")))
                .limit(100)
                .collect(Collectors.toList());

        ctx.response().end("Search: " + results.size() + " accounts (" + filterType + " @ " + filterBranch + ")");
    }

    private void handleBranchSummary(RoutingContext ctx) {
        Map<String, BigDecimal> branchTotals = new LinkedHashMap<>();
        Map<String, Integer> branchCounts = new LinkedHashMap<>();

        for (Map<String, Object> acct : accounts.values()) {
            String branch = (String) acct.get("branch");
            BigDecimal bal = new BigDecimal((String) acct.get("balance"));
            branchTotals.merge(branch, bal, BigDecimal::add);
            branchCounts.merge(branch, 1, Integer::sum);
        }

        StringBuilder sb = new StringBuilder();
        for (String branch : branchTotals.keySet()) {
            sb.append(String.format("%s: %d accounts, total=%s\n",
                    branch, branchCounts.get(branch), branchTotals.get(branch).toPlainString()));
        }

        ctx.response().end("Branch Summary: " + branchTotals.size() + " branches\n" + sb);
    }

    private void recordTransaction(String acctId, String type, String amount) {
        Map<String, Object> txn = new HashMap<>();
        txn.put("type", type);
        txn.put("amount", amount);
        txn.put("timestamp", System.currentTimeMillis());
        transactions.computeIfAbsent(acctId, k -> new ArrayList<>()).add(txn);
    }

    private String pickRandomAccount() {
        List<String> keys = new ArrayList<>(accounts.keySet());
        if (keys.isEmpty()) return null;
        return keys.get(rng.nextInt(keys.size()));
    }
}
