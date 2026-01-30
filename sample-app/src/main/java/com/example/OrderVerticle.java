package com.example;

import io.micrometer.prometheus.PrometheusConfig;
import io.micrometer.prometheus.PrometheusMeterRegistry;
import io.vertx.core.AbstractVerticle;
import io.vertx.core.CompositeFuture;
import io.vertx.core.Future;
import io.vertx.core.Promise;
import io.vertx.ext.web.Router;

import java.util.*;
import java.util.concurrent.ConcurrentHashMap;
import java.util.concurrent.atomic.AtomicLong;

/**
 * A second verticle simulating an order-processing service.
 * Deliberately uses different patterns from MainVerticle so that
 * Pyroscope flame graphs show distinct profiles for comparison.
 *
 * Key differences from MainVerticle:
 * - Heavy HashMap/ConcurrentHashMap usage (different allocation profile)
 * - String concatenation in loops (GC pressure)
 * - Synchronized order processing (lock contention)
 * - Iterative computation instead of recursive (different CPU profile shape)
 */
public class OrderVerticle extends AbstractVerticle {

    private final PrometheusMeterRegistry registry;
    private final ConcurrentHashMap<String, Map<String, Object>> orders = new ConcurrentHashMap<>();
    private final AtomicLong orderSeq = new AtomicLong();
    private final Random rng = new Random();

    public OrderVerticle() {
        this(new PrometheusMeterRegistry(PrometheusConfig.DEFAULT));
    }

    public OrderVerticle(PrometheusMeterRegistry registry) {
        this.registry = registry;
    }

    @Override
    public void start() {
        Router router = Router.router(vertx);

        router.get("/health").handler(ctx -> ctx.response().end("OK"));
        router.get("/metrics").handler(ctx ->
                ctx.response().putHeader("content-type", "text/plain").end(registry.scrape()));

        // --- Order service endpoints ---

        // Create order: heavy map allocation + string building
        router.get("/order/create").handler(ctx -> {
            String orderId = "ORD-" + orderSeq.incrementAndGet();
            Map<String, Object> order = buildOrder(orderId);
            orders.put(orderId, order);
            ctx.response().end("Created " + orderId + " (" + order.size() + " fields)");
        });

        // List orders: iterate and serialize all orders (allocation heavy)
        router.get("/order/list").handler(ctx -> {
            StringBuilder sb = new StringBuilder();
            int count = 0;
            for (Map.Entry<String, Map<String, Object>> e : orders.entrySet()) {
                sb.append(e.getKey()).append("=").append(e.getValue().toString()).append("\n");
                count++;
                if (count >= 100) break;
            }
            ctx.response().end("Listed " + count + " orders (" + sb.length() + " bytes)");
        });

        // Process order: synchronized block + iterative computation
        router.get("/order/process").handler(ctx ->
                vertx.executeBlocking(promise -> {
                    processOrders();
                    promise.complete();
                }, false, ar -> ctx.response().end("Processed batch")));

        // Validate order: regex + string ops (different CPU shape from fibonacci)
        router.get("/order/validate").handler(ctx -> {
            int validated = 0;
            for (Map<String, Object> order : orders.values()) {
                if (validateOrder(order)) validated++;
                if (validated >= 500) break;
            }
            ctx.response().end("Validated " + validated + " orders");
        });

        // Aggregate: group-by with heavy HashMap churn
        router.get("/order/aggregate").handler(ctx ->
                vertx.executeBlocking(promise -> {
                    Map<String, double[]> result = aggregateOrders();
                    promise.complete(result);
                }, false, ar -> {
                    @SuppressWarnings("unchecked")
                    Map<String, double[]> r = (Map<String, double[]>) ar.result();
                    ctx.response().end("Aggregated into " + (r != null ? r.size() : 0) + " groups");
                }));

        // Fulfill: fan-out simulation with different latency profile
        router.get("/order/fulfill").handler(ctx -> {
            List<Future> steps = new ArrayList<>();
            // inventory check
            Promise<String> inv = Promise.promise();
            vertx.executeBlocking(p -> { sleep(10 + rng.nextInt(30)); p.complete("inv-ok"); },
                    false, ar -> inv.complete((String) ar.result()));
            steps.add(inv.future());
            // payment
            Promise<String> pay = Promise.promise();
            vertx.executeBlocking(p -> { sleep(50 + rng.nextInt(100)); p.complete("pay-ok"); },
                    false, ar -> pay.complete((String) ar.result()));
            steps.add(pay.future());
            // shipping
            Promise<String> ship = Promise.promise();
            vertx.executeBlocking(p -> { sleep(30 + rng.nextInt(60)); p.complete("ship-ok"); },
                    false, ar -> ship.complete((String) ar.result()));
            steps.add(ship.future());

            CompositeFuture.all(steps).onComplete(ar ->
                    ctx.response().end("Fulfillment: " + (ar.succeeded() ? "complete" : "partial")));
        });

        vertx.createHttpServer()
             .requestHandler(router)
             .listen(8080)
             .onSuccess(s -> System.out.println("OrderVerticle HTTP server started on port 8080"));
    }

