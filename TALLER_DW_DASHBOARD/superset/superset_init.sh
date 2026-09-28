#!/bin/bash
set -e

superset db upgrade

# el || true es porque si el volumen ya existe, el admin tambien y falla
superset fab create-admin \
  --username admin \
  --firstname Admin \
  --lastname User \
  --email admin@superset.com \
  --password admin || true

superset init

# registra la conexion a clickhouse. superset shell es una consola interactiva,
# por eso va todo en sentencias de una linea y sin if/else, si no da SyntaxError
superset shell <<PY
from superset import db
from superset.models.core import Database
uri = "clickhouse+http://admin:admin123@clickhouse_server:8123/analytics"
registro = db.session.query(Database).filter_by(database_name="ClickHouse").first() or Database(database_name="ClickHouse")
registro.sqlalchemy_uri = uri
db.session.add(registro)
db.session.commit()
print("ClickHouse database registrada:", registro.id, registro.sqlalchemy_uri)
PY

superset run -h 0.0.0.0 -p 8088
