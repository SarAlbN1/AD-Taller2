# Resumen de lecturas — Taller 2

Tres documentos, tres niveles de abstracción sobre el mismo problema: cómo extraer valor de grandes volúmenes de datos.

| Documento | Autor / Año | Qué aporta |
|---|---|---|
| *Data Cube: A Relational Aggregation Operator* | Gray et al., Microsoft Research, 1997 | La **infraestructura**: cómo agregar datos en N dimensiones (OLAP, data warehouse) |
| *Principles of Data Mining* (3ª ed.) | Max Bramer, 2016 | Los **algoritmos**: clasificación, asociación, clustering, datos en streaming |
| *Data Science for Business* | Provost & Fawcett, 2013 | El **encuadre de negocio**: cómo convertir un problema de negocio en un problema de datos |

---

## 1. Gray et al. (1997) — El operador CUBE

### El problema
`GROUP BY` de SQL produce agregados de 0 o 1 dimensión. El análisis de datos necesita la generalización a N dimensiones. Con SQL estándar, tres cosas son difíciles o imposibles:

1. **Histogramas** — agregar sobre categorías calculadas (`GROUP BY Day(Time), Nation(lat, long)`) no está en el estándar.
2. **Roll-up / sub-totales** — requiere una UNION de N `GROUP BY` distintos.
3. **Cross-tabs (tablas cruzadas)** — una cross-tab de 6 dimensiones exige un **UNION de 64 `GROUP BY`**: 64 escaneos de la tabla, 64 sorts, y una espera larguísima. Además el optimizador no puede analizar esa expresión para optimizarla.

### La solución: CUBE y ROLLUP
Se sobrecarga `GROUP BY`:

```sql
SELECT Model, Year, Color, SUM(sales) AS Sales
FROM Sales
GROUP BY CUBE Model, Year, Color;
```

- **CUBE** genera el **conjunto potencia** (power set) de las columnas de agregación. Con N atributos hay `2^N - 1` super-agregados. Si las cardinalidades son C₁…C_N, el cubo resultante tiene `∏(Cᵢ + 1)` filas.
- **ROLLUP** es la versión asimétrica y jerárquica: solo `(v1,v2,…,vn)`, `(v1,…,ALL)`, …, `(ALL,…,ALL)`. Añade solo N filas. Útil cuando hay dependencias funcionales (día → semana → mes → año), donde un CUBE completo no tendría sentido.
- Álgebra de los operadores: `CUBE(ROLLUP) = CUBE`, `ROLLUP(GROUP BY) = ROLLUP`. Se pueden combinar en una sola sentencia.

### El valor ALL
La clave de representación: **el cubo sigue siendo una relación**. Se rellenan los super-agregados con un valor `ALL`, que semánticamente **representa el conjunto** sobre el que se agregó (`ALL(Model) = {Chevy, Ford}`), no un miembro de él.

Es un no-valor, como NULL, y contamina todo el lenguaje (operadores `=`, `<`, `IN`, catálogos, `ALL NOT ALLOWED`). Por eso se propone la **alternativa minimalista** — la que adoptó SQL Server 6.5:

- usar `NULL` en lugar de `ALL`,
- añadir la función booleana **`GROUPING()`** para distinguir un NULL real de un NULL-por-agregación.

### Clasificación de funciones de agregación ⭐
El aporte conceptual más reutilizable del paper. Para agregar `{X_ij}`:

| Tipo | Definición | Ejemplos | Coste del cubo |
|---|---|---|---|
| **Distributiva** | `F({X_ij}) = G({F(subconjuntos)})` | `COUNT`, `SUM`, `MIN`, `MAX` | Barato: se agrega sobre los agregados |
| **Algebraica** | Un resultado intermedio de **tamaño fijo M** resume el sub-agregado | `AVG` (guarda sum + count), desviación estándar, `MaxN`, centro de masa | Barato: hay que propagar el scratchpad, no el resultado final |
| **Holística** | **No existe** cota constante M para el sub-agregado | `MEDIAN`, `MODE`, `RANK` | Caro: no se conoce mejor algoritmo que el ingenuo `2^N` |

