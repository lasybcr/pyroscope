package com.example.handlers;

import io.vertx.ext.web.Router;
import io.vertx.ext.web.RoutingContext;

import java.io.*;
import java.util.Map;
import java.util.concurrent.ConcurrentHashMap;
import java.util.regex.Pattern;

public class RedisSimHandler {

    private final ConcurrentHashMap<String, byte[]> store = new ConcurrentHashMap<>();

    public void register(Router router) {
        router.get("/redis/set").handler(this::handleSet);
        router.get("/redis/get").handler(this::handleGet);
        router.get("/redis/scan").handler(this::handleScan);
    }

    private void handleSet(RoutingContext ctx) {
        String key = ctx.queryParams().get("key");
        if (key == null) key = "key-" + System.nanoTime();
        String value = ctx.queryParams().get("value");
        if (value == null) value = "data-" + Math.random();

        byte[] serialized = serialize(value);
        store.put(key, serialized);
        ctx.response().end("SET " + key + " (" + serialized.length + " bytes)");
    }

    private void handleGet(RoutingContext ctx) {
        String key = ctx.queryParams().get("key");
        if (key == null) key = "key-0";
        byte[] data = store.get(key);
        if (data == null) {
            ctx.response().end("(nil)");
            return;
        }
        String value = deserialize(data);
        ctx.response().end("GET " + key + " = " + value);
    }

    private void handleScan(RoutingContext ctx) {
        String pattern = ctx.queryParams().get("pattern");
        if (pattern == null) pattern = "key-.*";
        Pattern compiled = Pattern.compile(pattern);

        int matches = 0;
        for (Map.Entry<String, byte[]> entry : store.entrySet()) {
            if (compiled.matcher(entry.getKey()).matches()) {
                deserialize(entry.getValue());
                matches++;
            }
        }
        ctx.response().end("SCAN matched " + matches + " keys");
    }

    private byte[] serialize(Object obj) {
        try {
            ByteArrayOutputStream bos = new ByteArrayOutputStream();
            ObjectOutputStream oos = new ObjectOutputStream(bos);
            oos.writeObject(obj);
            oos.flush();
            return bos.toByteArray();
        } catch (IOException e) {
            return new byte[0];
        }
    }

    private String deserialize(byte[] data) {
        try {
            ByteArrayInputStream bis = new ByteArrayInputStream(data);
            ObjectInputStream ois = new ObjectInputStream(bis);
            return ois.readObject().toString();
        } catch (Exception e) {
            return "(error)";
        }
    }
}
