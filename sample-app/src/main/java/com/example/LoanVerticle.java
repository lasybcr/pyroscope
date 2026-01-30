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
import java.util.*;
import java.util.concurrent.ConcurrentHashMap;
import java.util.concurrent.atomic.AtomicLong;

/**
 * Simulates a bank loan origination and servicing platform.
 *
 * Profiling characteristics:
 * - Amortization schedule generation (tight BigDecimal loops)
 * - Credit scoring with weighted rules (CPU + branching)
 * - Monte Carlo risk simulation (Math.random + iteration)
 * - Portfolio aggregation across thousands of loans
 */
public class LoanVerticle extends AbstractVerticle {

    private final PrometheusMeterRegistry registry;
    private final ConcurrentHashMap<String, Map<String, Object>> loans = new ConcurrentHashMap<>();
    private final AtomicLong loanSeq = new AtomicLong();
    private final Random rng = new Random();

    public LoanVerticle() {
        this(new PrometheusMeterRegistry(PrometheusConfig.DEFAULT));
    }

    public LoanVerticle(PrometheusMeterRegistry registry) {
        this.registry = registry;
        // Seed portfolio
        for (int i = 0; i < 3000; i++) {
            String id = "LOAN-" + loanSeq.incrementAndGet();
            Map<String, Object> loan = new LinkedHashMap<>();
            loan.put("id", id);
            loan.put("principal", BigDecimal.valueOf(10000 + rng.nextInt(490000), 2).toPlainString());
            loan.put("rate", BigDecimal.valueOf(250 + rng.nextInt(1000), 4).toPlainString());
            loan.put("termMonths", 12 + rng.nextInt(348));
            loan.put("type", i % 4 == 0 ? "mortgage" : i % 4 == 1 ? "auto" : i % 4 == 2 ? "personal" : "business");
            loan.put("status", rng.nextInt(10) < 8 ? "active" : "delinquent");
            loan.put("creditScore", 550 + rng.nextInt(300));
            loans.put(id, loan);
        }
    }

    @Override
    public void start() {
        Router router = Router.router(vertx);

        router.get("/health").handler(ctx -> ctx.response().end("OK"));
        router.get("/metrics").handler(ctx ->
                ctx.response().putHeader("content-type", "text/plain").end(registry.scrape()));

        // Apply for loan — credit scoring + decisioning
        router.get("/loan/apply").handler(ctx -> {
            handleApply(ctx);
        });

        // Generate amortization schedule
        router.get("/loan/amortize").handler(ctx -> vertx.executeBlocking(p -> {
            handleAmortize(ctx);
            p.complete();
        }, false, ar -> {}));

        // Monte Carlo risk simulation
        router.get("/loan/risk-sim").handler(ctx -> vertx.executeBlocking(p -> {
            handleRiskSim(ctx);
            p.complete();
        }, false, ar -> {}));

        // Portfolio summary
        router.get("/loan/portfolio").handler(ctx -> vertx.executeBlocking(p -> {
            handlePortfolio(ctx);
            p.complete();
        }, false, ar -> {}));

        // Delinquency report
        router.get("/loan/delinquency").handler(ctx -> vertx.executeBlocking(p -> {
            handleDelinquency(ctx);
            p.complete();
        }, false, ar -> {}));

        // Loan origination orchestration — credit check + appraisal + underwriting + funding
        router.get("/loan/originate").handler(ctx -> {
            handleOrigination(ctx);
        });

        vertx.createHttpServer()
             .requestHandler(router)
             .listen(8080)
             .onSuccess(s -> System.out.println("LoanVerticle HTTP server started on port 8080"));
    }

