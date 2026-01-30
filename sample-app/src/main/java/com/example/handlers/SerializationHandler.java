package com.example.handlers;

import io.vertx.ext.web.Router;
import io.vertx.ext.web.RoutingContext;

import java.util.*;

public class SerializationHandler {

    private final Random rng = new Random();

    public void register(Router router) {
        router.get("/json/process").handler(this::handleJson);
        router.get("/xml/process").handler(this::handleXml);
    }

    private void handleJson(RoutingContext ctx) {
        Map<String, Object> root = buildNestedMap(4);
        String json = toJson(root);
        Map<String, Object> parsed = parseJsonObject(json, new int[]{0});
        ctx.response().end("JSON: serialized " + json.length() + " chars, parsed " + parsed.size() + " keys");
    }

    private void handleXml(RoutingContext ctx) {
        Map<String, Object> root = buildNestedMap(4);
        String xml = toXml("root", root);
        int tags = countOccurrences(xml, '<');
        ctx.response().end("XML: serialized " + xml.length() + " chars, " + tags + " tags");
    }

    @SuppressWarnings("unchecked")
    private Map<String, Object> buildNestedMap(int depth) {
        Map<String, Object> map = new LinkedHashMap<>();
        for (int i = 0; i < 10; i++) {
            String key = "field_" + i;
            if (depth > 0 && i % 3 == 0) {
                map.put(key, buildNestedMap(depth - 1));
            } else if (i % 2 == 0) {
                List<String> list = new ArrayList<>();
                for (int j = 0; j < 5; j++) list.add("item-" + rng.nextInt(1000));
                map.put(key, list);
            } else {
                map.put(key, "value-" + rng.nextInt(10000));
            }
        }
        return map;
    }

    @SuppressWarnings("unchecked")
    private String toJson(Object obj) {
        StringBuilder sb = new StringBuilder();
        if (obj instanceof Map) {
            sb.append('{');
            Map<String, Object> map = (Map<String, Object>) obj;
            Iterator<Map.Entry<String, Object>> it = map.entrySet().iterator();
            while (it.hasNext()) {
                Map.Entry<String, Object> e = it.next();
                sb.append('"').append(e.getKey()).append("\":").append(toJson(e.getValue()));
                if (it.hasNext()) sb.append(',');
            }
            sb.append('}');
        } else if (obj instanceof List) {
            sb.append('[');
            List<?> list = (List<?>) obj;
            for (int i = 0; i < list.size(); i++) {
                sb.append(toJson(list.get(i)));
                if (i < list.size() - 1) sb.append(',');
            }
            sb.append(']');
        } else {
            sb.append('"').append(obj).append('"');
        }
        return sb.toString();
    }

    @SuppressWarnings("unchecked")
    private String toXml(String tag, Object obj) {
        StringBuilder sb = new StringBuilder();
        sb.append('<').append(tag).append('>');
        if (obj instanceof Map) {
            Map<String, Object> map = (Map<String, Object>) obj;
            for (Map.Entry<String, Object> e : map.entrySet()) {
                sb.append(toXml(e.getKey(), e.getValue()));
            }
        } else if (obj instanceof List) {
            List<?> list = (List<?>) obj;
            for (Object item : list) {
                sb.append(toXml("item", item));
            }
        } else {
            sb.append(obj);
        }
        sb.append("</").append(tag).append('>');
        return sb.toString();
    }

    private Map<String, Object> parseJsonObject(String json, int[] pos) {
        Map<String, Object> map = new LinkedHashMap<>();
        pos[0]++; // skip {
        while (pos[0] < json.length() && json.charAt(pos[0]) != '}') {
            if (json.charAt(pos[0]) == ',' || json.charAt(pos[0]) == ' ') { pos[0]++; continue; }
            String key = parseJsonString(json, pos);
            pos[0]++; // skip :
            Object value = parseJsonValue(json, pos);
            map.put(key, value);
        }
        if (pos[0] < json.length()) pos[0]++; // skip }
        return map;
    }

    private Object parseJsonValue(String json, int[] pos) {
        char c = json.charAt(pos[0]);
        if (c == '{') return parseJsonObject(json, pos);
        if (c == '[') return parseJsonArray(json, pos);
        return parseJsonString(json, pos);
    }

    private List<Object> parseJsonArray(String json, int[] pos) {
        List<Object> list = new ArrayList<>();
        pos[0]++; // skip [
        while (pos[0] < json.length() && json.charAt(pos[0]) != ']') {
            if (json.charAt(pos[0]) == ',') { pos[0]++; continue; }
            list.add(parseJsonValue(json, pos));
        }
        if (pos[0] < json.length()) pos[0]++; // skip ]
        return list;
    }

    private String parseJsonString(String json, int[] pos) {
        if (pos[0] >= json.length() || json.charAt(pos[0]) != '"') return "";
        pos[0]++; // skip opening "
        StringBuilder sb = new StringBuilder();
        while (pos[0] < json.length() && json.charAt(pos[0]) != '"') {
            sb.append(json.charAt(pos[0]++));
        }
        if (pos[0] < json.length()) pos[0]++; // skip closing "
        return sb.toString();
    }

    private int countOccurrences(String s, char c) {
        int count = 0;
        for (int i = 0; i < s.length(); i++) {
            if (s.charAt(i) == c) count++;
        }
        return count;
    }
}
