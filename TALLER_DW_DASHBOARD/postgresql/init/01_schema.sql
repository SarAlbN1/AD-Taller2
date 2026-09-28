-- Esquema de la base transaccional retail_db (PostgreSQL 14)
-- Taller 2. El orden de las tablas respeta las llaves foraneas.

-- categories
CREATE TABLE categories (
    category_id   SERIAL PRIMARY KEY,
    category_name VARCHAR(50) NOT NULL,
    description   TEXT
);

-- suppliers
CREATE TABLE suppliers (
    supplier_id  SERIAL PRIMARY KEY,
    company_name VARCHAR(80) NOT NULL,
    city         VARCHAR(40),
    country      VARCHAR(40)
);

-- shippers
CREATE TABLE shippers (
    shipper_id   SERIAL PRIMARY KEY,
    company_name VARCHAR(80) NOT NULL,
    phone        VARCHAR(30)
);

-- region
CREATE TABLE region (
    region_id          INTEGER PRIMARY KEY,
    region_description VARCHAR(60) NOT NULL
);

-- territories
CREATE TABLE territories (
    territory_id          VARCHAR(20) PRIMARY KEY,
    territory_description VARCHAR(60) NOT NULL,
    region_id             INTEGER NOT NULL REFERENCES region (region_id)
);

-- employees
CREATE TABLE employees (
    employee_id SERIAL PRIMARY KEY,
    last_name   VARCHAR(40) NOT NULL,
    first_name  VARCHAR(40) NOT NULL,
    title       VARCHAR(60),
    birth_date  DATE,
    hire_date   DATE
);

-- employee_territories, relaciona empleados con territorios
CREATE TABLE employee_territories (
    employee_id  INTEGER     NOT NULL REFERENCES employees (employee_id),
    territory_id VARCHAR(20) NOT NULL REFERENCES territories (territory_id),
    PRIMARY KEY (employee_id, territory_id)
);

-- customers
CREATE TABLE customers (
    customer_id   VARCHAR(10) PRIMARY KEY,
    company_name  VARCHAR(80) NOT NULL,
    contact_name  VARCHAR(60),
    contact_title VARCHAR(60),
    address       VARCHAR(120),
    city          VARCHAR(40),
    region        VARCHAR(40),
    postal_code   VARCHAR(20),
    country       VARCHAR(40),
    phone         VARCHAR(30),
    fax           VARCHAR(30)
);

-- customer_demographics
CREATE TABLE customer_demographics (
    customer_type_id VARCHAR(10) PRIMARY KEY,
    customer_desc    TEXT
);

-- customer_customer_demo, relaciona clientes con su tipo
CREATE TABLE customer_customer_demo (
    customer_id      VARCHAR(10) NOT NULL REFERENCES customers (customer_id),
    customer_type_id VARCHAR(10) NOT NULL REFERENCES customer_demographics (customer_type_id),
    PRIMARY KEY (customer_id, customer_type_id)
);

-- products
CREATE TABLE products (
    product_id     SERIAL PRIMARY KEY,
    product_name   VARCHAR(80) NOT NULL,
    supplier_id    INTEGER REFERENCES suppliers (supplier_id),
    category_id    INTEGER REFERENCES categories (category_id),
    unit_price     NUMERIC(10,2) DEFAULT 0 CHECK (unit_price >= 0),
    units_in_stock INTEGER       DEFAULT 0 CHECK (units_in_stock >= 0)
);

-- orders
CREATE TABLE orders (
    order_id    SERIAL PRIMARY KEY,
    customer_id VARCHAR(10) REFERENCES customers (customer_id),
    employee_id INTEGER     REFERENCES employees (employee_id),
    order_date  DATE,
    ship_via    INTEGER     REFERENCES shippers (shipper_id),
    freight     NUMERIC(10,2) DEFAULT 0
);

-- order_details, las lineas de cada orden
CREATE TABLE order_details (
    order_id   INTEGER      NOT NULL REFERENCES orders (order_id),
    product_id INTEGER      NOT NULL REFERENCES products (product_id),
    unit_price NUMERIC(10,2) NOT NULL DEFAULT 0,
    quantity   SMALLINT      NOT NULL DEFAULT 1 CHECK (quantity > 0),
    discount   REAL          NOT NULL DEFAULT 0 CHECK (discount >= 0 AND discount <= 1),
    PRIMARY KEY (order_id, product_id)
);

-- indices para las consultas del taller
CREATE INDEX idx_orders_order_date  ON orders (order_date);
CREATE INDEX idx_orders_customer    ON orders (customer_id);
CREATE INDEX idx_orders_employee    ON orders (employee_id);
CREATE INDEX idx_order_details_prod ON order_details (product_id);
CREATE INDEX idx_products_category  ON products (category_id);
