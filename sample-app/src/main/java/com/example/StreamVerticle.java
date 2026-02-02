package com.example;

import io.micrometer.prometheus.PrometheusConfig;
import io.micrometer.prometheus.PrometheusMeterRegistry;
import io.vertx.core.AbstractVerticle;
import io.vertx.ext.reactivestreams.ReactiveReadStream;
import io.vertx.ext.reactivestreams.ReactiveWriteStream;
import io.vertx.ext.web.Router;

import org.reactivestreams.Publisher;
import org.reactivestreams.Subscriber;
import org.reactivestreams.Subscription;

import java.util.*;
import java.util.concurrent.ConcurrentLinkedQueue;
import java.util.concurrent.CopyOnWriteArrayList;
import java.util.concurrent.atomic.AtomicBoolean;
import java.util.concurrent.atomic.AtomicInteger;
import java.util.concurrent.atomic.AtomicLong;
import java.util.function.Function;

/**
 * Verticle demonstrating org.reactivestreams spec via vertx-reactive-streams bridge.
 * Domain: transaction event stream processing.
 *
 * Provides 6 endpoints with distinct reactive profiling signatures.
 * OPTIMIZED toggle flips between naive and efficient implementations
 * for before/after flame-graph comparison in Pyroscope.
 */
public class StreamVerticle extends AbstractVerticle {

    private final PrometheusMeterRegistry registry;
    private final boolean optimized = "true".equalsIgnoreCase(System.getenv("OPTIMIZED"));
    private final Random rng = new Random();
    private final AtomicLong txnSeq = new AtomicLong();

    private static final String[] REGIONS = {"US-EAST", "US-WEST", "EU-WEST", "EU-EAST", "APAC"};
    private static final String[] TYPES = {"DEBIT", "CREDIT", "TRANSFER", "REFUND", "FEE"};
    private static final String[] CURRENCIES = {"USD", "EUR", "GBP", "JPY", "AUD"};

    public StreamVerticle() {
        this(new PrometheusMeterRegistry(PrometheusConfig.DEFAULT));
    }

    public StreamVerticle(PrometheusMeterRegistry registry) {
        this.registry = registry;
    }

