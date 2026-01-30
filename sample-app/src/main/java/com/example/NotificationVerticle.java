package com.example;

import io.micrometer.prometheus.PrometheusConfig;
import io.micrometer.prometheus.PrometheusMeterRegistry;
import io.vertx.core.AbstractVerticle;
import io.vertx.ext.web.Router;
import io.vertx.ext.web.RoutingContext;

import java.util.*;
import java.util.concurrent.ConcurrentLinkedDeque;
import java.util.concurrent.atomic.AtomicLong;

/**
 * Simulates a bank notification / messaging service.
 *
 * Profiling characteristics:
 * - Template rendering via String.format and StringBuilder (allocation heavy)
 * - Queue drain loops (different CPU shape — short tight iterations)
 * - Bulk message generation (GC pressure from many short-lived strings)
 * - Retry simulation with exponential backoff (Thread.sleep patterns in lock profile)
 */
public class NotificationVerticle extends AbstractVerticle {

    private final PrometheusMeterRegistry registry;
    private final ConcurrentLinkedDeque<Map<String, Object>> outbox = new ConcurrentLinkedDeque<>();
    private final ConcurrentLinkedDeque<Map<String, Object>> sentLog = new ConcurrentLinkedDeque<>();
    private final AtomicLong msgSeq = new AtomicLong();
    private final Random rng = new Random();

    private static final int MAX_LOG = 20000;

    private static final String[] TEMPLATES = {
        "Dear %s, your transfer of $%s has been completed. Reference: %s. Thank you for banking with us.",
        "ALERT: A login from %s was detected on your account %s at %s. If this wasn't you, call 1-800-BANK.",
        "Your monthly statement for account %s is ready. Period: %s. Balance: $%s.",
        "Payment of $%s to %s has been scheduled for %s. Reference: %s.",
        "Your loan application %s has been %s. Details: rate=%s, term=%s months.",
        "Fraud alert: Transaction %s for $%s at %s has been flagged. Please verify.",
        "Welcome to BankCorp, %s! Your new %s account %s is now active.",
        "Reminder: Your credit card payment of $%s is due on %s. Current balance: $%s."
    };

    public NotificationVerticle() {
        this(new PrometheusMeterRegistry(PrometheusConfig.DEFAULT));
    }

    public NotificationVerticle(PrometheusMeterRegistry registry) {
        this.registry = registry;
    }

    @Override
    public void start() {
        Router router = Router.router(vertx);

        router.get("/health").handler(ctx -> ctx.response().end("OK"));
        router.get("/metrics").handler(ctx ->
                ctx.response().putHeader("content-type", "text/plain").end(registry.scrape()));

        // Send a single notification
        router.get("/notify/send").handler(ctx -> {
            handleSend(ctx);
        });

        // Bulk send — generate and queue many messages
        router.get("/notify/bulk").handler(ctx -> vertx.executeBlocking(p -> {
            handleBulk(ctx);
            p.complete();
        }, false, ar -> {}));

        // Drain outbox — process queued messages with retry logic
        router.get("/notify/drain").handler(ctx -> vertx.executeBlocking(p -> {
            handleDrain(ctx);
            p.complete();
        }, false, ar -> {}));

        // Render a template — heavy string formatting
        router.get("/notify/render").handler(ctx -> {
            handleRender(ctx);
        });

        // Delivery status report
        router.get("/notify/status").handler(ctx -> {
            handleStatus(ctx);
        });

        // Retry failed messages with exponential backoff
        router.get("/notify/retry").handler(ctx -> vertx.executeBlocking(p -> {
            handleRetry(ctx);
            p.complete();
        }, false, ar -> {}));

        vertx.createHttpServer()
             .requestHandler(router)
             .listen(8080)
             .onSuccess(s -> System.out.println("NotificationVerticle HTTP server started on port 8080"));
    }

    private void handleSend(RoutingContext ctx) {
        String msgId = "MSG-" + msgSeq.incrementAndGet();
        String rendered = renderTemplate();

        Map<String, Object> msg = new LinkedHashMap<>();
        msg.put("id", msgId);
        msg.put("body", rendered);
        msg.put("channel", rng.nextBoolean() ? "email" : rng.nextBoolean() ? "sms" : "push");
        msg.put("status", "sent");
        msg.put("timestamp", System.currentTimeMillis());

        addToLog(msg);
        ctx.response().end("Sent " + msgId + " via " + msg.get("channel") + " (" + rendered.length() + " chars)");
    }