**Por qué importa:** esta taxonomía decide si un cubo se puede calcular incrementalmente y si se puede paralelizar. La combinación de resultados parciales en un sistema distribuido usa la misma lógica. En la práctica se evitan las funciones holísticas aproximándolas estadísticamente.

Algoritmos: el ingenuo llama `Iter()` `T × 2^N` veces. Lo eficiente es calcular el **core** `GROUP BY` primero y derivar los super-agregados de él, bajando una dimensión a la vez, y **agregando siempre por la dimensión de menor cardinalidad**. Interfaz de agregación definida por el usuario: `start() → next() → end()` sobre un scratchpad, más `Iter_super(&handle, &handle)` para plegar sub-agregados.

### Mantenimiento del cubo (no es lo mismo que calcularlo)
Insight sutil y práctico: `MAX` es **distributiva para SELECT e INSERT pero holística para DELETE**. Al insertar solo hay que visitar `2^N` celdas; al borrar el máximo global hay que recalcular el cubo entero. Existen jerarquías ortogonales para SELECT, INSERT y DELETE.

### Otros conceptos
- **Esquema estrella / copo de nieve (star / snowflake)**: una tabla de hechos central (`Product, Seller, Buyer, Units, Price, Office, Date`) más tablas de dimensión con sus granularidades de agregación. Las granularidades forman en realidad un **retículo (lattice), no una jerarquía pura** — las semanas no encajan en meses ni años.
- **Decoraciones**: columnas que no están en el `GROUP BY` pero dependen funcionalmente de él (`department.name`). Si el agregado no determina la decoración, el campo va NULL.

---

## 2. Bramer — *Principles of Data Mining*

530 páginas, 22 capítulos. Estructura y los puntos de mayor densidad:

### Bloque A — Fundamentos (cap. 1–2)
Datos etiquetados vs. no etiquetados → aprendizaje supervisado (clasificación, predicción numérica) vs. no supervisado (reglas de asociación, clustering). Tipos de variable (categórica / continua), limpieza, tratamiento de valores ausentes (descartar instancias vs. reemplazar por moda/media), reducción de atributos, repositorio UCI.

### Bloque B — Clasificación y árboles (cap. 3–12) — el núcleo del libro
- **Naïve Bayes** y **vecino más cercano (k-NN)**: medidas de distancia, normalización, atributos categóricos. Aprendizaje *eager* vs. *lazy*.
- **TDIDT** (Top-Down Induction of Decision Trees): el algoritmo base.
- **Selección de atributos** — el tema central. Se comparan: **entropía / ganancia de información**, **índice Gini de diversidad**, **χ²**, y **gain ratio** (que corrige el sesgo de la ganancia de información hacia atributos de muchos valores mediante *split information*). Sesgo inductivo.
- **Atributos continuos**: discretización **local** (pseudo-atributos dentro de TDIDT) vs. **global** (algoritmo **ChiMerge**, que fusiona intervalos adyacentes mientras χ² no sea significativo).
- **Overfitting**: choques (*clashes*) en el conjunto de entrenamiento, **pre-pruning** y **post-pruning** de árboles.
- **Estimación de precisión**: train/test separados, error estándar, **validación cruzada de k pliegues**, N-fold (leave-one-out).
- **Medición del rendimiento**: matriz de confusión, verdaderos/falsos positivos y negativos, por qué las tasas TP/FP dicen más que la precisión global, **gráficos y curvas ROC**, elección del mejor clasificador.
- **Reglas modulares**: el algoritmo **Prism** frente a TDIDT; resolución de conflictos entre reglas; por qué el formato árbol es limitante (*replicated subtree problem*).
- **Comparación de clasificadores**: **t-test emparejado**, intervalos de confianza, elección de datasets, cómo interpretar un «sin diferencia significativa».
- **Ensembles**: variar el conjunto de entrenamiento (bagging), variar el conjunto de atributos, sistemas de votación alternativos, ensembles paralelos.
- **Grandes volúmenes**: distribuir datos en múltiples procesadores, caso **PMCRI**, revisión incremental de un clasificador.