    @Override
    public void start() {
        Router router = Router.router(vertx);

        router.get("/health").handler(ctx -> ctx.response().end("OK"));
        router.get("/metrics").handler(ctx ->
                ctx.response().putHeader("content-type", "text/plain").end(registry.scrape()));

        // --- Stream processing endpoints ---

        // 1. Basic Publisher→Subscriber transaction stream
        router.get("/stream/transactions").handler(ctx -> {
            int count = 500;
            List<Map<String, Object>> results = new ArrayList<>();
            TransactionPublisher publisher = new TransactionPublisher(count);

            publisher.subscribe(new Subscriber<Map<String, Object>>() {
                Subscription sub;
                @Override
                public void onSubscribe(Subscription s) {
                    this.sub = s;
                    if (optimized) {
                        s.request(64);
                    } else {
                        s.request(1);
                    }
                }
                @Override
                public void onNext(Map<String, Object> txn) {
                    if (optimized) {
                        results.add(txn);
                        if (results.size() % 64 == 0) {
                            sub.request(64);
                        }
                    } else {
                        // Unoptimized: sync blocking per element
                        processTransactionBlocking(txn);
                        results.add(txn);
                        sub.request(1);
                    }
                }
                @Override
                public void onError(Throwable t) {
                    ctx.response().setStatusCode(500).end(t.getMessage());
                }
                @Override
                public void onComplete() {
                    ctx.response()
                       .putHeader("content-type", "application/json")
                       .end("{\"count\":" + results.size() + ",\"mode\":\"" +
                            (optimized ? "batched" : "single") + "\"}");
                }
            });
        });

        // 2. Count-windowed aggregation
        router.get("/stream/windowed-aggregation").handler(ctx -> {
            int totalEvents = 5000;
            int windowSize = 100;

            if (optimized) {
                windowedAggregationOptimized(totalEvents, windowSize, ctx);
            } else {
                windowedAggregationUnoptimized(totalEvents, windowSize, ctx);
            }
        });

        // 3. Fan-out to 5 subscribers
        router.get("/stream/fanout").handler(ctx -> {
            int count = 200;
            List<Map<String, Object>> events = generateTransactions(count);

            if (optimized) {
                fanoutOptimized(events, ctx);
            } else {
                fanoutUnoptimized(events, ctx);
            }
        });

        // 4. 5-stage transform pipeline
        router.get("/stream/transform-pipeline").handler(ctx -> {
            int count = 1000;

            if (optimized) {
                transformPipelineOptimized(count, ctx);
            } else {
                transformPipelineUnoptimized(count, ctx);
            }
        });

        // 5. Backpressure stress: fast producer / slow consumer
        router.get("/stream/backpressure-stress").handler(ctx ->
                vertx.executeBlocking(promise -> {
                    int count = 10000;
                    if (optimized) {
                        promise.complete(backpressureOptimized(count));
                    } else {
                        promise.complete(backpressureUnoptimized(count));
                    }
                }, false, ar -> {
                    @SuppressWarnings("unchecked")
                    Map<String, Object> result = (Map<String, Object>) ar.result();
                    ctx.response()
                       .putHeader("content-type", "application/json")
                       .end("{\"processed\":" + result.get("processed") +
                            ",\"mode\":\"" + result.get("mode") + "\"}");
                }));

        // 6. Merge-sorted: 3-stream fan-in
        router.get("/stream/merge-sorted").handler(ctx ->
                vertx.executeBlocking(promise -> {
                    if (optimized) {
                        promise.complete(mergeSortedOptimized());
                    } else {
                        promise.complete(mergeSortedUnoptimized());
                    }
                }, false, ar -> {
                    @SuppressWarnings("unchecked")
                    Map<String, Object> result = (Map<String, Object>) ar.result();
                    ctx.response()
                       .putHeader("content-type", "application/json")
                       .end("{\"merged\":" + result.get("merged") +
                            ",\"mode\":\"" + result.get("mode") + "\"}");
                }));

        vertx.createHttpServer()
             .requestHandler(router)
             .listen(8080)
             .onSuccess(s -> System.out.println("StreamVerticle HTTP server started on port 8080"));
    }

    // -------------------------------------------------------------------------
    // Transaction generation
    // -------------------------------------------------------------------------

    private Map<String, Object> generateTransaction() {
        Map<String, Object> txn = new LinkedHashMap<>();
        txn.put("id", "TXN-" + txnSeq.incrementAndGet());
        txn.put("timestamp", System.currentTimeMillis());
        txn.put("region", REGIONS[rng.nextInt(REGIONS.length)]);
        txn.put("type", TYPES[rng.nextInt(TYPES.length)]);
        txn.put("currency", CURRENCIES[rng.nextInt(CURRENCIES.length)]);
        txn.put("amount", Math.round(rng.nextDouble() * 10000.0) / 100.0);
        txn.put("account", "ACC-" + rng.nextInt(50000));
        txn.put("merchant", "MER-" + rng.nextInt(5000));
        return txn;
    }

    private List<Map<String, Object>> generateTransactions(int count) {
        List<Map<String, Object>> list = new ArrayList<>(count);
        for (int i = 0; i < count; i++) {
            list.add(generateTransaction());
        }
        return list;
    }

    private void processTransactionBlocking(Map<String, Object> txn) {
        // Simulate per-element blocking work
        double amount = ((Number) txn.get("amount")).doubleValue();
        double hash = 0;
        for (int i = 0; i < 100; i++) {
            hash += Math.sin(amount + i) * Math.cos(amount - i);
        }
        txn.put("hash", hash);
    }

    // -------------------------------------------------------------------------
    // Publisher implementation
    // -------------------------------------------------------------------------

    private class TransactionPublisher implements Publisher<Map<String, Object>> {
        private final int total;

        TransactionPublisher(int total) {
            this.total = total;
        }

