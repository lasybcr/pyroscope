package com.example;

import io.micrometer.prometheus.PrometheusConfig;
import io.micrometer.prometheus.PrometheusMeterRegistry;
import io.vertx.core.AbstractVerticle;
import io.vertx.ext.web.Router;
import io.vertx.ext.web.RoutingContext;

import java.util.*;
import java.util.concurrent.ConcurrentLinkedDeque;
import java.util.regex.Pattern;

/**
 * Simulates a bank fraud detection / risk scoring service.
 *
 * Profiling characteristics:
 * - Regex-heavy rule evaluation (CPU bound, pattern compilation)
 * - Sliding window event storage (allocation churn)
 * - Statistical computation (Math.log, Math.exp, standard deviation)
 * - Large collection scanning and filtering
 */
public class FraudDetectionVerticle extends AbstractVerticle {

    private final PrometheusMeterRegistry registry;
    private final Random rng = new Random();
    private final ConcurrentLinkedDeque<Map<String, Object>> eventStream = new ConcurrentLinkedDeque<>();
    private static final int MAX_EVENTS = 50000;

    // Precompiled patterns for rule engine
    private static final Pattern[] SUSPICIOUS_PATTERNS = {
        Pattern.compile("^(TXN|PAY)-\\d{1,3}$"),            // low sequence IDs
        Pattern.compile(".*amount=(\\d{5,}).*"),              // large amounts
        Pattern.compile(".*country=(RU|KP|IR|SY).*"),         // sanctioned countries
        Pattern.compile(".*velocity=(\\d{3,}).*"),            // high velocity
        Pattern.compile(".*device=unknown.*"),                 // unknown devices
        Pattern.compile(".*ip=10\\.0\\.0\\..*"),              // internal IPs
        Pattern.compile(".*merchant=(casino|crypto).*"),       // high-risk merchants
        Pattern.compile(".*currency=(XMR|BTC).*"),             // crypto currencies
    };

    public FraudDetectionVerticle() {
        this(new PrometheusMeterRegistry(PrometheusConfig.DEFAULT));
    }

    public FraudDetectionVerticle(PrometheusMeterRegistry registry) {
        this.registry = registry;
    }

    @Override
    public void start() {
        Router router = Router.router(vertx);

        router.get("/health").handler(ctx -> ctx.response().end("OK"));
        router.get("/metrics").handler(ctx ->
                ctx.response().putHeader("content-type", "text/plain").end(registry.scrape()));

        // Score a single transaction
        router.get("/fraud/score").handler(ctx -> {
            handleScore(ctx);
        });

        // Batch rule evaluation — scan events against all rules
        router.get("/fraud/scan").handler(ctx -> vertx.executeBlocking(promise -> {
            handleScan(ctx);
            promise.complete();
        }, false, ar -> {}));

        // Anomaly detection — statistical analysis on event stream
        router.get("/fraud/anomaly").handler(ctx -> vertx.executeBlocking(promise -> {
            handleAnomaly(ctx);
            promise.complete();
        }, false, ar -> {}));

        // Ingest events into the sliding window
        router.get("/fraud/ingest").handler(ctx -> {
            handleIngest(ctx);
        });

        // Velocity check — count events in time windows
        router.get("/fraud/velocity").handler(ctx -> {
            handleVelocity(ctx);
        });

        // Generate risk report
        router.get("/fraud/report").handler(ctx -> vertx.executeBlocking(promise -> {
            handleReport(ctx);
            promise.complete();
        }, false, ar -> {}));

        vertx.createHttpServer()
             .requestHandler(router)
             .listen(8080)
             .onSuccess(s -> System.out.println("FraudDetectionVerticle HTTP server started on port 8080"));
    }

    private void handleScore(RoutingContext ctx) {
        String event = buildEvent();
        int ruleHits = 0;
        double score = 0.0;

        for (Pattern p : SUSPICIOUS_PATTERNS) {
            if (p.matcher(event).find()) {
                ruleHits++;
                score += 12.5;
            }
        }

        // Additional heuristic scoring
        score += Math.log1p(event.length()) * 2.0;
        score += rng.nextGaussian() * 5.0;
        score = Math.max(0, Math.min(100, score));

        String risk = score > 75 ? "HIGH" : score > 40 ? "MEDIUM" : "LOW";

        addEvent(event, score, risk);
        ctx.response().end(String.format("Score: %.1f (%s) — %d rules matched", score, risk, ruleHits));
    }

    private void handleScan(RoutingContext ctx) {
        int scanned = 0;
        int flagged = 0;

        for (Map<String, Object> event : eventStream) {
            String raw = (String) event.getOrDefault("raw", "");
            for (Pattern p : SUSPICIOUS_PATTERNS) {
                if (p.matcher(raw).find()) {
                    flagged++;
                    break;
                }
            }
            scanned++;
            if (scanned >= 10000) break;
        }

        ctx.response().end("Scan: " + scanned + " events, " + flagged + " flagged");
    }