### Bloque C — Reglas de asociación (cap. 16–18)
- Medidas de interés de una regla: soporte, confianza, criterios de **Piatetsky-Shapiro**, medida **RI**, **J-measure** (contenido de información de una regla).
- **Apriori** (Agrawal & Srikant). Se apoya en dos teoremas:
  - **Teorema 1 (downward closure)**: si un itemset está soportado, todos sus subconjuntos no vacíos también lo están.
  - **Teorema 2**: si `L_k = ∅`, entonces `L_{k+1}`, `L_{k+2}`… también son vacíos.

  De ahí el algoritmo: generar itemsets en orden ascendente de cardinalidad; de `L_{k-1}` se forma el conjunto candidato `C_k`, se poda con `minsup` para obtener `L_k`, y se corta en cuanto `L_k` sea vacío.
- **FP-Trees** (Frequent Pattern Trees): alternativa a Apriori que evita generar candidatos.

### Bloque D — Clustering y texto (cap. 19–20)
- **k-means** (exclusivo): elegir k → seleccionar k centroides arbitrarios (mejor si están alejados entre sí) → asignar cada objeto al centroide más cercano → recalcular centroides → repetir hasta que no se muevan. Función objetivo: suma de cuadrados de las distancias al centroide. **Termina siempre, pero no garantiza el óptimo global** (depende de la inicialización).
- **Clustering jerárquico** (aglomerativo), con su propia elección de medida de distancia entre clusters.
- **Minería de texto**: representación vectorial, stop words, stemming, y ponderación **TFIDF** = `t_j × log₂(n / n_j)` — frecuencia del término en el documento × rareza del término en la colección. Normalización de los pesos para que la longitud del documento no domine.

### Bloque E — Datos en streaming (cap. 21–22) — nuevo en la 3ª edición
Motivación: flujos de más de un millón de registros diarios, potencialmente infinitos.

- **Árboles de Hoeffding**: se construye el árbol de forma incremental, un registro a la vez, sin almacenar el flujo. El problema estructural es que **un nodo, una vez dividido, no se puede des-dividir**, lo que hace el resultado muy sensible a las primeras divisiones.
- **Cota de Hoeffding**: solo se divide si el mejor atributo X supera al segundo mejor Y de forma significativa, es decir si `IG(X) − IG(Y) > ε`, con

  ```
  ε = R × √( ln(1/δ) / (2 × nrec) )
  ```

  donde R es el rango de la medida, `δ = 1 − Prob`, y `nrec` el número de registros llegados a ese nodo. Cumple lo que uno esperaría: mayor rango → mayor cota; mayor confianza exigida → mayor cota; más registros → menor cota.
- Mitigaciones para el arranque: empezar con un G (*grace period*) grande y reducirlo, o arrancar desde un árbol TDIDT construido con ~10.000 registros iniciales. Conviene aleatorizar el orden de los registros iniciales.
- **CDH-Tree** y **deriva de concepto (concept drift)**: ventana deslizante, re-división en nodos, identificación de **nodos sospechosos**, creación de **nodos alternativos** que crecen en paralelo y sustituyen al nodo interno cuando lo superan.

---

## 3. Provost & Fawcett — *Data Science for Business*

La tesis del libro: la ciencia de datos no es un catálogo de algoritmos, es un **conjunto pequeño de principios fundamentales** que se instancian de muchas formas. Se puede entender el campo, y evaluar críticamente a quien lo practica, sabiendo esos principios.

