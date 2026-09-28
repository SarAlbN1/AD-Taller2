# Guia del proyecto: que se hizo, por que, y como verlo

Documento de trabajo. No va dentro de `Taller-DW.zip`, es para que revises el entregable y puedas
defender cada decision.

---

## Parte 1. Como correrlo para revisarlo

### Si los contenedores ya estan arriba

Verifica primero:

```
cd /Users/sara/Downloads/Taller2/TALLER_DW_DASHBOARD
docker compose ps
```

Deben aparecer los cuatro: `postgres_server`, `clickhouse_server`, `taller_jupyter`, `superset`,
todos en estado `running`.

Abre en el navegador:

- Jupyter: http://localhost:8888/lab?token=taller_dw
- Superset: http://localhost:8088 (usuario `admin`, clave `admin`)

En Jupyter, el notebook esta en `work/taller_clickhouse.ipynb` y ya trae todas las salidas guardadas,
asi que lo puedes leer completo sin ejecutar nada.

### Si estan apagados (arranque en frio)

```
cd /Users/sara/Downloads/Taller2/TALLER_DW_DASHBOARD
docker compose up -d --build
```

Espera unos 2 minutos. Jupyter instala los requirements al arrancar y Superset corre las migraciones
de su base de metadatos. Para saber cuando esta listo Superset:

```
curl -s -o /dev/null -w "%{http_code}\n" http://localhost:8088/health
```

Cuando responda `200`, ya puedes entrar.

### Si quieres probar que todo funciona desde cero

Esto borra los volumenes y vuelve a cargar todo. Sirve para comprobar que el entregable levanta en
una maquina limpia, que es lo que va a hacer el profesor:

```
docker compose down -v
docker compose up -d --build
```

Despues abre el notebook y dale `Run All`. Tarda unos 2 minutos, casi todo en el insert de las 100
millones de filas del benchmark. Si Superset queda sin dashboard, lo importas: Settings, Import
Dashboards, seleccionas `superset/dashboard_taller2.zip`, y cuando pida la clave de la base pones
`admin123`.

### Para apagar

```
docker compose down       # apaga pero conserva los datos
docker compose down -v    # apaga y borra los datos
```

---

## Parte 2. Que se hizo en cada punto y por que

### 1. Base de datos transaccional (PostgreSQL)

**Que se hizo.** El taller entrega `02_sample_data.sql` con los datos, pero no el esquema. Habia que
deducir el DDL a partir de los INSERT. El resultado esta en `postgresql/init/01_schema.sql`.

**Por que asi.**

Las tablas cuyos INSERT no traen el id (categories, employees, shippers, suppliers, products, orders)
usan `SERIAL`, porque si el id no viene en el INSERT, la base lo tiene que generar. `customers` es la
excepcion: trae su propio `customer_id` de texto (C0001, C0002), asi que es `VARCHAR(10)` como llave
primaria.

Los tipos salieron de mirar los datos reales, no de adivinar. Por ejemplo `discount` es `REAL` con
`CHECK (discount >= 0 AND discount <= 1)` porque los valores van de 0 a 0.15, y `unit_price` es
`NUMERIC(10,2)` porque es plata y con `FLOAT` se acumularian errores de redondeo.

Las llaves foraneas se pusieron todas porque el enunciado pide un modelo transaccional, y en un OLTP
la integridad referencial es justamente el punto. El orden de las tablas en el archivo respeta esas
llaves: primero las que no dependen de nadie, despues las que referencian.

Los indices sobre `order_date`, `customer_id`, `employee_id`, `product_id` y `category_id` son las
columnas por las que filtran y cruzan las consultas del taller.

**Como verlo.**

```
docker exec postgres_server psql -U lab_user -d retail_db -c "\dt"
```

Deben salir 13 tablas, que son exactamente las 13 que lista el enunciado en el punto 1.4.

```
docker exec postgres_server psql -U lab_user -d retail_db -c "SELECT count(*) FROM orders;"
```

2000 ordenes. Tambien hay 5906 lineas en `order_details`, 500 productos y 40 clientes.

En el notebook, las secciones 1.4 a 1.7 muestran el listado de tablas, los primeros 10 clientes, una
consulta por cada una de las 13 tablas, y el JOIN de ordenes con clientes y empleados.

