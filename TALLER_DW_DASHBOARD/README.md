# Taller 2. Data Warehouse y Dashboard

El taller monta el flujo completo: los datos transaccionales viven en PostgreSQL, un notebook de Jupyter
los extrae y los transforma con PyArrow, los carga en ClickHouse como esquema estrella, y Superset arma
el dashboard encima de esas tablas.

Pregunta del analista de negocio: cuanto se factura por dia de la semana, para decidir si se contrata
publicidad los fines de semana.

## Como levantarlo

```
podman machine start
podman compose up -d --build
```

Si se usa Docker es el mismo compose:

```
docker compose up -d --build
```

La primera vez demora un poco porque Jupyter instala los requirements al arrancar y Superset corre las
migraciones de su base de metadatos.

Accesos:

- Jupyter: http://localhost:8888 con el token `taller_dw`
- Superset: http://localhost:8088 con usuario `admin` y clave `admin`
- ClickHouse: http://localhost:8123 con usuario `admin` y clave `admin123`
- PostgreSQL: `localhost:5432`, base `retail_db`, usuario `lab_user`, clave `lab_pass`

El notebook `notebooks/taller_clickhouse.ipynb` se corre de arriba a abajo. Antes de cargar hace TRUNCATE
de dim_tiempo, fact_sales y benchmark_eventos, asi que se puede ejecutar varias veces sin duplicar datos.

## Estructura

```
TALLER_DW_DASHBOARD
│   compose.yaml
│   README.md
│
├───clickhouse
│   ├───config
│   │        admin-user.xml
│   │        default-user.xml
│   └───init
│            01_schema.sql
│            02_sample_data.sql
│
├───notebooks
│       taller_clickhouse.ipynb
│       requirements.txt
│
├───postgresql
│   │   Dockerfile
│   └───init
│            01_schema.sql
│            02_sample_data.sql
│
└───superset
        Dockerfile
        requirements.txt
        superset_init.sh
        dashboard_taller2.zip
```

## 1. Base de datos transaccional

El archivo `postgresql/init/01_schema.sql` tiene el DDL de las 13 tablas de retail_db. Escribi el esquema
a partir de los INSERT del archivo de datos: las tablas que no traen id en el INSERT (categories, employees,
shippers, suppliers, products, orders) usan SERIAL, y customers trae su propio customer_id de texto.

Estan las llaves foraneas de orders hacia customers, employees y shippers, de order_details hacia orders y
products, de products hacia suppliers y categories, y de territories hacia region. Tambien las dos tablas
puente de muchos a muchos (employee_territories y customer_customer_demo). Agregue indices sobre order_date,
customer_id, employee_id, product_id y category_id porque son las columnas por las que filtran y cruzan las
consultas del taller.

Lo que queda cargado: 40 clientes, 20 empleados, 10 categorias, 10 transportadores, 20 proveedores,
20 regiones, 5 territorios, 500 productos, 2000 ordenes y 5906 lineas de detalle, con fechas entre el
1 de enero y el 28 de febrero de 2026.

Las consultas de los puntos 1.4 a 1.7 estan en el notebook: listado de tablas, los primeros 10 clientes,
una consulta por cada tabla, y el JOIN de orders con customers y employees mostrando el flete.

## 2. ClickHouse

El esquema de analytics esta en `clickhouse/init/01_schema.sql` y se ejecuta al crear el contenedor. Todas
las tablas usan MergeTree. El ORDER BY es el indice primario disperso y el PARTITION BY define los directorios
en disco.

Los tiempos que me dieron al correr el benchmark de la seccion 2.3:

- Insertar 100 millones de filas: 6.63 segundos
- GROUP BY producto_id con count y avg sobre esas 100 millones: 0.1343 segundos
- count con WHERE usuario_id menor a N, con N entre mil y cien millones: entre 0.002 y 0.005 segundos

Lo interesante es lo ultimo: el tiempo casi no cambia aunque el filtro pase de mil a cien millones de filas.
Como usuario_id es la primera columna del ORDER BY, el motor salta los bloques de 8192 filas que no cumplen
la condicion y solo lee esa columna del disco.

## 3. Esquema de analitica

Es un esquema estrella con una dimension:

```
dim_tiempo (365 filas de 2026)              fact_sales (5906 filas)
  dim_tiempo_id  Int64  <-------------------  dim_tiempo_id          Int64
  fecha          Date                         dim_orden_id           UInt32
  dia_semana     UInt8 (0 lunes a 6 domingo)  dim_producto_id        UInt32
  dia, mes, trimestre, semestre, year         subtotal_por_producto  Float64
```

El pipeline de la seccion 3.5 va por lotes de 10000 filas leyendo en streaming desde PostgreSQL. De cada
lote arma una tabla Arrow, calcula dim_tiempo_id convirtiendo order_date a timestamp unix y calcula la
medida como quantity por (unit_price menos discount), y carga con insert_arrow.