        @Override
        public void subscribe(Subscriber<? super Map<String, Object>> subscriber) {
            subscriber.onSubscribe(new Subscription() {
                private int emitted = 0;
                private final AtomicBoolean cancelled = new AtomicBoolean(false);

                @Override
                public void request(long n) {
                    if (cancelled.get()) return;
                    for (long i = 0; i < n && emitted < total; i++) {
                        subscriber.onNext(generateTransaction());
                        emitted++;
                    }
                    if (emitted >= total) {
                        subscriber.onComplete();
                    }
                }

                @Override
                public void cancel() {
                    cancelled.set(true);
                }
            });
        }
    }

    // -------------------------------------------------------------------------
    // Endpoint 2: Windowed Aggregation
    // -------------------------------------------------------------------------

    private void windowedAggregationUnoptimized(int totalEvents, int windowSize,
                                                 io.vertx.ext.web.RoutingContext ctx) {
        // Unoptimized: buffer ALL events into ArrayList, then multi-pass aggregate
        List<Map<String, Object>> allEvents = new ArrayList<>();
        TransactionPublisher publisher = new TransactionPublisher(totalEvents);

        publisher.subscribe(new Subscriber<Map<String, Object>>() {
            Subscription sub;
            @Override
            public void onSubscribe(Subscription s) {
                this.sub = s;
                s.request(1);
            }
            @Override
            public void onNext(Map<String, Object> txn) {
                allEvents.add(txn);
                sub.request(1);
            }
            @Override
            public void onError(Throwable t) {
                ctx.response().setStatusCode(500).end(t.getMessage());
            }
            @Override
            public void onComplete() {
                // Multi-pass: iterate windows after buffering everything
                List<Map<String, Object>> windows = new ArrayList<>();
                for (int start = 0; start < allEvents.size(); start += windowSize) {
                    int end = Math.min(start + windowSize, allEvents.size());
                    List<Map<String, Object>> window = new ArrayList<>(allEvents.subList(start, end));
                    double sum = 0;
                    double min = Double.MAX_VALUE;
                    double max = Double.MIN_VALUE;
                    for (Map<String, Object> e : window) {
                        double amt = ((Number) e.get("amount")).doubleValue();
                        sum += amt;
                        min = Math.min(min, amt);
                        max = Math.max(max, amt);
                    }
                    Map<String, Object> agg = new LinkedHashMap<>();
                    agg.put("windowStart", start);
                    agg.put("count", window.size());
                    agg.put("sum", sum);
                    agg.put("min", min);
                    agg.put("max", max);
                    agg.put("avg", sum / window.size());
                    windows.add(agg);
                }
                ctx.response()
                   .putHeader("content-type", "application/json")
                   .end("{\"windows\":" + windows.size() + ",\"totalEvents\":" +
                        allEvents.size() + ",\"mode\":\"buffered\"}");
            }
        });
    }

    private void windowedAggregationOptimized(int totalEvents, int windowSize,
                                               io.vertx.ext.web.RoutingContext ctx) {
        // Optimized: rolling aggregation in onNext, constant memory
        final double[] windowStats = new double[4]; // sum, min, max, count
        final int[] windowCount = {0};
        final int[] totalWindows = {0};

        TransactionPublisher publisher = new TransactionPublisher(totalEvents);

        publisher.subscribe(new Subscriber<Map<String, Object>>() {
            Subscription sub;
            @Override
            public void onSubscribe(Subscription s) {
                this.sub = s;
                windowStats[1] = Double.MAX_VALUE; // min
                windowStats[2] = Double.MIN_VALUE; // max
                s.request(64);
            }
            @Override
            public void onNext(Map<String, Object> txn) {
                double amt = ((Number) txn.get("amount")).doubleValue();
                windowStats[0] += amt;
                windowStats[1] = Math.min(windowStats[1], amt);
                windowStats[2] = Math.max(windowStats[2], amt);
                windowStats[3]++;
                windowCount[0]++;

                if (windowCount[0] >= windowSize) {
                    totalWindows[0]++;
                    // Reset window
                    windowStats[0] = 0;
                    windowStats[1] = Double.MAX_VALUE;
                    windowStats[2] = Double.MIN_VALUE;
                    windowStats[3] = 0;
                    windowCount[0] = 0;
                }

                if ((int) windowStats[3] % 64 == 0) {
                    sub.request(64);
                }
            }
            @Override
            public void onError(Throwable t) {
                ctx.response().setStatusCode(500).end(t.getMessage());
            }
            @Override
            public void onComplete() {
                if (windowCount[0] > 0) totalWindows[0]++;
                ctx.response()
                   .putHeader("content-type", "application/json")
                   .end("{\"windows\":" + totalWindows[0] + ",\"totalEvents\":" +
                        totalEvents + ",\"mode\":\"rolling\"}");
            }
        });
    }

