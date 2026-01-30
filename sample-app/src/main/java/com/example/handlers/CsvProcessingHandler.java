package com.example.handlers;

import io.vertx.core.Vertx;
import io.vertx.ext.web.Router;
import io.vertx.ext.web.RoutingContext;

import java.util.*;

public class CsvProcessingHandler {

    private final Random rng = new Random();

    public void register(Router router, Vertx vertx) {
        router.get("/csv/process").handler(ctx -> vertx.executeBlocking(promise -> {
            handleProcess(ctx);
            promise.complete();
        }, false, ar -> {}));
    }

    private void handleProcess(RoutingContext ctx) {
        int rows = 10000;
        StringBuilder csv = new StringBuilder("id,region,product,quantity,price\n");
        for (int i = 0; i < rows; i++) {
            csv.append(i).append(",region-").append(i % 8)
               .append(",product-").append(i % 50)
               .append(',').append(1 + rng.nextInt(100))
               .append(',').append(String.format("%.2f", 0.5 + rng.nextDouble() * 999.5))
               .append('\n');
        }

        String[] lines = csv.toString().split("\n");
        String[] headers = lines[0].split(",");

        Map<String, double[]> regionAgg = new HashMap<>();

        for (int i = 1; i < lines.length; i++) {
            String[] cols = lines[i].split(",");
            String region = cols[1];
            double qty = Double.parseDouble(cols[3]);
            double price = Double.parseDouble(cols[4]);
            double total = qty * price;

            regionAgg.computeIfAbsent(region, k -> new double[3]);
            double[] agg = regionAgg.get(region);
            agg[0] += total;
            agg[1] += qty;
            agg[2]++;
        }

        ctx.response().end("CSV processed " + (lines.length - 1) + " rows into " + regionAgg.size() + " groups");
    }
}