El resultado que pide el analista:

```
Domingo     81015.46
Lunes       76077.14
Martes      85900.86
Miercoles   71262.40
Jueves      96000.93
Viernes     88109.91
Sabado      94829.30
                       total 593196.00
```

Jueves y sabado son los dias mas fuertes y miercoles el mas flojo. Sabado y domingo juntos suman 175844.76,
mas que cualquier par de dias seguidos de la parte baja de la semana, asi que la publicidad de fin de semana
si se sostiene con estos numeros.

## 4. Dashboard en Superset

El contenedor deja registrada la conexion a ClickHouse al arrancar, con la URI
`clickhouse+http://admin:admin123@clickhouse_server:8123/analytics`.

Datasets:

- fact_sales, fisico, con la metrica total_ventas definida como SUM(subtotal_por_producto)
- dim_tiempo, fisico
- vw_ventas_por_tiempo, virtual, que es el JOIN de las dos anteriores

El SQL del dataset virtual:

```sql
SELECT
    t.fecha AS fecha, t.year AS year, t.semestre AS semestre, t.trimestre AS trimestre,
    t.mes AS mes, t.dia AS dia,
    multiIf(t.dia_semana = 0, '1 Lunes',
            t.dia_semana = 1, '2 Martes',
            t.dia_semana = 2, '3 Miercoles',
            t.dia_semana = 3, '4 Jueves',
            t.dia_semana = 4, '5 Viernes',
            t.dia_semana = 5, '6 Sabado',
                              '7 Domingo') AS dia_semana,
    f.dim_orden_id AS dim_orden_id,
    f.dim_producto_id AS dim_producto_id,
    f.subtotal_por_producto AS subtotal_por_producto
FROM analytics.fact_sales f
JOIN analytics.dim_tiempo t ON t.dim_tiempo_id = f.dim_tiempo_id
```

Los charts del dashboard "Dashboard Total Ventas":

1. Barras apiladas con x-axis dia_semana, metrica SUM(subtotal_por_producto) y dimension mes, que es el que
   pide el punto 4.5
2. Barras con el total por dia de la semana
3. Linea de ventas totales por dia
4. Tabla con la facturacion por dia de la semana
5. Big number con el total del periodo, 593196.00

Si el dashboard hay que reconstruirlo en otra instancia: Dashboards, Import, y se selecciona
`superset/dashboard_taller2.zip`. Pide la clave de la base ClickHouse, que es admin123. Lo probe sobre una
instancia limpia (despues de `compose down -v`) y reconstruye la conexion, los tres datasets, los cinco charts
y el layout.

Dos cosas que me tocaron ajustar frente a lo que trae el enunciado:

En `superset_init.sh`, el bloque con if/else dentro de `superset shell` falla con SyntaxError porque ese shell
es una consola interactiva de Python y no acepta bloques indentados pegados asi. Lo reescribi con sentencias
de una sola linea. Tambien deje el create-admin tolerante a que el usuario ya exista, porque el volumen de
metadatos de Superset persiste entre reinicios.

En el chart de linea no use time grain. El dialecto clickhouse+http genera
`toStartOfDay(toDateTime(fecha)) AS fecha` sobre el alias del dataset virtual y ClickHouse responde
"Column virtual_table.fecha is not under aggregate function". Agrupando por fecha directamente, que ya es
tipo Date, no hay problema.

## 5. Ejercicios opcionales

Estan resueltos al final del notebook.

El de festivos lo planteo agregando una columna es_festivo a dim_tiempo, que es donde corresponde porque es
un atributo del tiempo y no de la venta. Asi la tabla de hechos no se toca y no hay que volver a correr el
pipeline.

El del 50% de las ventas por categoria necesita la categoria del producto, que no esta en el warehouse, asi
que la traigo de retail_db y la cruzo con la agregacion por producto de ClickHouse, ordeno de mayor a menor
y corto con la suma acumulada.

El de clientes similares arma la matriz de clientes por productos sobre las semanas 1 a 52, calcula Jaccard
con el vector binario y coseno con el vector de cantidades, y termina con un clustering jerarquico sobre la
distancia de Jaccard.

El de rentabilidad por region y territorio no se puede responder solo con el warehouse, porque la region
cuelga del empleado que atendio la orden. Lo resuelvo cruzando el agregado de ClickHouse con las tablas de
empleados y territorios del OLTP, y como retail_db no guarda costo, lo aproximo al 70% del precio de lista.
Para hacerlo nativo habria que agregarle dim_empleado_id a fact_sales y crear una dim_territorio.

## Comprobaciones rapidas

```
docker exec clickhouse_server clickhouse-client -u admin --password admin123 -q \
  "SELECT count(), round(sum(subtotal_por_producto),2) FROM analytics.fact_sales"

docker exec clickhouse_server ls /var/lib/clickhouse/data/analytics/fact_sales
```