    private void handleBulk(RoutingContext ctx) {
        int count = 500 + rng.nextInt(1500);
        for (int i = 0; i < count; i++) {
            String msgId = "MSG-" + msgSeq.incrementAndGet();
            String rendered = renderTemplate();

            Map<String, Object> msg = new LinkedHashMap<>();
            msg.put("id", msgId);
            msg.put("body", rendered);
            msg.put("channel", i % 3 == 0 ? "email" : i % 3 == 1 ? "sms" : "push");
            msg.put("status", "queued");
            msg.put("timestamp", System.currentTimeMillis());
            msg.put("attempts", 0);

            outbox.addLast(msg);
        }
        ctx.response().end("Queued " + count + " messages (outbox=" + outbox.size() + ")");
    }

    private void handleDrain(RoutingContext ctx) {
        int processed = 0;
        int failed = 0;
        int maxDrain = 1000;

        while (!outbox.isEmpty() && processed < maxDrain) {
            Map<String, Object> msg = outbox.pollFirst();
            if (msg == null) break;

            // Simulate delivery with occasional failures
            boolean success = rng.nextInt(100) < 92; // 92% success rate
            if (success) {
                msg.put("status", "delivered");
                addToLog(msg);
                processed++;
            } else {
                msg.put("status", "failed");
                int attempts = (Integer) msg.getOrDefault("attempts", 0) + 1;
                msg.put("attempts", attempts);
                if (attempts < 3) {
                    outbox.addLast(msg); // re-queue
                } else {
                    msg.put("status", "dead-letter");
                    addToLog(msg);
                }
                failed++;
            }
        }

        ctx.response().end(String.format("Drain: processed=%d failed=%d remaining=%d", processed, failed, outbox.size()));
    }

    private void handleRender(RoutingContext ctx) {
        // Render many templates to stress string allocation
        int count = 200 + rng.nextInt(300);
        int totalChars = 0;
        for (int i = 0; i < count; i++) {
            String rendered = renderTemplate();
            totalChars += rendered.length();
        }
        ctx.response().end("Rendered " + count + " templates (" + totalChars + " total chars)");
    }

    private void handleStatus(RoutingContext ctx) {
        Map<String, Integer> statusCounts = new LinkedHashMap<>();
        statusCounts.put("sent", 0);
        statusCounts.put("delivered", 0);
        statusCounts.put("failed", 0);
        statusCounts.put("dead-letter", 0);
        statusCounts.put("queued", 0);

        for (Map<String, Object> msg : sentLog) {
            String status = (String) msg.getOrDefault("status", "unknown");
            statusCounts.merge(status, 1, Integer::sum);
        }

        int queued = outbox.size();
        statusCounts.put("queued", queued);

        ctx.response().end("Status: " + statusCounts);
    }

    private void handleRetry(RoutingContext ctx) {
        int retried = 0;
        List<Map<String, Object>> failedMsgs = new ArrayList<>();

        for (Map<String, Object> msg : sentLog) {
            if ("failed".equals(msg.get("status")) || "dead-letter".equals(msg.get("status"))) {
                failedMsgs.add(msg);
                if (failedMsgs.size() >= 50) break;
            }
        }

        for (Map<String, Object> msg : failedMsgs) {
            int attempt = (Integer) msg.getOrDefault("attempts", 0) + 1;
            // Exponential backoff: 10ms, 20ms, 40ms
            int backoff = 10 * (1 << Math.min(attempt, 4));
            try { Thread.sleep(backoff); }
            catch (InterruptedException e) { Thread.currentThread().interrupt(); break; }

            msg.put("attempts", attempt);
            if (rng.nextInt(100) < 80) { // 80% success on retry
                msg.put("status", "delivered");
            }
            retried++;
        }

        ctx.response().end("Retry: " + retried + " messages re-attempted");
    }

    private String renderTemplate() {
        String template = TEMPLATES[rng.nextInt(TEMPLATES.length)];
        // Generate random values to fill the template
        Object[] args = new Object[8];
        for (int i = 0; i < args.length; i++) {
            switch (rng.nextInt(4)) {
                case 0: args[i] = "Customer-" + rng.nextInt(10000); break;
                case 1: args[i] = String.format("%.2f", 10 + rng.nextDouble() * 9990); break;
                case 2: args[i] = "REF-" + rng.nextInt(999999); break;
                default: args[i] = new Date().toString(); break;
            }
        }
        try {
            return String.format(template, args);
        } catch (Exception e) {
            return template; // fallback if format args don't match
        }
    }

    private void addToLog(Map<String, Object> msg) {
        sentLog.addFirst(msg);
        while (sentLog.size() > MAX_LOG) sentLog.pollLast();
    }
}
