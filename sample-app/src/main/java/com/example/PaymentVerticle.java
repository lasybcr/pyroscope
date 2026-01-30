package com.example;

import io.micrometer.prometheus.PrometheusConfig;
import io.micrometer.prometheus.PrometheusMeterRegistry;
import io.vertx.core.AbstractVerticle;
import io.vertx.core.CompositeFuture;
import io.vertx.core.Future;
import io.vertx.core.Promise;
import io.vertx.ext.web.Router;
import io.vertx.ext.web.RoutingContext;

import java.math.BigDecimal;
import java.math.MathContext;
import java.math.RoundingMode;
import java.security.MessageDigest;
import java.security.NoSuchAlgorithmException;
import java.util.*;
import java.util.concurrent.ConcurrentHashMap;
import java.util.concurrent.atomic.AtomicLong;

/**
 * Simulates a bank payment processing service.
 *
 * Profiling characteristics:
 * - BigDecimal math (CPU + allocation heavy, no floating-point shortcuts)
 * - SHA-256 hashing for transaction signing (CPU bound)
 * - Synchronized ledger writes (lock contention)
 * - Multi-step payment orchestration (fan-out latency)
 */
public class PaymentVerticle extends AbstractVerticle {

    private final PrometheusMeterRegistry registry;
    private final ConcurrentHashMap<String, Map<String, Object>> ledger = new ConcurrentHashMap<>();
    private final AtomicLong txnSeq = new AtomicLong();
    private final Random rng = new Random();

    public PaymentVerticle() {
        this(new PrometheusMeterRegistry(PrometheusConfig.DEFAULT));
    }

    public PaymentVerticle(PrometheusMeterRegistry registry) {
        this.registry = registry;
    }

    @Override
    public void start() {
        Router router = Router.router(vertx);

        router.get("/health").handler(ctx -> ctx.response().end("OK"));
        router.get("/metrics").handler(ctx ->
                ctx.response().putHeader("content-type", "text/plain").end(registry.scrape()));

        // Wire transfer — BigDecimal precision arithmetic + SHA-256 signing
        router.get("/payment/transfer").handler(ctx -> vertx.executeBlocking(promise -> {
            handleTransfer(ctx);
            promise.complete();
        }, false, ar -> {}));

        // Batch payroll — process many payments with ledger locking
        router.get("/payment/payroll").handler(ctx -> vertx.executeBlocking(promise -> {
            handlePayroll(ctx);
            promise.complete();
        }, false, ar -> {}));

        // FX conversion — iterative currency conversion with BigDecimal
        router.get("/payment/fx").handler(ctx -> {
            handleFxConversion(ctx);
        });

        // Payment orchestration — fraud check + debit + credit + notification
        router.get("/payment/orchestrate").handler(ctx -> {
            handleOrchestration(ctx);
        });

        // Transaction history — scan ledger, filter, sort
        router.get("/payment/history").handler(ctx -> vertx.executeBlocking(promise -> {
            handleHistory(ctx);
            promise.complete();
        }, false, ar -> {}));

        // Reconciliation — cross-reference all ledger entries
        router.get("/payment/reconcile").handler(ctx -> vertx.executeBlocking(promise -> {
            handleReconciliation(ctx);
            promise.complete();
        }, false, ar -> {}));

        vertx.createHttpServer()
             .requestHandler(router)
             .listen(8080)
             .onSuccess(s -> System.out.println("PaymentVerticle HTTP server started on port 8080"));
    }

    private void handleTransfer(RoutingContext ctx) {
        String txnId = "TXN-" + txnSeq.incrementAndGet();
        BigDecimal amount = BigDecimal.valueOf(1 + rng.nextInt(100000), 2);
        BigDecimal fee = amount.multiply(new BigDecimal("0.0015"), MathContext.DECIMAL128);
        BigDecimal tax = amount.multiply(new BigDecimal("0.0025"), MathContext.DECIMAL128);
        BigDecimal total = amount.add(fee).add(tax).setScale(2, RoundingMode.HALF_UP);

        // Sign transaction
        String payload = txnId + "|" + amount + "|" + total + "|" + System.nanoTime();
        String signature = sha256(payload);

        // Record in ledger
        synchronized (ledger) {
            Map<String, Object> entry = new LinkedHashMap<>();
            entry.put("id", txnId);
            entry.put("amount", amount.toPlainString());
            entry.put("fee", fee.toPlainString());
            entry.put("tax", tax.toPlainString());
            entry.put("total", total.toPlainString());
            entry.put("signature", signature);
            entry.put("timestamp", System.currentTimeMillis());
            entry.put("status", "completed");
            ledger.put(txnId, entry);
        }

        ctx.response().end("Transfer " + txnId + ": " + total + " (sig=" + signature.substring(0, 8) + "...)");
    }

    private synchronized void handlePayroll(RoutingContext ctx) {
        int employees = 200 + rng.nextInt(300);
        BigDecimal totalPaid = BigDecimal.ZERO;

        for (int i = 0; i < employees; i++) {
            String txnId = "PAY-" + txnSeq.incrementAndGet();
            BigDecimal salary = BigDecimal.valueOf(300000 + rng.nextInt(700000), 2);
            BigDecimal withholding = salary.multiply(new BigDecimal("0.22"), MathContext.DECIMAL128);
            BigDecimal net = salary.subtract(withholding).setScale(2, RoundingMode.HALF_UP);
            totalPaid = totalPaid.add(net);

            String sig = sha256(txnId + "|" + net + "|" + i);

            Map<String, Object> entry = new LinkedHashMap<>();
            entry.put("id", txnId);
            entry.put("type", "payroll");
            entry.put("gross", salary.toPlainString());
            entry.put("net", net.toPlainString());
            entry.put("signature", sig);
            entry.put("timestamp", System.currentTimeMillis());
            entry.put("status", "completed");
            ledger.put(txnId, entry);
        }

        ctx.response().end("Payroll: " + employees + " employees, total=" + totalPaid.toPlainString());
    }