### 2. ClickHouse y su rendimiento

**Que se hizo.** El esquema de `analytics` quedo en `clickhouse/init/01_schema.sql`, que el contenedor
ejecuta solo la primera vez que arranca. Ademas se corrio el benchmark de 100 millones de filas.

**Por que asi.**

El esquema va en `init` y no en el notebook porque el enunciado lo pide explicitamente en el punto 3.3,
y porque tiene sentido: la estructura del warehouse es parte de la infraestructura, no del pipeline. Si
alguien levanta el proyecto en otra maquina, las tablas existen antes de que el notebook corra.

Todas las tablas usan `MergeTree`. El `ORDER BY` no es un orden de salida, es el indice primario: define
como quedan fisicamente ordenadas las filas en disco. El `PARTITION BY` crea un directorio por particion,
lo que permite descartar particiones enteras sin leerlas.

**Como verlo.** Los numeros del benchmark estan en el notebook, seccion 2.3:

- 100 millones de filas insertadas en 6.63 segundos
- una agregacion con GROUP BY sobre esas 100 millones en 0.1343 segundos
- un `count()` con filtro, variando el filtro de mil a cien millones de filas: entre 0.002 y 0.005
  segundos, practicamente igual

Ese ultimo resultado es el importante y es el que hay que saber explicar. El tiempo no crece porque
`usuario_id` es la primera columna del `ORDER BY`, entonces el motor usa las marcas del indice para
saltar bloques completos de 8192 filas que no cumplen la condicion (eso se llama data skipping), y
ademas solo lee esa columna del disco, no la fila entera.

Si quieres ver la compresion columnar con numeros:

```
docker exec clickhouse_server clickhouse-client -u admin --password admin123 -q \
"SELECT name, formatReadableSize(sum(data_compressed_bytes)) AS comprimido,
        formatReadableSize(sum(data_uncompressed_bytes)) AS sin_comprimir
 FROM system.columns WHERE database='analytics' AND table='benchmark_eventos'
 GROUP BY name FORMAT PrettyCompact"
```

Sale algo asi: `usuario_id` ocupa 3.39 MiB comprimido contra 381 MiB sin comprimir. `evento_ts` en cambio
ocupa 293 MiB, porque son timestamps casi todos distintos y comprimen mal. Esa diferencia es exactamente
lo que explica el enunciado cuando habla de que los datos homogeneos de una columna comprimen mejor.

### 3. Esquema de analitica (estrella)

**Que se hizo.** Dos tablas: `fact_sales` (hechos) y `dim_tiempo` (dimension). La dimension se llena con
pandas y PyArrow, y la tabla de hechos con un pipeline por lotes desde PostgreSQL.

**Por que asi.**

La medida es `subtotal_por_producto = quantity * (unit_price - discount)`. Esa formula se ve rara porque
`discount` es una fraccion (0 a 0.15) y lo natural seria `unit_price * (1 - discount)`. Pero es la formula
que trae el enunciado, y la comprobe antes de programarla: con `unit_price - discount` el total da
593196.00, que es exactamente la suma de la tabla de resultados esperados del enunciado. Con la otra
formula daria 579179.10 y no cuadraria. Si el profesor pregunta, esa es la respuesta: se siguio el
enunciado y se verifico contra el resultado esperado.

`dim_tiempo_id` es el unix timestamp en segundos, tal como lo pide el punto 3.1. Eso permite que el JOIN
entre hechos y dimension sea sobre un entero, que es lo mas barato posible.

El pipeline procesa de a 10000 filas con `stream_results=True` en vez de traer todo de una. Con 5906 filas
no hace diferencia, pero es el patron correcto: si la tabla tuviera millones de filas, traerlas todas a
memoria reventaria el notebook. Las transformaciones se hacen con `pyarrow.compute` y no con pandas porque
son operaciones vectorizadas en C++ sobre memoria columnar, que es justo lo que el enunciado explica sobre
Arrow y el zero-copy hacia ClickHouse.

Antes de cargar, el notebook hace `TRUNCATE` de las tablas. Eso es para que se pueda correr varias veces
seguidas sin duplicar los datos. Sin eso, un segundo `Run All` dejaria 11812 filas en vez de 5906 y los
totales saldrian al doble.