    private Map<String, Object> buildOrder(String orderId) {
        Map<String, Object> order = new LinkedHashMap<>();
        order.put("id", orderId);
        order.put("customer", "customer-" + rng.nextInt(10000));
        order.put("region", "region-" + rng.nextInt(10));
        order.put("status", "pending");
        order.put("created", System.currentTimeMillis());

        // Line items: deliberate String concatenation to create GC pressure
        List<String> items = new ArrayList<>();
        int itemCount = 1 + rng.nextInt(10);
        for (int i = 0; i < itemCount; i++) {
            String item = "";
            item += "product-" + rng.nextInt(200);
            item += "|qty=" + (1 + rng.nextInt(20));
            item += "|price=" + String.format("%.2f", 1.0 + rng.nextDouble() * 500);
            items.add(item);
        }
        order.put("items", items);
        order.put("total", items.size() * (10 + rng.nextDouble() * 100));
        return order;
    }

    private synchronized void processOrders() {
        // Synchronized to create lock contention under load
        List<String> toProcess = new ArrayList<>();
        for (Map.Entry<String, Map<String, Object>> e : orders.entrySet()) {
            if ("pending".equals(e.getValue().get("status"))) {
                toProcess.add(e.getKey());
            }
            if (toProcess.size() >= 50) break;
        }

        for (String id : toProcess) {
            Map<String, Object> order = orders.get(id);
            if (order != null) {
                // Iterative price computation (different CPU shape from recursive fibonacci)
                double total = 0;
                @SuppressWarnings("unchecked")
                List<String> items = (List<String>) order.get("items");
                if (items != null) {
                    for (String item : items) {
                        String[] parts = item.split("\\|");
                        for (String part : parts) {
                            if (part.startsWith("price=")) {
                                total += Double.parseDouble(part.substring(6));
                            }
                        }
                    }
                }
                order.put("total", total);
                order.put("status", "processed");
            }
        }
        sleep(20 + rng.nextInt(40));
    }

    private boolean validateOrder(Map<String, Object> order) {
        String id = (String) order.get("id");
        String customer = (String) order.get("customer");
        if (id == null || customer == null) return false;
        // Simulate regex validation
        if (!id.matches("ORD-\\d+")) return false;
        if (!customer.matches("customer-\\d+")) return false;
        @SuppressWarnings("unchecked")
        List<String> items = (List<String>) order.get("items");
        if (items == null || items.isEmpty()) return false;
        for (String item : items) {
            if (!item.contains("|qty=") || !item.contains("|price=")) return false;
        }
        return true;
    }

    private Map<String, double[]> aggregateOrders() {
        Map<String, double[]> regionTotals = new HashMap<>();
        for (Map<String, Object> order : orders.values()) {
            String region = (String) order.get("region");
            if (region == null) continue;
            Object totalObj = order.get("total");
            double total = totalObj instanceof Number ? ((Number) totalObj).doubleValue() : 0;
            regionTotals.computeIfAbsent(region, k -> new double[2]);
            double[] agg = regionTotals.get(region);
            agg[0] += total;
            agg[1]++;
        }
        return regionTotals;
    }

    private void sleep(int ms) {
        try { Thread.sleep(ms); }
        catch (InterruptedException e) { Thread.currentThread().interrupt(); }
    }
}