### Las 9 tareas canónicas de minería de datos ⭐
El marco más citable del libro. Todo problema de negocio se traduce a una o varias de estas:

1. **Clasificación y estimación de probabilidad de clase** — ¿a cuál de un conjunto pequeño de clases pertenece este individuo? El *scoring* devuelve una probabilidad en vez de una etiqueta; un modelo que hace una cosa suele adaptarse a la otra.
2. **Regresión (estimación de valor)** — el valor numérico de una variable. *La clasificación predice si algo ocurrirá; la regresión predice cuánto.*
3. **Emparejamiento por similitud** — encontrar individuos parecidos (IBM buscando empresas similares a sus mejores clientes). Base de muchos recomendadores.
4. **Clustering** — agrupar por similitud **sin un propósito específico**. Exploratorio: los grupos que aparecen sugieren otras tareas.
5. **Agrupación por co-ocurrencia** (frequent itemset mining, reglas de asociación, *market-basket analysis*) — a diferencia del clustering, la similitud viene de **aparecer juntos en transacciones**, no de los atributos.
6. **Perfilado (descripción de comportamiento)** — caracterizar el comportamiento típico. Base de la **detección de anomalías**: el grado de desajuste con el perfil es la puntuación de sospecha (fraude, intrusiones).
7. **Predicción de enlaces** — predecir que una conexión debería existir, y su fuerza (redes sociales, recomendación de películas como grafo usuario–ítem).
8. **Reducción de datos** — sustituir un conjunto grande por uno menor que conserve la información importante. Hay pérdida; la compensación es mayor claridad.
9. **Modelado causal** — ¿el anuncio causó la compra, o el modelo simplemente identificó bien a quien iba a comprar de todos modos? Experimentos controlados aleatorizados (**test A/B**) y métodos observacionales. Todo análisis causal es **contrafactual** y **siempre** hace supuestos: hay que enunciarlos explícitamente (el efecto placebo es el ejemplo clásico de un supuesto que se pasó por alto).

### El proceso de minería de datos (CRISP-DM)
Ciclo iterativo, no lineal: **Comprensión del negocio → Comprensión de los datos → Preparación de los datos → Modelado → Evaluación → Despliegue**, y vuelta atrás desde cualquier fase. El libro insiste en que el trabajo real está en las primeras fases y que el equipo debe gestionarse en función de ese ciclo.

Distinción relacionada: aplicar ciencia de datos a un **problema bien estructurado** frente a **minería exploratoria** requiere esfuerzos muy distintos en cada fase.

También sitúa la disciplina frente a lo adyacente: estadística, consulta de bases de datos, **data warehousing** (aquí se conecta directamente con el paper de Gray), análisis de regresión, machine learning.

### Recorrido temático
- **Cap. 3 — Segmentación supervisada**: identificar **atributos informativos**, selección por **ganancia de información**, inducción de árboles, árboles como conjuntos de reglas, estimación de probabilidad.
- **Cap. 4 — Ajustar un modelo a los datos**: funciones discriminantes lineales, **función objetivo** y **función de pérdida**, regresión lineal, regresión logística, SVM, redes neuronales. El principio: elegir un objetivo y buscar los parámetros que lo optimizan.
- **Cap. 5 — Overfitting y su evitación**: generalización, **gráficos de ajuste** (*fitting graphs*), datos de holdout, **curvas de aprendizaje**, validación cruzada, **control de complejidad** como método general (poda, regularización, selección de atributos). Por qué el overfitting es malo, no solo inelegante.
- **Cap. 6 — Similitud, vecinos y clusters**: distancias, k-NN (cuántos vecinos y con cuánta influencia), interpretación geométrica del overfitting en k-NN, atributos heterogéneos, clustering jerárquico.
- **Cap. 7 y 11 — Pensamiento analítico para decisiones**: ¿qué es un buen modelo? El **marco de valor esperado** (*expected value framework*) para descomponer un problema de negocio en sub-problemas de datos junto con sus costes, beneficios y restricciones. Hacia la «ingeniería analítica».
- **Cap. 8 — Visualizar el rendimiento**: curvas ROC, AUC, curvas de **lift** y de ganancia acumulada, y por qué la precisión (*accuracy*) engaña con clases desbalanceadas.
- **Cap. 9 — Evidencia y probabilidades**: Bayes, *lift* como peso de la evidencia.
- **Cap. 10 — Representar y minar texto**: bag of words, TFIDF, n-gramas.
- **Cap. 13 — Estrategia de negocio**: los datos y la capacidad analítica como **activo estratégico**; cómo la ciencia de datos genera ventaja competitiva y cómo se sostiene; atracción y estructuración de equipos.