    private void handleApply(RoutingContext ctx) {
        int creditScore = 550 + rng.nextInt(300);
        BigDecimal income = BigDecimal.valueOf(30000 + rng.nextInt(170000));
        BigDecimal requested = BigDecimal.valueOf(5000 + rng.nextInt(495000));
        BigDecimal dti = requested.divide(income, 4, RoundingMode.HALF_UP);

        // Weighted credit scoring
        double score = 0;
        score += (creditScore - 550.0) / 300.0 * 40; // 40 pts for credit score
        score += Math.max(0, (1.0 - dti.doubleValue()) * 25);  // 25 pts for low DTI
        score += (income.doubleValue() > 75000 ? 15 : income.doubleValue() > 50000 ? 10 : 5);
        score += rng.nextGaussian() * 3; // noise
        score = Math.max(0, Math.min(100, score));

        String decision = score >= 60 ? "APPROVED" : score >= 40 ? "REVIEW" : "DENIED";
        String rate = decision.equals("APPROVED") ?
                BigDecimal.valueOf(300 + (int)((100 - score) * 10), 4).toPlainString() : "N/A";

        if (decision.equals("APPROVED")) {
            String id = "LOAN-" + loanSeq.incrementAndGet();
            Map<String, Object> loan = new LinkedHashMap<>();
            loan.put("id", id);
            loan.put("principal", requested.toPlainString());
            loan.put("rate", rate);
            loan.put("termMonths", 60);
            loan.put("type", "personal");
            loan.put("status", "active");
            loan.put("creditScore", creditScore);
            loans.put(id, loan);
        }

        ctx.response().end(String.format("Application: score=%.1f decision=%s rate=%s", score, decision, rate));
    }

    private void handleAmortize(RoutingContext ctx) {
        // Pick a loan or generate parameters
        BigDecimal principal = BigDecimal.valueOf(50000 + rng.nextInt(450000), 2);
        BigDecimal annualRate = BigDecimal.valueOf(300 + rng.nextInt(700), 4);
        int termMonths = 60 + rng.nextInt(300);

        BigDecimal monthlyRate = annualRate.divide(BigDecimal.valueOf(12), 10, RoundingMode.HALF_UP);
        // Monthly payment: P * r * (1+r)^n / ((1+r)^n - 1)
        BigDecimal onePlusR = BigDecimal.ONE.add(monthlyRate);
        BigDecimal onePlusRn = power(onePlusR, termMonths);
        BigDecimal payment = principal.multiply(monthlyRate).multiply(onePlusRn)
                .divide(onePlusRn.subtract(BigDecimal.ONE), 2, RoundingMode.HALF_UP);

        BigDecimal balance = principal;
        BigDecimal totalInterest = BigDecimal.ZERO;

        for (int month = 1; month <= termMonths; month++) {
            BigDecimal interest = balance.multiply(monthlyRate).setScale(2, RoundingMode.HALF_UP);
            BigDecimal principalPart = payment.subtract(interest);
            balance = balance.subtract(principalPart);
            totalInterest = totalInterest.add(interest);
            if (balance.compareTo(BigDecimal.ZERO) <= 0) break;
        }

        ctx.response().end(String.format("Amortize: principal=%s rate=%s term=%d payment=%s totalInterest=%s",
                principal.toPlainString(), annualRate.toPlainString(), termMonths,
                payment.toPlainString(), totalInterest.toPlainString()));
    }

    private void handleRiskSim(RoutingContext ctx) {
        int simulations = 10000;
        int defaults = 0;
        double totalLoss = 0;

        for (int sim = 0; sim < simulations; sim++) {
            // Pick a random loan from portfolio
            double defaultProb = 0.02 + rng.nextDouble() * 0.08; // 2-10% default rate
            double lgd = 0.3 + rng.nextDouble() * 0.4; // 30-70% loss given default
            double exposure = 10000 + rng.nextInt(490000);

            if (rng.nextDouble() < defaultProb) {
                defaults++;
                totalLoss += exposure * lgd;
            }
        }

        double expectedLoss = totalLoss / simulations;
        double defaultRate = (double) defaults / simulations;

        ctx.response().end(String.format("Risk Sim: %d runs, defaultRate=%.4f, expectedLoss=%.2f, totalSimLoss=%.2f",
                simulations, defaultRate, expectedLoss, totalLoss));
    }

