package com.example;

import com.example.handlers.*;
import io.micrometer.prometheus.PrometheusConfig;
import io.micrometer.prometheus.PrometheusMeterRegistry;
import io.vertx.core.AbstractVerticle;
import io.vertx.core.Vertx;
import io.vertx.core.VertxOptions;
import io.vertx.ext.web.Router;
import io.vertx.micrometer.MicrometerMetricsOptions;
import io.vertx.micrometer.VertxPrometheusOptions;

import java.util.ArrayList;
import java.util.List;
import java.util.Random;

/**
 * A sample Vert.x HTTP application that exposes endpoints which simulate
 * realistic workloads (CPU, memory allocation, blocking I/O).
 *
 * This class is intentionally left unmodified for Pyroscope – the agent
 * is attached externally via JAVA_TOOL_OPTIONS.
 */
public class MainVerticle extends AbstractVerticle {

    private static final Random RNG = new Random();
    private final boolean optimized = "true".equalsIgnoreCase(System.getenv("OPTIMIZED"));

    public static void main(String[] args) {
        PrometheusMeterRegistry registry = new PrometheusMeterRegistry(PrometheusConfig.DEFAULT);

        VertxOptions options = new VertxOptions()
                .setMetricsOptions(new MicrometerMetricsOptions()
                        .setPrometheusOptions(new VertxPrometheusOptions().setEnabled(true))
                        .setMicrometerRegistry(registry)
                        .setEnabled(true));

        Vertx vertx = Vertx.vertx(options);

        String verticle = System.getenv("VERTICLE");
        if (verticle == null) verticle = "main";
        switch (verticle.toLowerCase()) {
            case "order":
                vertx.deployVerticle(new OrderVerticle(registry));
                break;
            case "payment":
                vertx.deployVerticle(new PaymentVerticle(registry));
                break;
            case "fraud":
                vertx.deployVerticle(new FraudDetectionVerticle(registry));
                break;
            case "account":
                vertx.deployVerticle(new AccountVerticle(registry));
                break;
            case "loan":
                vertx.deployVerticle(new LoanVerticle(registry));
                break;
            case "notification":
                vertx.deployVerticle(new NotificationVerticle(registry));
                break;
            case "stream":
                vertx.deployVerticle(new StreamVerticle(registry));
                break;
            default:
                vertx.deployVerticle(new MainVerticle(registry));
                break;
        }
    }

    private final PrometheusMeterRegistry registry;

    public MainVerticle() {
        this(new PrometheusMeterRegistry(PrometheusConfig.DEFAULT));
    }

    public MainVerticle(PrometheusMeterRegistry registry) {
        this.registry = registry;
    }

    @Override
    public void start() {
        Router router = Router.router(vertx);

        // Health check
        router.get("/health").handler(ctx -> ctx.response().end("OK"));

        // Prometheus metrics endpoint
        router.get("/metrics").handler(ctx ->
                ctx.response()
                   .putHeader("content-type", "text/plain")
                   .end(registry.scrape()));

        // --- Original workload endpoints ---

        // CPU-intensive: recursive Fibonacci
        router.get("/cpu").handler(ctx -> {
            int n = 35 + RNG.nextInt(5);
            long result = fibonacci(n);
            ctx.response().end("fib(" + n + ") = " + result);
        });

        // Memory-allocation-heavy endpoint
        router.get("/alloc").handler(ctx -> {
            List<byte[]> sink = new ArrayList<>();
            for (int i = 0; i < 500; i++) {
                sink.add(new byte[1024 * (1 + RNG.nextInt(64))]);
            }
            ctx.response().end("allocated " + sink.size() + " buffers");
        });

        // Simulated slow I/O (lock contention / blocking)
        router.get("/slow").handler(ctx ->
                vertx.executeBlocking(promise -> {
                    try {
                        Thread.sleep(200 + RNG.nextInt(300));
                    } catch (InterruptedException e) {
                        Thread.currentThread().interrupt();
                    }
                    promise.complete("done");
                }, false, ar -> ctx.response().end("slow request completed")));

        // Simulated database-like work
        router.get("/db").handler(ctx ->
                vertx.executeBlocking(promise -> {
                    simulateDatabaseWork();
                    promise.complete();
                }, false, ar -> ctx.response().end("db work done")));

        // Mixed workload
        router.get("/mixed").handler(ctx -> {
            fibonacci(30);
            List<byte[]> sink = new ArrayList<>();
            for (int i = 0; i < 100; i++) {
                sink.add(new byte[4096]);
            }
            vertx.executeBlocking(promise -> {
                try { Thread.sleep(50 + RNG.nextInt(100)); }
                catch (InterruptedException e) { Thread.currentThread().interrupt(); }
                promise.complete();
            }, false, ar -> ctx.response().end("mixed work done"));
        });

        // --- Enterprise simulation handlers ---
        new RedisSimHandler().register(router);
        new DatabaseSimHandler().register(router, vertx);
        new CsvProcessingHandler().register(router, vertx);
        new SerializationHandler().register(router);
        new HttpClientSimHandler().register(router, vertx);
        new BatchProcessingHandler().register(router, vertx);

        vertx.createHttpServer()
             .requestHandler(router)
             .listen(8080)
             .onSuccess(s -> System.out.println("Vert.x HTTP server started on port 8080"));
    }

    private long fibonacci(int n) {
        if (optimized) return fibonacciIterative(n);
        if (n <= 1) return n;
        return fibonacci(n - 1) + fibonacci(n - 2);
    }

    private long fibonacciIterative(int n) {
        if (n <= 1) return n;
        long[] fib = new long[n + 1];
        fib[0] = 0;
        fib[1] = 1;
        for (int i = 2; i <= n; i++) {
            fib[i] = fib[i - 1] + fib[i - 2];
        }
        return fib[n];
    }

    private void simulateDatabaseWork() {
        // Simulate sorting a large dataset (CPU + alloc)
        List<String> data = new ArrayList<>();
        for (int i = 0; i < 50_000; i++) {
            data.add("row-" + RNG.nextInt(100_000));
        }
        data.sort(String::compareTo);

        // Simulate I/O latency
        try { Thread.sleep(30 + RNG.nextInt(70)); }
        catch (InterruptedException e) { Thread.currentThread().interrupt(); }
    }
}
