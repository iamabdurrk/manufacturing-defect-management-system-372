#!/usr/bin/env bash
set -euo pipefail

# Manufacturing Defect Management System - MongoDB provisioning
# - Creates collections
# - Creates indexes needed by backend queries
# - Seeds minimal lookup data (idempotent)
#
# Environment:
#   MONGODB_URL: Mongo connection string (preferred)
#   MONGODB_DB:  Database name (preferred)
#
# Optional:
#   db_connection.txt: If present, should contain a line like: mongosh "<connection-string>"
#                      Used as a fallback only.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Prefer env vars; fallback to db_connection.txt (per container guidance).
MONGO_URI="${MONGODB_URL:-}"
MONGO_DB="${MONGODB_DB:-}"

if [[ -z "${MONGO_URI}" || -z "${MONGO_DB}" ]]; then
  if [[ -f "${SCRIPT_DIR}/db_connection.txt" ]]; then
    # Extract the connection string inside quotes after 'mongosh'
    # e.g. mongosh "mongodb://..."
    MONGO_URI="$(awk -F'"' '/mongosh/{print $2; exit}' "${SCRIPT_DIR}/db_connection.txt" | tr -d '\r' || true)"
  fi
fi

if [[ -z "${MONGO_URI}" ]]; then
  echo "ERROR: Mongo connection string not provided."
  echo "Set MONGODB_URL (recommended) or provide ${SCRIPT_DIR}/db_connection.txt."
  exit 1
fi

if [[ -z "${MONGO_DB}" ]]; then
  echo "ERROR: Database name not provided."
  echo "Set MONGODB_DB."
  exit 1
fi

echo "Provisioning MongoDB database '${MONGO_DB}'..."

# One mongosh execution, multiple idempotent operations.
# Note: We keep it resilient: createCollection only when missing; createIndex is idempotent.
mongosh "${MONGO_URI}/${MONGO_DB}" --quiet --eval '
/**
 * Idempotent provisioning for Manufacturing Defect Management System.
 * Creates collections, indexes, and minimal seed data.
 */
const dbName = db.getName();
print(`Connected to db: ${dbName}`);

function ensureCollection(name) {
  const existing = db.getCollectionNames();
  if (!existing.includes(name)) {
    db.createCollection(name);
    print(`Created collection: ${name}`);
  } else {
    print(`Collection exists: ${name}`);
  }
}

function ensureIndex(coll, keys, options) {
  const res = db.getCollection(coll).createIndex(keys, options);
  print(`Index ensured on ${coll}: ${JSON.stringify(keys)} => ${res}`);
}

/**
 * Collections (aligned to backend API shapes in OpenAPI):
 * - users: auth (signup/login)
 * - defect_types: lookup used by defects + analytics
 * - severity_rules: lookup/rules (used by UI/backend validations)
 * - defects: main records, supports lists & analytics filters
 * - root_causes: 1 per defect_id, method + details
 * - corrective_actions: actions list + overdue queries
 * - uploads: metadata for uploaded files (GridFS not assumed)
 */
[
  "users",
  "defect_types",
  "severity_rules",
  "defects",
  "root_causes",
  "corrective_actions",
  "uploads"
].forEach(ensureCollection);

// -------------------- Indexes --------------------
// users
ensureIndex("users", { email: 1 }, { unique: true, name: "users_email_unique" });
ensureIndex("users", { role: 1 }, { name: "users_role" });

// defect_types
ensureIndex("defect_types", { name: 1 }, { unique: true, name: "defect_types_name_unique" });
ensureIndex("defect_types", { active: 1 }, { name: "defect_types_active" });

// severity_rules
ensureIndex("severity_rules", { defect_type_id: 1 }, { name: "severity_rules_defect_type" });
ensureIndex("severity_rules", { min_qty: 1, max_qty: 1 }, { name: "severity_rules_qty_range" });

// defects
// Support common list views and analytics filters: time range, line, part, type, status, severity.
ensureIndex("defects", { created_at: -1 }, { name: "defects_created_at_desc" });
ensureIndex("defects", { status: 1, created_at: -1 }, { name: "defects_status_created_at" });
ensureIndex("defects", { production_line: 1, created_at: -1 }, { name: "defects_line_created_at" });
ensureIndex("defects", { part_number: 1, created_at: -1 }, { name: "defects_part_created_at" });
ensureIndex("defects", { defect_type_id: 1, created_at: -1 }, { name: "defects_type_created_at" });
ensureIndex("defects", { severity: 1, created_at: -1 }, { name: "defects_severity_created_at" });

// root_causes (upsert by defect_id)
ensureIndex("root_causes", { defect_id: 1 }, { unique: true, name: "root_causes_defect_id_unique" });
ensureIndex("root_causes", { method: 1 }, { name: "root_causes_method" });

// corrective_actions (dashboard overdue)
ensureIndex("corrective_actions", { defect_id: 1 }, { name: "actions_defect" });
ensureIndex("corrective_actions", { owner_id: 1 }, { name: "actions_owner" });
ensureIndex("corrective_actions", { status: 1, due_date: 1 }, { name: "actions_status_due" });
ensureIndex("corrective_actions", { due_date: 1 }, { name: "actions_due_date" });

// uploads
ensureIndex("uploads", { file_id: 1 }, { unique: true, name: "uploads_file_id_unique" });
ensureIndex("uploads", { created_at: -1 }, { name: "uploads_created_at_desc" });

// -------------------- Seed data (idempotent) --------------------

// Defect types (minimal set; can be extended via app UI later)
const defectTypes = [
  { name: "Scratch", active: true },
  { name: "Dent", active: true },
  { name: "Crack", active: true },
  { name: "Discoloration", active: true },
  { name: "Misalignment", active: true }
];

defectTypes.forEach(dt => {
  db.defect_types.updateOne(
    { name: dt.name },
    { $setOnInsert: { ...dt, created_at: new Date() } },
    { upsert: true }
  );
});
print("Seeded defect_types (if missing).");

// Severity rules (generic defaults by quantity; backend can override)
// We store defect_type_id = null for global rules; can be specialized per defect_type_id later.
const severityRules = [
  { defect_type_id: null, min_qty: 1, max_qty: 1, severity: "Minor" },
  { defect_type_id: null, min_qty: 2, max_qty: 5, severity: "Major" },
  { defect_type_id: null, min_qty: 6, max_qty: null, severity: "Critical" }
];

severityRules.forEach(rule => {
  db.severity_rules.updateOne(
    { defect_type_id: rule.defect_type_id, min_qty: rule.min_qty, max_qty: rule.max_qty },
    { $setOnInsert: { ...rule, created_at: new Date() } },
    { upsert: true }
  );
});
print("Seeded severity_rules (if missing).");

// Optional: seed a default admin user (no password hash assumptions here).
// Backend should handle hashing; we only insert if a user with this email does not exist.
// If the backend enforces password presence, it will overwrite/replace on signup.
db.users.updateOne(
  { email: "admin@example.com" },
  {
    $setOnInsert: {
      name: "Admin",
      email: "admin@example.com",
      role: "admin",
      // Placeholder; backend should update to proper password hash on first login/signup flow.
      password_hash: null,
      created_at: new Date()
    }
  },
  { upsert: true }
);
print("Seeded default admin user (admin@example.com) if missing.");

print("MongoDB provisioning complete.");
'
echo "Done."
