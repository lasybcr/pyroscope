package com.example.handlers;

import io.vertx.core.CompositeFuture;
import io.vertx.core.Future;
import io.vertx.core.Promise;
import io.vertx.core.Vertx;
import io.vertx.ext.web.Router;
import io.vertx.ext.web.RoutingContext;

import java.util.ArrayList;
import java.util.List;
import java.util.Random;

public class HttpClientSimHandler {

    private final Random rng = new Random();

    public void register(Router router, Vertx vertx) {
        router.get("/downstream/call").handler(ctx -> {
            vertx.executeBlocking(promise -> {
                simulateDownstreamCall();
                promise.complete("response-" + rng.nextInt(10000));
            }, false, ar -> ctx.response().end("downstream call: " + ar.result()));
        });

        router.get("/downstream/fanout").handler(ctx -> {
            List<Future> futures = new ArrayList<>();
            int fanoutCount = 3 + rng.nextInt(5);
            for (int i = 0; i < fanoutCount; i++) {
                Promise<String> p = Promise.promise();
                int idx = i;
                vertx.executeBlocking(promise -> {
                    simulateDownstreamCall();
                    promise.complete("svc-" + idx + ":ok");
                }, false, ar -> p.complete((String) ar.result()));
                futures.add(p.future());
            }
            CompositeFuture.all(futures).onComplete(ar ->
                ctx.response().end("fanout to " + fanoutCount + " services: " +
                    (ar.succeeded() ? "all ok" : "partial failure"))
            );
        });
    }

    private void simulateDownstreamCall() {
        // Simulate varying downstream latency
        int latency = 20 + rng.nextInt(200);
        try {
            Thread.sleep(latency);
        } catch (InterruptedException e) {
            Thread.currentThread().interrupt();
        }
        // Simulate response parsing
        StringBuilder sb = new StringBuilder();
        for (int i = 0; i < 1000; i++) {
            sb.append("field-").append(i).append(":value-").append(rng.nextInt(10000)).append(';');
        }
        sb.toString().split(";");
    }
}
