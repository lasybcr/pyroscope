# Postman Collection

Import both files into Postman:

1. **Collection:** `pyroscope-demo.postman_collection.json`
2. **Environment:** `pyroscope-demo.postman_environment.json`

Select the "Pyroscope Demo — Local" environment, then explore the folders:

- **Health & Metrics** — verify all services are up
- **MainVerticle** — all workload endpoints (Redis, DB, CSV, JSON/XML, HTTP client, batch)
- **OrderVerticle** — order CRUD, processing, fulfillment
- **Pyroscope API** — list profiles, render flame graph data
- **Prometheus API** — query JVM metrics
- **Grafana API** — list datasources, dashboards

Use the Postman Runner to execute all requests in sequence for a quick smoke test.