    // -------------------------------------------------------------------------
    // Endpoint 3: Fan-out
    // -------------------------------------------------------------------------

    private void fanoutUnoptimized(List<Map<String, Object>> events,
                                    io.vertx.ext.web.RoutingContext ctx) {
        // Unoptimized: deep-copy per subscriber, sequential processing
        int subscriberCount = 5;
        int[] totals = new int[subscriberCount];

        for (int s = 0; s < subscriberCount; s++) {
            List<Map<String, Object>> copy = new ArrayList<>();
            for (Map<String, Object> event : events) {
                copy.add(new LinkedHashMap<>(event)); // deep copy each event
            }
            // Sequential processing per subscriber
            for (Map<String, Object> e : copy) {
                processTransactionBlocking(e);
            }
            totals[s] = copy.size();
        }

        int total = 0;
        for (int t : totals) total += t;
        ctx.response()
           .putHeader("content-type", "application/json")
           .end("{\"subscribers\":5,\"totalProcessed\":" + total +
                ",\"mode\":\"deep-copy-sequential\"}");
    }

    private void fanoutOptimized(List<Map<String, Object>> events,
                                  io.vertx.ext.web.RoutingContext ctx) {
        // Optimized: shared immutable refs, parallel via executeBlocking
        int subscriberCount = 5;
        AtomicInteger completed = new AtomicInteger(0);
        AtomicInteger totalProcessed = new AtomicInteger(0);
        // Make events immutable-by-convention (shared across subscribers)
        List<Map<String, Object>> sharedEvents = Collections.unmodifiableList(events);

        for (int s = 0; s < subscriberCount; s++) {
            vertx.executeBlocking(promise -> {
                int count = 0;
                for (Map<String, Object> e : sharedEvents) {
                    // Read-only access, no copy needed
                    double amount = ((Number) e.get("amount")).doubleValue();
                    double hash = 0;
                    for (int i = 0; i < 100; i++) {
                        hash += Math.sin(amount + i) * Math.cos(amount - i);
                    }
                    count++;
                }
                promise.complete(count);
            }, false, ar -> {
                totalProcessed.addAndGet((Integer) ar.result());
                if (completed.incrementAndGet() == subscriberCount) {
                    ctx.response()
                       .putHeader("content-type", "application/json")
                       .end("{\"subscribers\":5,\"totalProcessed\":" + totalProcessed.get() +
                            ",\"mode\":\"shared-parallel\"}");
                }
            });
        }
    }

    // -------------------------------------------------------------------------
    // Endpoint 4: Transform Pipeline
    // -------------------------------------------------------------------------