    private void handlePortfolio(RoutingContext ctx) {
        Map<String, BigDecimal> typeTotals = new LinkedHashMap<>();
        Map<String, Integer> typeCounts = new LinkedHashMap<>();
        BigDecimal grandTotal = BigDecimal.ZERO;

        for (Map<String, Object> loan : loans.values()) {
            String type = (String) loan.get("type");
            BigDecimal principal = new BigDecimal((String) loan.get("principal"));
            typeTotals.merge(type, principal, BigDecimal::add);
            typeCounts.merge(type, 1, Integer::sum);
            grandTotal = grandTotal.add(principal);
        }

        StringBuilder sb = new StringBuilder();
        sb.append("Portfolio: ").append(loans.size()).append(" loans, total=").append(grandTotal.toPlainString()).append("\n");
        for (String type : typeTotals.keySet()) {
            sb.append(String.format("  %s: %d loans, %s\n", type, typeCounts.get(type), typeTotals.get(type).toPlainString()));
        }

        ctx.response().end(sb.toString());
    }

    private void handleDelinquency(RoutingContext ctx) {
        List<Map<String, Object>> delinquent = new ArrayList<>();
        BigDecimal atRisk = BigDecimal.ZERO;

        for (Map<String, Object> loan : loans.values()) {
            if ("delinquent".equals(loan.get("status"))) {
                delinquent.add(loan);
                atRisk = atRisk.add(new BigDecimal((String) loan.get("principal")));
            }
        }

        delinquent.sort(Comparator.comparingInt(l -> -((Integer) l.getOrDefault("creditScore", 0))));

        ctx.response().end(String.format("Delinquency: %d loans at risk, exposure=%s",
                delinquent.size(), atRisk.toPlainString()));
    }

    private void handleOrigination(RoutingContext ctx) {
        List<Future> steps = new ArrayList<>();

        // Credit check
        Promise<String> credit = Promise.promise();
        vertx.executeBlocking(p -> {
            int score = 550 + rng.nextInt(300);
            sleep(15 + rng.nextInt(35));
            p.complete("credit:" + score);
        }, false, ar -> credit.complete((String) ar.result()));
        steps.add(credit.future());

        // Property appraisal
        Promise<String> appraisal = Promise.promise();
        vertx.executeBlocking(p -> {
            sleep(30 + rng.nextInt(70));
            p.complete("appraisal:" + (100000 + rng.nextInt(900000)));
        }, false, ar -> appraisal.complete((String) ar.result()));
        steps.add(appraisal.future());

        // Underwriting
        Promise<String> underwrite = Promise.promise();
        vertx.executeBlocking(p -> {
            sleep(20 + rng.nextInt(50));
            p.complete("underwrite:approved");
        }, false, ar -> underwrite.complete((String) ar.result()));
        steps.add(underwrite.future());

        // Funding
        Promise<String> fund = Promise.promise();
        vertx.executeBlocking(p -> {
            sleep(10 + rng.nextInt(30));
            p.complete("fund:disbursed");
        }, false, ar -> fund.complete((String) ar.result()));
        steps.add(fund.future());

        CompositeFuture.all(steps).onComplete(ar ->
                ctx.response().end("Origination: " + (ar.succeeded() ? "funded" : "failed")));
    }

    private BigDecimal power(BigDecimal base, int exp) {
        BigDecimal result = BigDecimal.ONE;
        for (int i = 0; i < exp; i++) {
            result = result.multiply(base, MathContext.DECIMAL64);
        }
        return result;
    }

    private void sleep(int ms) {
        try { Thread.sleep(ms); }
        catch (InterruptedException e) { Thread.currentThread().interrupt(); }
    }
}
