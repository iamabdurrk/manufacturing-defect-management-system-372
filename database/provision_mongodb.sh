#!/bin/bash
set -euo pipefail

# MongoDB provisioning script for the Manufacturing Defect Management System.
#
# - Uses db_connection.txt if present (expected format: `mongosh <mongodb-uri>`)
# - Idempotent: safe to run multiple times
# - Creates collections + indexes used by the Flask backend
#
# Notes:
# - This container template uses localhost:5000 with authSource=admin by default.
# - If you change creds/port/db, ensure startup.sh updates db_connection.txt accordingly.

DB_NAME_DEFAULT="myapp"
DB_PORT_DEFAULT="5000"
DB_USER_DEFAULT="appuser"
DB_PASSWORD_DEFAULT="dbuser123"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${SCRIPT_DIR}"

# Determine a MongoDB URI from db_connection.txt (preferred) or fall back to defaults.
MONGO_URI=""
if [ -f "db_connection.txt" ]; then
  # db_connection.txt is expected to contain a single line like:
  # mongosh mongodb://user:pass@localhost:5000/myapp?authSource=admin
  # We extract the second token as the URI.
  MONGO_URI="$(awk '{print $2}' db_connection.txt | head -n 1 | tr -d '\r\n')"
fi

if [ -z "${MONGO_URI}" ]; then
  MONGO_URI="mongodb://${DB_USER_DEFAULT}:${DB_PASSWORD_DEFAULT}@localhost:${DB_PORT_DEFAULT}/${DB_NAME_DEFAULT}?authSource=admin"
fi

echo "Provisioning MongoDB schema using: ${MONGO_URI}"

# Quick connectivity check
mongosh "${MONGO_URI}" --quiet --eval 'db.runCommand({ping:1})' >/dev/null

# Create collections (idempotent)
# Note: createCollection will error if already exists, so we check first.
mongosh "${MONGO_URI}" --quiet --eval '
const collections = new Set(db.getCollectionNames());
const toCreate = [
  "users",
  "defect_types",
  "defects",
  "root_causes",
  "why_analysis",
  "corrective_actions",
  "severity_rules"
];
for (const name of toCreate) {
  if (!collections.has(name)) {
    db.createCollection(name);
    print(`created collection: ${name}`);
  } else {
    print(`collection exists: ${name}`);
  }
}
'

# Indexes
# Keep indexes minimal-but-useful for app queries + uniqueness constraints.
mongosh "${MONGO_URI}" --quiet --eval 'db.users.createIndex({email:1},{unique:true,name:"uniq_email"})'
mongosh "${MONGO_URI}" --quiet --eval 'db.users.createIndex({role:1},{name:"idx_role"})'

mongosh "${MONGO_URI}" --quiet --eval 'db.defect_types.createIndex({code:1},{unique:true,name:"uniq_code"})'

# Optional business identifier; partial unique prevents conflicts when defect_id is missing.
mongosh "${MONGO_URI}" --quiet --eval 'db.defects.createIndex({defect_id:1},{unique:true,name:"uniq_defect_id",partialFilterExpression:{defect_id:{$type:"string"}}})'

mongosh "${MONGO_URI}" --quiet --eval 'db.defects.createIndex({created_at:-1},{name:"idx_created_at"})'
mongosh "${MONGO_URI}" --quiet --eval 'db.defects.createIndex({updated_at:-1},{name:"idx_updated_at"})'
mongosh "${MONGO_URI}" --quiet --eval 'db.defects.createIndex({status:1,created_at:-1},{name:"idx_status_created"})'
mongosh "${MONGO_URI}" --quiet --eval 'db.defects.createIndex({severity:1,created_at:-1},{name:"idx_severity_created"})'
mongosh "${MONGO_URI}" --quiet --eval 'db.defects.createIndex({defect_type_id:1,created_at:-1},{name:"idx_type_created"})'

# Minimal attachments metadata support (if defects embed attachment refs)
mongosh "${MONGO_URI}" --quiet --eval 'db.defects.createIndex({"attachments.file_id":1},{name:"idx_attachments_file"})'

mongosh "${MONGO_URI}" --quiet --eval 'db.root_causes.createIndex({defect_id:1},{name:"idx_defect_id"})'
mongosh "${MONGO_URI}" --quiet --eval 'db.why_analysis.createIndex({defect_id:1},{name:"idx_defect_id"})'

mongosh "${MONGO_URI}" --quiet --eval 'db.corrective_actions.createIndex({defect_id:1},{name:"idx_defect_id"})'
mongosh "${MONGO_URI}" --quiet --eval 'db.corrective_actions.createIndex({assigned_to:1,status:1,due_date:1},{name:"idx_assignee_status_due"})'
mongosh "${MONGO_URI}" --quiet --eval 'db.corrective_actions.createIndex({due_date:1,status:1},{name:"idx_due_status"})'

mongosh "${MONGO_URI}" --quiet --eval 'db.severity_rules.createIndex({name:1},{unique:true,name:"uniq_name"})'

echo "MongoDB provisioning complete."
