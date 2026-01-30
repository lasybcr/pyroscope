package com.example.handlers;

import io.vertx.core.Vertx;
import io.vertx.ext.web.Router;
import io.vertx.ext.web.RoutingContext;

import java.util.*;
import java.util.stream.Collectors;

public class DatabaseSimHandler {

    private final List<Map<String, String>> usersTable = new ArrayList<>();
    private final List<Map<String, String>> ordersTable = new ArrayList<>();
    private final Random rng = new Random();

    public DatabaseSimHandler() {
        for (int i = 0; i < 5000; i++) {
            Map<String, String> user = new HashMap<>();
            user.put("id", String.valueOf(i));
            user.put("name", "user-" + i);
            user.put("region", "region-" + (i % 10));
            usersTable.add(user);

            Map<String, String> order = new HashMap<>();
            order.put("id", String.valueOf(i));
            order.put("user_id", String.valueOf(rng.nextInt(5000)));
            order.put("amount", String.valueOf(10 + rng.nextInt(990)));
            order.put("status", rng.nextBoolean() ? "completed" : "pending");
            ordersTable.add(order);
        }
    }

    public void register(Router router, Vertx vertx) {
        router.get("/db/select").handler(ctx -> vertx.executeBlocking(promise -> {
            handleSelect(ctx);
            promise.complete();
        }, false, ar -> {}));

        router.get("/db/insert").handler(ctx -> vertx.executeBlocking(promise -> {
            handleInsert(ctx);
            promise.complete();
        }, false, ar -> {}));

        router.get("/db/join").handler(ctx -> vertx.executeBlocking(promise -> {
            handleJoin(ctx);
            promise.complete();
        }, false, ar -> {}));
    }

    private void handleSelect(RoutingContext ctx) {
        String region = ctx.queryParams().get("region");
        if (region == null) region = "region-" + rng.nextInt(10);

        String filterRegion = region;
        List<Map<String, String>> results = usersTable.stream()
                .filter(u -> filterRegion.equals(u.get("region")))
                .sorted(Comparator.comparing(u -> u.get("name")))
                .collect(Collectors.toList());

        ctx.response().end("SELECT returned " + results.size() + " rows");
    }

    private synchronized void handleInsert(RoutingContext ctx) {
        Map<String, String> row = new HashMap<>();
        row.put("id", String.valueOf(usersTable.size()));
        row.put("name", "user-" + System.nanoTime());
        row.put("region", "region-" + rng.nextInt(10));
        usersTable.add(row);
        ctx.response().end("INSERT 1 row (total=" + usersTable.size() + ")");
    }

    private void handleJoin(RoutingContext ctx) {
        int limit = 200;
        int joined = 0;
        StringBuilder sb = new StringBuilder();

        for (Map<String, String> user : usersTable) {
            for (Map<String, String> order : ordersTable) {
                if (user.get("id").equals(order.get("user_id"))) {
                    sb.append(user.get("name")).append(':').append(order.get("amount")).append(',');
                    joined++;
                    if (joined >= limit) break;
                }
            }
            if (joined >= limit) break;
        }

        ctx.response().end("JOIN produced " + joined + " rows (" + sb.length() + " bytes)");
    }
}
