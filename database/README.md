# Database (MongoDB) container

This container provides MongoDB provisioning scripts (collections, indexes, and minimal seed data) used by the backend API.

## Environment variables

Provisioning expects:

- `MONGODB_URL` — MongoDB connection string
- `MONGODB_DB` — database name

If those are not set, `provision_mongodb.sh` will attempt to read `db_connection.txt` (if present) containing a line like:

```bash
mongosh "mongodb://user:pass@host:27017"
```

## Scripts

- `provision_mongodb.sh`
  - Idempotently creates collections:
    - `users`, `defect_types`, `severity_rules`, `defects`, `root_causes`, `corrective_actions`, `uploads`
  - Creates indexes to support:
    - authentication (unique email)
    - defect lists and analytics filters (created_at, line/part/type/status/severity)
    - RCA upsert by defect_id
    - overdue actions queries (status + due_date)
    - uploads lookup by file_id
  - Seeds minimal lookup data:
    - several `defect_types`
    - default global `severity_rules`
    - a placeholder admin user (`admin@example.com`) if missing

- `startup.sh`
  - Runs provisioning then starts `db_visualizer` (if bundled)

## Notes

- This repository does **not** assume GridFS; uploads are tracked in an `uploads` metadata collection. If the backend uses GridFS later, this can be extended.
- The default seeded admin user does **not** include a real password hash; backend auth should manage hashing on signup/login.
