#!/bin/bash
set -euo pipefail

# MongoDB startup + provisioning script.
# - Starts mongod (if not already running)
# - Ensures admin/app user exists
# - Writes db_connection.txt (authoritative connection string for other containers/tools)
# - Provisions collections/indexes for the defect management system

DB_NAME="myapp"
DB_USER="appuser"
DB_PASSWORD="dbuser123"
DB_PORT="5000"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${SCRIPT_DIR}"

echo "Starting MongoDB setup..."

CONN_URI="mongodb://${DB_USER}:${DB_PASSWORD}@localhost:${DB_PORT}/${DB_NAME}?authSource=admin"
CONN_CMD="mongosh ${CONN_URI}"

print_connection_help() {
    echo ""
    echo "Database: ${DB_NAME}"
    echo "Admin/App user: ${DB_USER} (password: ${DB_PASSWORD})"
    echo "Port: ${DB_PORT}"
    echo ""
    echo "To connect to the database, use:"
    if [ -f "db_connection.txt" ]; then
        cat db_connection.txt
    else
        echo "${CONN_CMD}"
    fi
    echo ""
}

write_connection_files() {
    # db_connection.txt format is intentionally:
    #   mongosh <mongodb-uri>
    # so other scripts can parse it consistently.
    echo "${CONN_CMD}" > db_connection.txt
    echo "Connection string saved to db_connection.txt"

    # Used by db_visualizer/server.js (expects MONGODB_URL + MONGODB_DB)
    cat > db_visualizer/mongodb.env << EOF
export MONGODB_URL="mongodb://${DB_USER}:${DB_PASSWORD}@localhost:${DB_PORT}/?authSource=admin"
export MONGODB_DB="${DB_NAME}"
EOF
    echo "Environment variables saved to db_visualizer/mongodb.env"
}

provision_schema() {
    # Provision collections + indexes in a separate script for clarity/idempotence.
    if [ -f "./provision_mongodb.sh" ]; then
        echo "Provisioning MongoDB collections/indexes..."
        ./provision_mongodb.sh
    else
        echo "WARNING: provision_mongodb.sh not found; skipping schema provisioning."
    fi
}

# If MongoDB is already running on target port, just ensure connection info exists and schema is provisioned.
if mongosh --port ${DB_PORT} --eval "db.adminCommand('ping')" > /dev/null 2>&1; then
    echo "MongoDB is already running on port ${DB_PORT}!"
    write_connection_files
    provision_schema
    print_connection_help
    echo "Script finished - MongoDB server already running."
    exit 0
fi

# Check if MongoDB is running on a different port; stop it to avoid confusion with the expected port.
if pgrep -x mongod > /dev/null; then
    MONGO_PID="$(pgrep -x mongod | head -n 1)"
    CURRENT_PORT="$(sudo lsof -Pan -p "${MONGO_PID}" -i 2>/dev/null | grep -o ":[0-9]*" | grep -o "[0-9]*" | head -1 || true)"

    if [ "${CURRENT_PORT:-}" = "${DB_PORT}" ]; then
        echo "MongoDB is already running on port ${DB_PORT}!"
        write_connection_files
        provision_schema
        print_connection_help
        echo "Script finished - server already running."
        exit 0
    else
        echo "MongoDB is running on different port (${CURRENT_PORT:-unknown}), stopping it..."
        sudo pkill -x mongod || true
        sleep 2
    fi
fi

# Clean up any existing socket files
sudo rm -f /tmp/mongodb-*.sock 2>/dev/null || true

# Start MongoDB server (this template starts without enabling access control; users are created for app use)
echo "Starting MongoDB server..."
nohup sudo mongod --dbpath /var/lib/mongodb --port ${DB_PORT} --bind_ip 127.0.0.1 --unixSocketPrefix /var/run/mongodb > /var/lib/mongodb/mongod.log 2>&1 &

echo "Waiting for MongoDB to start..."
sleep 5

for i in {1..15}; do
    if mongosh --port ${DB_PORT} --eval "db.adminCommand('ping')" > /dev/null 2>&1; then
        echo "MongoDB is ready!"
        break
    fi
    echo "Waiting... ($i/15)"
    sleep 2
done

# Create database and users (idempotent)
echo "Setting up database and user..."
mongosh --port ${DB_PORT} << EOF
use admin

if (db.getUser("${DB_USER}") == null) {
  db.createUser({
    user: "${DB_USER}",
    pwd: "${DB_PASSWORD}",
    roles: [
      { role: "userAdminAnyDatabase", db: "admin" },
      { role: "readWriteAnyDatabase", db: "admin" }
    ]
  });
}

use ${DB_NAME}

if (db.getUser("${DB_USER}") == null) {
  db.createUser({
    user: "${DB_USER}",
    pwd: "${DB_PASSWORD}",
    roles: [
      { role: "readWrite", db: "${DB_NAME}" }
    ]
  });
}

print("MongoDB user setup complete!");
EOF

write_connection_files
provision_schema
print_connection_help

echo "MongoDB is running in the background."
echo "You can now start your application."