    private void handleAnomaly(RoutingContext ctx) {
        // Collect scores for statistical analysis
        List<Double> scores = new ArrayList<>();
        for (Map<String, Object> event : eventStream) {
            Object s = event.get("score");
            if (s instanceof Number) {
                scores.add(((Number) s).doubleValue());
            }
            if (scores.size() >= 5000) break;
        }

        if (scores.isEmpty()) {
            ctx.response().end("Anomaly: no data");
            return;
        }

        // Mean
        double sum = 0;
        for (double s : scores) sum += s;
        double mean = sum / scores.size();

        // Standard deviation
        double sqDiffSum = 0;
        for (double s : scores) sqDiffSum += (s - mean) * (s - mean);
        double stddev = Math.sqrt(sqDiffSum / scores.size());

        // Count anomalies (> 2 std deviations)
        int anomalies = 0;
        double threshold = mean + 2 * stddev;
        for (double s : scores) {
            if (s > threshold) anomalies++;
        }

        // Compute percentiles (sort-based)
        Collections.sort(scores);
        double p50 = scores.get(scores.size() / 2);
        double p95 = scores.get((int) (scores.size() * 0.95));
        double p99 = scores.get((int) (scores.size() * 0.99));

        ctx.response().end(String.format("Anomaly: n=%d mean=%.1f std=%.1f p50=%.1f p95=%.1f p99=%.1f anomalies=%d",
                scores.size(), mean, stddev, p50, p95, p99, anomalies));
    }

    private void handleIngest(RoutingContext ctx) {
        int count = 50 + rng.nextInt(150);
        for (int i = 0; i < count; i++) {
            String event = buildEvent();
            double score = rng.nextDouble() * 100;
            String risk = score > 75 ? "HIGH" : score > 40 ? "MEDIUM" : "LOW";
            addEvent(event, score, risk);
        }
        ctx.response().end("Ingested " + count + " events (total=" + eventStream.size() + ")");
    }

    private void handleVelocity(RoutingContext ctx) {
        long now = System.currentTimeMillis();
        long windowMs = 60_000; // 1 minute window
        int count1m = 0, count5m = 0, count15m = 0;

        for (Map<String, Object> event : eventStream) {
            long ts = (Long) event.getOrDefault("timestamp", 0L);
            long age = now - ts;
            if (age <= windowMs) count1m++;
            if (age <= windowMs * 5) count5m++;
            if (age <= windowMs * 15) count15m++;
        }

        ctx.response().end(String.format("Velocity: 1m=%d 5m=%d 15m=%d", count1m, count5m, count15m));
    }

    private void handleReport(RoutingContext ctx) {
        Map<String, int[]> riskBuckets = new LinkedHashMap<>();
        riskBuckets.put("HIGH", new int[1]);
        riskBuckets.put("MEDIUM", new int[1]);
        riskBuckets.put("LOW", new int[1]);

        int total = 0;
        double totalScore = 0;

        for (Map<String, Object> event : eventStream) {
            String risk = (String) event.getOrDefault("risk", "LOW");
            int[] bucket = riskBuckets.get(risk);
            if (bucket != null) bucket[0]++;
            Object s = event.get("score");
            if (s instanceof Number) totalScore += ((Number) s).doubleValue();
            total++;
        }

        StringBuilder sb = new StringBuilder();
        sb.append("Risk Report: total=").append(total);
        sb.append(String.format(" avgScore=%.1f", total > 0 ? totalScore / total : 0));
        for (Map.Entry<String, int[]> e : riskBuckets.entrySet()) {
            sb.append(" ").append(e.getKey()).append("=").append(e.getValue()[0]);
        }

        ctx.response().end(sb.toString());
    }

    private String buildEvent() {
        String[] countries = {"US", "GB", "DE", "FR", "JP", "RU", "KP", "CA", "AU", "IR"};
        String[] merchants = {"amazon", "walmart", "casino", "crypto", "grocery", "airline", "hotel"};
        String[] devices = {"iphone", "android", "web", "unknown", "tablet"};
        String[] currencies = {"USD", "EUR", "GBP", "BTC", "XMR", "JPY"};

        return "txn=TXN-" + rng.nextInt(100000) +
               "|amount=" + (10 + rng.nextInt(99990)) +
               "|country=" + countries[rng.nextInt(countries.length)] +
               "|merchant=" + merchants[rng.nextInt(merchants.length)] +
               "|device=" + devices[rng.nextInt(devices.length)] +
               "|currency=" + currencies[rng.nextInt(currencies.length)] +
               "|velocity=" + rng.nextInt(500) +
               "|ip=10.0.0." + rng.nextInt(256);
    }

    private void addEvent(String raw, double score, String risk) {
        Map<String, Object> event = new HashMap<>();
        event.put("raw", raw);
        event.put("score", score);
        event.put("risk", risk);
        event.put("timestamp", System.currentTimeMillis());
        eventStream.addFirst(event);

        // Trim sliding window
        while (eventStream.size() > MAX_EVENTS) {
            eventStream.pollLast();
        }
    }
}