    private void transformPipelineUnoptimized(int count, io.vertx.ext.web.RoutingContext ctx) {
        // Unoptimized: new ArrayList per stage (5 intermediate lists)
        List<Map<String, Object>> stage0 = generateTransactions(count);

        // Stage 1: enrich
        List<Map<String, Object>> stage1 = new ArrayList<>();
        for (Map<String, Object> txn : stage0) {
            Map<String, Object> enriched = new LinkedHashMap<>(txn);
            enriched.put("enriched", true);
            enriched.put("riskScore", rng.nextDouble());
            enriched.put("processingNode", "node-" + rng.nextInt(10));
            stage1.add(enriched);
        }

        // Stage 2: filter (keep amount > 20)
        List<Map<String, Object>> stage2 = new ArrayList<>();
        for (Map<String, Object> txn : stage1) {
            if (((Number) txn.get("amount")).doubleValue() > 20.0) {
                stage2.add(txn);
            }
        }

        // Stage 3: map (compute fee)
        List<Map<String, Object>> stage3 = new ArrayList<>();
        for (Map<String, Object> txn : stage2) {
            Map<String, Object> mapped = new LinkedHashMap<>(txn);
            mapped.put("fee", ((Number) txn.get("amount")).doubleValue() * 0.015);
            stage3.add(mapped);
        }

        // Stage 4: map (format output)
        List<Map<String, Object>> stage4 = new ArrayList<>();
        for (Map<String, Object> txn : stage3) {
            Map<String, Object> formatted = new LinkedHashMap<>(txn);
            formatted.put("formatted", txn.get("id") + ":" + txn.get("type") + ":" + txn.get("amount"));
            stage4.add(formatted);
        }

        // Stage 5: reduce (sum amounts by region)
        Map<String, Double> regionSums = new LinkedHashMap<>();
        for (Map<String, Object> txn : stage4) {
            String region = (String) txn.get("region");
            regionSums.merge(region, ((Number) txn.get("amount")).doubleValue(), Double::sum);
        }

        ctx.response()
           .putHeader("content-type", "application/json")
           .end("{\"inputCount\":" + count + ",\"afterFilter\":" + stage2.size() +
                ",\"regions\":" + regionSums.size() + ",\"mode\":\"multi-list\"}");
    }

    private void transformPipelineOptimized(int count, io.vertx.ext.web.RoutingContext ctx) {
        // Optimized: single composed function in onNext, no intermediate lists
        Map<String, Double> regionSums = new LinkedHashMap<>();
        final int[] afterFilter = {0};

        TransactionPublisher publisher = new TransactionPublisher(count);

        // Composed transform: enrich → filter → map → map → reduce in single pass
        publisher.subscribe(new Subscriber<Map<String, Object>>() {
            Subscription sub;
            @Override
            public void onSubscribe(Subscription s) {
                this.sub = s;
                s.request(64);
            }
            @Override
            public void onNext(Map<String, Object> txn) {
                // Enrich inline
                double riskScore = rng.nextDouble();
                double amount = ((Number) txn.get("amount")).doubleValue();

                // Filter
                if (amount > 20.0) {
                    afterFilter[0]++;
                    // Map: compute fee (don't need to store)
                    // Reduce: accumulate by region
                    String region = (String) txn.get("region");
                    regionSums.merge(region, amount, Double::sum);
                }

                sub.request(1);
            }
            @Override
            public void onError(Throwable t) {
                ctx.response().setStatusCode(500).end(t.getMessage());
            }
            @Override
            public void onComplete() {
                ctx.response()
                   .putHeader("content-type", "application/json")
                   .end("{\"inputCount\":" + count + ",\"afterFilter\":" + afterFilter[0] +
                        ",\"regions\":" + regionSums.size() + ",\"mode\":\"single-pass\"}");
            }
        });
    }

    // -------------------------------------------------------------------------
    // Endpoint 5: Backpressure Stress
    // -------------------------------------------------------------------------

    private Map<String, Object> backpressureUnoptimized(int count) {
        // Unoptimized: unbounded ConcurrentLinkedQueue buffer
        ConcurrentLinkedQueue<Map<String, Object>> buffer = new ConcurrentLinkedQueue<>();

        // Fast producer: dump everything into the queue
        for (int i = 0; i < count; i++) {
            buffer.add(generateTransaction());
        }

        // Slow consumer: drain one at a time with work
        int processed = 0;
        Map<String, Object> txn;
        while ((txn = buffer.poll()) != null) {
            processTransactionBlocking(txn);
            processed++;
        }

        Map<String, Object> result = new LinkedHashMap<>();
        result.put("processed", processed);
        result.put("mode", "unbounded-queue");
        return result;
    }

