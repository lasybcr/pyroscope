package com.example.handlers;

import io.vertx.core.Vertx;
import io.vertx.ext.web.Router;
import io.vertx.ext.web.RoutingContext;

import java.util.ArrayList;
import java.util.List;
import java.util.Random;
import java.util.regex.Pattern;

public class BatchProcessingHandler {

    private final Random rng = new Random();
    private static final Pattern EMAIL_PATTERN = Pattern.compile("^[\\w.+-]+@[\\w.-]+\\.[a-zA-Z]{2,}$");
    private static final Pattern PHONE_PATTERN = Pattern.compile("^\\+?\\d{10,15}$");

    public void register(Router router, Vertx vertx) {
        router.get("/batch/process").handler(ctx -> vertx.executeBlocking(promise -> {
            handleBatch(ctx);
            promise.complete();
        }, false, ar -> {}));
    }

    private void handleBatch(RoutingContext ctx) {
        int totalRecords = 50000;
        int chunkSize = 1000;
        int validCount = 0;
        double totalScore = 0.0;

        List<String> records = new ArrayList<>(totalRecords);
        for (int i = 0; i < totalRecords; i++) {
            records.add(generateRecord(i));
        }

        for (int offset = 0; offset < totalRecords; offset += chunkSize) {
            int end = Math.min(offset + chunkSize, totalRecords);
            for (int i = offset; i < end; i++) {
                String record = records.get(i);
                String[] parts = record.split("\\|");
                if (parts.length < 4) continue;

                boolean emailValid = EMAIL_PATTERN.matcher(parts[1]).matches();
                boolean phoneValid = PHONE_PATTERN.matcher(parts[2]).matches();

                if (emailValid && phoneValid) {
                    validCount++;
                    double score = computeScore(parts[3]);
                    totalScore += score;
                }
            }
        }

        double avgScore = validCount > 0 ? totalScore / validCount : 0;
        ctx.response().end(String.format("Batch: %d records, %d valid, avg score=%.4f", totalRecords, validCount, avgScore));
    }

    private String generateRecord(int id) {
        return id + "|user" + id + "@example.com|+" + (10000000000L + rng.nextInt(Integer.MAX_VALUE)) + "|" +
               rng.nextDouble() + "," + rng.nextDouble() + "," + rng.nextDouble();
    }

    private double computeScore(String data) {
        String[] vals = data.split(",");
        double score = 0;
        for (String v : vals) {
            double d = Double.parseDouble(v);
            score += Math.sin(d) * Math.cos(d) + Math.sqrt(Math.abs(d));
        }
        return score / vals.length;
    }
}