**Como verlo.**

```
docker exec clickhouse_server clickhouse-client -u admin --password admin123 -q \
"SELECT count(), round(sum(subtotal_por_producto),2) FROM analytics.fact_sales"
```

Debe dar 5906 filas y 593196 de total.

El resultado que pide el analista:

```
docker exec clickhouse_server clickhouse-client -u admin --password admin123 -q \
"SELECT t.dia_semana, round(sum(f.subtotal_por_producto),2) AS total
 FROM analytics.fact_sales f
 JOIN analytics.dim_tiempo t ON t.dim_tiempo_id = f.dim_tiempo_id
 GROUP BY t.dia_semana ORDER BY t.dia_semana FORMAT PrettyCompact"
```

El dia 0 es lunes y el 6 es domingo, que es la convencion de `dayofweek` de pandas. Los valores tienen que
coincidir uno a uno con la tabla del enunciado.

Y la estructura fisica en disco, que el enunciado pide comprobar:

```
docker exec clickhouse_server ls /var/lib/clickhouse/data/analytics/fact_sales
```

Salen dos directorios, uno por mes (202601 y 202602), porque la tabla esta particionada por mes y los datos
solo cubren enero y febrero de 2026. Si entras a uno de esos directorios veras `data.bin` con los datos,
`data.cmrk3` con las marcas del indice y `primary.cidx` con el indice primario.

### 4. Dashboard en Superset

**Que se hizo.** Tres datasets (dos fisicos y uno virtual) y cinco charts dentro de un dashboard llamado
"Dashboard Total Ventas".

**Por que asi.**

El dataset virtual es el JOIN de `fact_sales` con `dim_tiempo`. Es virtual y no una tabla nueva porque no
duplica datos: es solo una consulta guardada que Superset ejecuta contra ClickHouse cada vez. Funciona como
una vista. Si fuera una tabla fisica habria que mantenerla sincronizada cada vez que entren ventas nuevas.

Los dias de la semana se convierten a texto con `multiIf` dentro del dataset virtual, y con un numero
adelante (`1 Lunes`, `2 Martes`). El numero es para que el eje del chart quede ordenado de lunes a domingo;
si fueran solo los nombres, Superset los ordenaria alfabeticamente y quedaria Domingo, Jueves, Lunes.

El chart principal es el que pide el punto 4.5: barras apiladas, eje x `dia_semana`, metrica
`SUM(subtotal_por_producto)` y dimension `mes`. Los otros cuatro son el total por dia de la semana, la
linea de ventas por dia, una tabla y un big number con el total del periodo.

**Como verlo.** Entra a http://localhost:8088 con `admin` / `admin` y abre el dashboard. Si quieres ver el
SQL que hay detras de cada chart, en Superset cada chart tiene la opcion "View query" en el menu de los tres
puntos.

El archivo `superset/dashboard_taller2.zip` es el export del dashboard completo. Sirve para reconstruirlo en
otra instancia sin rehacerlo a mano, y es evidencia de que el dashboard existe aunque el profesor no levante
el stack.

### 5. Ejercicios opcionales

Estan al final del notebook, en la seccion 5.

El de festivos se resuelve agregando una columna `es_festivo` a `dim_tiempo`. La razon es conceptual y vale
la pena decirla: si un festivo es un atributo del dia, va en la dimension del tiempo, no en la tabla de
hechos. Asi la pregunta nueva se responde sin tocar los hechos ni volver a correr el pipeline. Eso es
justamente para lo que sirve un esquema estrella.

El del 50% de ventas por categoria necesita la categoria del producto, que no esta en el warehouse porque
el modelo del taller solo tiene dimension de tiempo. Se trae de `retail_db` y se cruza con la agregacion de
ClickHouse. El corte se hace con la suma acumulada del porcentaje.

El de clientes similares arma una matriz de clientes por productos. Para Jaccard se usa el vector binario
(compro o no compro) y para el coseno el vector con las cantidades. Termina con un clustering jerarquico
sobre la distancia de Jaccard, que es 1 menos la similitud.