    private Map<String, Object> backpressureOptimized(int count) {
        // Optimized: proper demand via Subscription.request(n)
        final int[] processed = {0};
        final int batchSize = 256;

        TransactionPublisher publisher = new TransactionPublisher(count);

        // Synchronous subscriber with controlled demand
        publisher.subscribe(new Subscriber<Map<String, Object>>() {
            Subscription sub;
            int inFlight = 0;
            @Override
            public void onSubscribe(Subscription s) {
                this.sub = s;
                s.request(batchSize);
            }
            @Override
            public void onNext(Map<String, Object> txn) {
                // Light processing, no blocking
                double amount = ((Number) txn.get("amount")).doubleValue();
                txn.put("hash", amount * 31);
                processed[0]++;
                inFlight++;
                if (inFlight >= batchSize) {
                    inFlight = 0;
                    sub.request(batchSize);
                }
            }
            @Override
            public void onError(Throwable t) {}
            @Override
            public void onComplete() {}
        });

        Map<String, Object> result = new LinkedHashMap<>();
        result.put("processed", processed[0]);
        result.put("mode", "demand-driven");
        return result;
    }

    // -------------------------------------------------------------------------
    // Endpoint 6: Merge-sorted (3-stream fan-in)
    // -------------------------------------------------------------------------

    private Map<String, Object> mergeSortedUnoptimized() {
        // Unoptimized: concat all 3 streams + Collections.sort
        int perStream = 2000;
        List<Map<String, Object>> all = new ArrayList<>();

        for (int s = 0; s < 3; s++) {
            List<Map<String, Object>> stream = generateTransactions(perStream);
            // Sort each sub-stream by amount
            stream.sort(Comparator.comparingDouble(
                    t -> ((Number) t.get("amount")).doubleValue()));
            all.addAll(stream);
        }

        // Re-sort the entire concatenated list
        all.sort(Comparator.comparingDouble(
                t -> ((Number) t.get("amount")).doubleValue()));

        Map<String, Object> result = new LinkedHashMap<>();
        result.put("merged", all.size());
        result.put("mode", "concat-sort");
        return result;
    }

    private Map<String, Object> mergeSortedOptimized() {
        // Optimized: PriorityQueue k-way merge
        int perStream = 2000;
        int k = 3;

        @SuppressWarnings("unchecked")
        List<Map<String, Object>>[] streams = new List[k];
        int[] indices = new int[k];

        for (int s = 0; s < k; s++) {
            streams[s] = generateTransactions(perStream);
            streams[s].sort(Comparator.comparingDouble(
                    t -> ((Number) t.get("amount")).doubleValue()));
        }

        // PriorityQueue keyed by (amount, stream-index)
        PriorityQueue<long[]> pq = new PriorityQueue<>(
                Comparator.comparingLong(a -> a[0]));

        for (int s = 0; s < k; s++) {
            if (!streams[s].isEmpty()) {
                double amt = ((Number) streams[s].get(0).get("amount")).doubleValue();
                pq.add(new long[]{Double.doubleToLongBits(amt), s});
            }
        }

        List<Map<String, Object>> merged = new ArrayList<>(perStream * k);
        while (!pq.isEmpty()) {
            long[] top = pq.poll();
            int streamIdx = (int) top[1];
            merged.add(streams[streamIdx].get(indices[streamIdx]));
            indices[streamIdx]++;
            if (indices[streamIdx] < streams[streamIdx].size()) {
                double nextAmt = ((Number) streams[streamIdx]
                        .get(indices[streamIdx]).get("amount")).doubleValue();
                pq.add(new long[]{Double.doubleToLongBits(nextAmt), streamIdx});
            }
        }

        Map<String, Object> result = new LinkedHashMap<>();
        result.put("merged", merged.size());
        result.put("mode", "pq-merge");
        return result;
    }
}
