-- Esquema del data warehouse analytics (ClickHouse 24.8)
-- Se ejecuta solo la primera vez que arranca el contenedor.

CREATE DATABASE IF NOT EXISTS analytics;

-- seccion 2.1, tabla de eventos de navegacion
-- el ORDER BY es el indice primario disperso y el PARTITION BY crea un directorio por dia
CREATE TABLE IF NOT EXISTS analytics.eventos
(
    evento_ts    DateTime,
    user_id      UInt64,
    session_id   String,
    evento_tipo  LowCardinality(String),
    producto_id  UInt32,
    categoria    String,
    precio       Float32
)
ENGINE = MergeTree
ORDER BY (evento_ts, user_id)
PARTITION BY toDate(evento_ts);

-- seccion 3.2, dimension de tiempo. dim_tiempo_id es el unix timestamp en segundos del dia
CREATE TABLE IF NOT EXISTS analytics.dim_tiempo
(
    dim_tiempo_id Int64,
    fecha         Date,
    dia_semana    UInt8,   -- 0 = lunes ... 6 = domingo (pandas dayofweek)
    dia           UInt8,
    mes           UInt8,
    trimestre     UInt8,
    semestre      UInt8,
    year          UInt16
)
ENGINE = MergeTree
ORDER BY (dim_tiempo_id);

-- seccion 3.3, tabla de hechos
-- la medida subtotal_por_producto es quantity * (unit_price - discount)
CREATE TABLE IF NOT EXISTS analytics.fact_sales
(
    dim_tiempo_id          Int64,
    dim_orden_id           UInt32,
    dim_producto_id        UInt32,
    subtotal_por_producto  Float64
)
ENGINE = MergeTree
ORDER BY (dim_tiempo_id, dim_orden_id, dim_producto_id)
PARTITION BY toYYYYMM(toDateTime(dim_tiempo_id));

-- seccion 2.3, tabla para el benchmark de rendimiento
CREATE TABLE IF NOT EXISTS analytics.benchmark_eventos
(
    evento_ts   DateTime,
    usuario_id  UInt32,
    producto_id UInt32,
    precio      Float32
)
ENGINE = MergeTree
PARTITION BY toDate(evento_ts)
ORDER BY (usuario_id, evento_ts);