    private void handleFxConversion(RoutingContext ctx) {
        // Simulate multi-hop currency conversion: USD -> EUR -> GBP -> JPY -> USD
        String[] currencies = {"USD", "EUR", "GBP", "JPY", "CHF", "CAD", "AUD"};
        BigDecimal amount = BigDecimal.valueOf(10000 + rng.nextInt(90000), 2);
        BigDecimal current = amount;
        StringBuilder trail = new StringBuilder();

        for (int hop = 0; hop < 20; hop++) {
            String from = currencies[hop % currencies.length];
            String to = currencies[(hop + 1) % currencies.length];
            BigDecimal rate = BigDecimal.valueOf(50 + rng.nextInt(200), 2);
            current = current.multiply(rate, MathContext.DECIMAL128).setScale(4, RoundingMode.HALF_UP);
            trail.append(from).append("->").append(to).append("@").append(rate).append("; ");
        }

        ctx.response().end("FX: " + amount + " through " + 20 + " hops = " + current);
    }

    private void handleOrchestration(RoutingContext ctx) {
        List<Future> steps = new ArrayList<>();

        // Fraud check
        Promise<String> fraud = Promise.promise();
        vertx.executeBlocking(p -> {
            sha256("fraud-check-" + System.nanoTime());
            sleep(5 + rng.nextInt(20));
            p.complete("fraud:pass");
        }, false, ar -> fraud.complete((String) ar.result()));
        steps.add(fraud.future());

        // Debit source account
        Promise<String> debit = Promise.promise();
        vertx.executeBlocking(p -> {
            BigDecimal amt = BigDecimal.valueOf(rng.nextInt(100000), 2);
            sha256("debit-" + amt + "-" + System.nanoTime());
            sleep(10 + rng.nextInt(30));
            p.complete("debit:ok");
        }, false, ar -> debit.complete((String) ar.result()));
        steps.add(debit.future());

        // Credit destination account
        Promise<String> credit = Promise.promise();
        vertx.executeBlocking(p -> {
            sleep(10 + rng.nextInt(30));
            p.complete("credit:ok");
        }, false, ar -> credit.complete((String) ar.result()));
        steps.add(credit.future());

        // Send notification
        Promise<String> notify = Promise.promise();
        vertx.executeBlocking(p -> {
            sleep(5 + rng.nextInt(15));
            p.complete("notify:sent");
        }, false, ar -> notify.complete((String) ar.result()));
        steps.add(notify.future());

        CompositeFuture.all(steps).onComplete(ar ->
                ctx.response().end("Orchestration: " + (ar.succeeded() ? "all steps passed" : "partial failure")));
    }

    private void handleHistory(RoutingContext ctx) {
        String type = ctx.queryParams().get("type");
        List<Map<String, Object>> results = new ArrayList<>();

        for (Map<String, Object> entry : ledger.values()) {
            if (type != null && !type.equals(entry.get("type"))) continue;
            results.add(entry);
            if (results.size() >= 500) break;
        }

        results.sort(Comparator.comparingLong(e -> -((Long) e.getOrDefault("timestamp", 0L))));

        StringBuilder sb = new StringBuilder();
        for (Map<String, Object> r : results) {
            sb.append(r.get("id")).append("|").append(r.get("status")).append("|").append(r.get("total")).append("\n");
        }

        ctx.response().end("History: " + results.size() + " entries (" + sb.length() + " bytes)");
    }

    private void handleReconciliation(RoutingContext ctx) {
        BigDecimal totalDebits = BigDecimal.ZERO;
        BigDecimal totalCredits = BigDecimal.ZERO;
        int mismatches = 0;

        for (Map<String, Object> entry : ledger.values()) {
            String totalStr = (String) entry.getOrDefault("total", (String) entry.getOrDefault("net", "0"));
            BigDecimal val = new BigDecimal(totalStr);
            String sig = (String) entry.get("signature");
            String id = (String) entry.get("id");

            // Re-verify signature
            String recomputed = sha256(id + "|" + totalStr + "|verify");
            if (sig != null && !sig.equals(recomputed)) {
                mismatches++;
            }

            if (id != null && id.startsWith("PAY-")) {
                totalCredits = totalCredits.add(val);
            } else {
                totalDebits = totalDebits.add(val);
            }
        }

        ctx.response().end("Reconciliation: debits=" + totalDebits.toPlainString() +
                " credits=" + totalCredits.toPlainString() + " mismatches=" + mismatches);
    }

    private String sha256(String input) {
        try {
            MessageDigest md = MessageDigest.getInstance("SHA-256");
            byte[] hash = md.digest(input.getBytes());
            StringBuilder sb = new StringBuilder();
            for (byte b : hash) sb.append(String.format("%02x", b));
            return sb.toString();
        } catch (NoSuchAlgorithmException e) {
            return "error";
        }
    }

    private void sleep(int ms) {
        try { Thread.sleep(ms); }
        catch (InterruptedException e) { Thread.currentThread().interrupt(); }
    }
}