El de rentabilidad por region no se puede responder solo con el warehouse, porque la region cuelga del
empleado que atendio la orden y `fact_sales` no guarda el empleado. Se resuelve cruzando con el OLTP, y se
deja dicho que la solucion correcta seria agregar `dim_empleado_id` a la tabla de hechos y una
`dim_territorio`.

---

## Parte 3. Cosas del enunciado que no cuadraban

Estas son diferencias reales del documento del taller. Vale la pena tenerlas claras porque si el profesor
las nota, la respuesta ya esta lista.

1. El texto del enunciado dice `admin-user.html` y `default-user.html`, pero el arbol de archivos esperado
   dice `.xml`. Se uso `.xml`, porque ClickHouse en `users.d` solo lee XML.
2. El enunciado crea la tabla `eventos` y en la linea siguiente hace `INSERT INTO analytics.events`. Se uso
   `eventos` en ambos lados.
3. El punto 3.1 nombra el campo `dim_product_id` pero el codigo del punto 3.5 usa `dim_producto_id`. Se uso
   el del codigo.
4. El enunciado hace `print(res.summary)` sobre el retorno de `command()`. En la version de
   `clickhouse-connect` que se usa, `command()` no devuelve un objeto con `.summary`, asi que se imprime
   `res` directamente.
5. La formula del descuento, ya explicada arriba.

Y dos cosas que tocaron arreglar para que funcionara:

6. En `superset_init.sh`, el bloque `if/else` dentro de `superset shell` falla con `SyntaxError`. Ese shell
   es una consola interactiva de Python y no acepta bloques indentados pegados de esa forma. Se reescribio
   con sentencias de una sola linea.
7. El chart de linea no usa time grain. El dialecto `clickhouse+http` genera
   `toStartOfDay(toDateTime(fecha)) AS fecha` sobre el alias del dataset virtual y ClickHouse responde
   `Column virtual_table.fecha is not under aggregate function`. Agrupando por `fecha`, que ya es tipo
   `Date`, no hay conflicto de alias.

---

## Parte 4. Preguntas probables y como responderlas

**Por que ClickHouse y no PostgreSQL para el warehouse.**
Porque las consultas analiticas leen pocas columnas de muchas filas. En un motor por filas hay que leer la
fila completa aunque solo se necesiten dos columnas. ClickHouse guarda cada columna en un archivo aparte,
entonces lee solo lo que necesita, y como los datos de una columna son homogeneos comprimen mucho mejor.
El benchmark del notebook lo muestra con numeros.

**Que hace el ORDER BY de MergeTree.**
No es un orden de salida. Define el orden fisico de las filas en disco y con eso el indice primario disperso,
que guarda una marca cada 8192 filas. Cuando la consulta filtra por esas columnas, el motor salta bloques
enteros sin leerlos.

**Por que la dimension de tiempo se calcula en pandas y no en SQL.**
Porque se calcula una sola vez, son 365 filas, y pandas ya tiene todo resuelto (`dayofweek`, `quarter`).
Es codigo mas corto y mas claro que generar el calendario en SQL. Si fueran millones de filas la decision
seria otra.

**Por que un dataset virtual y no una tabla materializada.**
Porque no duplica datos. Es una consulta guardada que se ejecuta contra ClickHouse cuando el chart la pide.
Una tabla fisica habria que mantenerla sincronizada.

**Por que el tiempo de consulta no crece con las filas filtradas.**
Por el data skipping del indice disperso mas la lectura de una sola columna. Explicado arriba.

**De donde salio el esquema de PostgreSQL si el taller no lo dio.**
Se dedujo de los INSERT del archivo de datos: que columnas trae cada tabla, cuales generan id automatico,
que rangos tienen los valores. Y se valido cargando los datos reales sin errores de integridad.

---

## Parte 5. Checklist antes de entregar

- [ ] `docker compose down -v` y `docker compose up -d --build` levanta los cuatro contenedores sin error
- [ ] El notebook corre completo con `Run All` sin ninguna celda en rojo
- [ ] `fact_sales` tiene 5906 filas y suma 593196.00
- [ ] La tabla por dia de la semana coincide con la del enunciado
- [ ] El dashboard abre en Superset y los cinco charts muestran datos
- [ ] El zip es `Taller-DW.zip` y adentro esta la carpeta `TALLER_DW_DASHBOARD` completa