### Los principios fundamentales, en tres grupos (cap. 14)
1. **Organizativos / competitivos** — cómo encaja la ciencia de datos en la empresa, cómo formar y nutrir equipos, cómo se logra y se sostiene la ventaja competitiva.
2. **Formas de pensar analíticamente**:
   - Los **datos son un activo**: hay que decidir deliberadamente qué invertir para explotarlos.
   - El **marco de valor esperado** estructura el problema de negocio y revela el tejido de costes, beneficios y restricciones.
   - **Generalización vs. overfitting**: *si miramos los datos con demasiada insistencia, encontraremos patrones*; queremos los que generalizan a datos no vistos.
   - Problema bien estructurado ≠ exploración.
3. **Extracción de conocimiento**:
   - Identificar **atributos informativos** (los que correlacionan con la cantidad de interés).
   - **Ajustar** un modelo numérico eligiendo un objetivo y optimizando parámetros.
   - **Controlar la complejidad** para equilibrar generalización y overfitting.
   - **Calcular similitud** entre objetos descritos por datos.

### Dos ideas transversales que el libro subraya
- **La similitud es un principio, no una técnica.** El mismo concepto sostiene la búsqueda de clientes parecidos, la clasificación y regresión por k-NN, el clustering, la recuperación de documentos frente a una consulta, y los recomendadores (proyectar clientes y películas al mismo «espacio de gustos»).
- **El *lift* —cuánto más probable es un patrón de lo esperado por azar— reaparece por todas partes**: evaluar la segmentación publicitaria, juzgar el peso de la evidencia a favor de una conclusión, y decidir si una co-ocurrencia repetida es interesante o solo consecuencia de la popularidad.

El capítulo final añade lo que los datos **no** pueden hacer (humanos en el bucle), y privacidad y ética al minar datos sobre individuos.

---

## Hilo conductor de los tres documentos

1. **Gray** resuelve cómo **obtener** los agregados multidimensionales de forma eficiente. Es la capa de extracción del ciclo *Extraer → Visualizar → Analizar → Reformular*. Su taxonomía distributiva / algebraica / holística sigue siendo la que decide qué se puede precalcular, mantener incrementalmente y paralelizar — el mismo razonamiento que hoy aplica a cualquier motor OLAP o de agregación distribuida.
2. **Bramer** cubre qué **algoritmos** aplicar sobre esos datos, con el detalle matemático: entropía, Apriori, k-means, TFIDF, cota de Hoeffding.
3. **Provost & Fawcett** responden **por qué y para qué**: cómo traducir un problema de negocio a una de las 9 tareas, cómo estructurar la decisión con valor esperado, y cómo evaluar honestamente (ROC, lift, validación cruzada) para no confundir un patrón espurio con conocimiento.

Los tres convergen en la misma advertencia desde ángulos distintos: **agregar o ajustar es fácil; lo difícil es saber si el resultado significa algo.** Gray lo plantea como el coste de recalcular, Bramer como overfitting y significancia estadística, Provost & Fawcett como generalización y supuestos causales explícitos.
