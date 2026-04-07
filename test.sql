-- =============================================================================
-- SQLite Comprehensive Demo Schema
-- Covers: data types, constraints, indexes, triggers, views, CTEs, FTS5,
--         generated columns, STRICT tables, WITHOUT ROWID, JSON, window
--         functions, partial indexes, expression indexes, and more.
-- =============================================================================


-- =============================================================================
-- 0. DROP STATEMENTS  (views first, then tables, then virtual tables)
-- =============================================================================

DROP VIEW  IF EXISTS vw_order_summary;
DROP VIEW  IF EXISTS vw_employee_hierarchy;
DROP VIEW  IF EXISTS vw_product_inventory;
DROP VIEW  IF EXISTS vw_customer_lifetime;
DROP VIEW  IF EXISTS vw_monthly_revenue;
DROP VIEW  IF EXISTS vw_audit_log;

DROP TABLE IF EXISTS order_items;
DROP TABLE IF EXISTS orders;
DROP TABLE IF EXISTS product_tags;
DROP TABLE IF EXISTS tags;
DROP TABLE IF EXISTS products;
DROP TABLE IF EXISTS inventory;
DROP TABLE IF EXISTS categories;
DROP TABLE IF EXISTS employees;
DROP TABLE IF EXISTS departments;
DROP TABLE IF EXISTS customers;
DROP TABLE IF EXISTS addresses;
DROP TABLE IF EXISTS audit_log;
DROP TABLE IF EXISTS settings;
DROP TABLE IF EXISTS sessions;
DROP TABLE IF EXISTS attachments;

-- Virtual / special tables
DROP TABLE IF EXISTS products_fts;


-- =============================================================================
-- 1. TABLES
-- =============================================================================

-- ---------------------------------------------------------------------------
-- 1.1  addresses  –  demonstrates NULL / NOT NULL, CHECK, DEFAULT, UNIQUE
-- ---------------------------------------------------------------------------
CREATE TABLE addresses (
    address_id   INTEGER PRIMARY KEY AUTOINCREMENT,   -- implicit rowid alias
    street       TEXT    NOT NULL,
    city         TEXT    NOT NULL,
    state        TEXT,                                -- nullable
    postal_code  TEXT,
    country      TEXT    NOT NULL DEFAULT 'US',
    latitude     REAL    CHECK (latitude  BETWEEN -90  AND  90),
    longitude    REAL    CHECK (longitude BETWEEN -180 AND 180),
    is_verified  INTEGER NOT NULL DEFAULT 0           -- SQLite boolean (0/1)
                         CHECK (is_verified IN (0, 1)),
    created_at   TEXT    NOT NULL
                         DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),

    -- Named table-level CHECK constraint
    CONSTRAINT chk_postal CHECK (
        postal_code IS NULL OR length(postal_code) >= 3
    )
);

-- ---------------------------------------------------------------------------
-- 1.2  customers  –  FOREIGN KEY, composite UNIQUE, TEXT affinity rules
-- ---------------------------------------------------------------------------
CREATE TABLE customers (
    customer_id  INTEGER PRIMARY KEY,
    first_name   TEXT    NOT NULL,
    last_name    TEXT    NOT NULL,
    email        TEXT    NOT NULL UNIQUE COLLATE NOCASE,
    phone        TEXT,
    birth_date   TEXT,                               -- stored as ISO-8601
    address_id   INTEGER REFERENCES addresses (address_id)
                         ON DELETE SET NULL
                         ON UPDATE CASCADE,
    loyalty_pts  INTEGER NOT NULL DEFAULT 0
                         CHECK (loyalty_pts >= 0),
    tier         TEXT    NOT NULL DEFAULT 'bronze'
                         CHECK (tier IN ('bronze','silver','gold','platinum')),
    metadata     TEXT,                               -- JSON stored as TEXT
    created_at   TEXT    NOT NULL
                         DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    updated_at   TEXT    NOT NULL
                         DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),

    CONSTRAINT uq_customer_name_phone UNIQUE (first_name, last_name, phone)
);

-- ---------------------------------------------------------------------------
-- 1.3  departments  –  self-referencing FK (hierarchy)
-- ---------------------------------------------------------------------------
CREATE TABLE departments (
    dept_id     INTEGER PRIMARY KEY,
    dept_name   TEXT    NOT NULL UNIQUE,
    parent_id   INTEGER REFERENCES departments (dept_id)
                        ON DELETE SET NULL,
    budget      REAL    NOT NULL DEFAULT 0.0
                        CHECK (budget >= 0),
    cost_center TEXT
);

-- ---------------------------------------------------------------------------
-- 1.4  employees  –  multi-column FK, generated columns
-- ---------------------------------------------------------------------------
CREATE TABLE employees (
    employee_id   INTEGER PRIMARY KEY AUTOINCREMENT,
    dept_id       INTEGER NOT NULL
                          REFERENCES departments (dept_id)
                          ON DELETE RESTRICT,
    first_name    TEXT    NOT NULL,
    last_name     TEXT    NOT NULL,
    -- GENERATED (stored) column – computed once on INSERT/UPDATE
    full_name     TEXT    GENERATED ALWAYS AS
                          (trim(first_name || ' ' || last_name)) STORED,
    email         TEXT    NOT NULL UNIQUE COLLATE NOCASE,
    job_title     TEXT,
    salary        REAL    NOT NULL CHECK (salary > 0),
    hire_date     TEXT    NOT NULL,
    manager_id    INTEGER REFERENCES employees (employee_id),
    is_active     INTEGER NOT NULL DEFAULT 1
                          CHECK (is_active IN (0,1)),
    -- GENERATED (virtual) column – recomputed on every read
    annual_salary REAL    GENERATED ALWAYS AS (salary * 12) VIRTUAL
);

-- ---------------------------------------------------------------------------
-- 1.5  categories  –  WITHOUT ROWID table (good for small lookup tables)
-- ---------------------------------------------------------------------------
CREATE TABLE categories (
    category_code TEXT    PRIMARY KEY,               -- no implicit rowid
    category_name TEXT    NOT NULL UNIQUE,
    description   TEXT,
    is_active     INTEGER NOT NULL DEFAULT 1
                          CHECK (is_active IN (0,1))
) WITHOUT ROWID;

-- ---------------------------------------------------------------------------
-- 1.6  products  –  REAL / NUMERIC affinity, NOT NULL DEFAULT, multi-CHECK
-- ---------------------------------------------------------------------------
CREATE TABLE products (
    product_id    INTEGER PRIMARY KEY AUTOINCREMENT,
    category_code TEXT    NOT NULL
                          REFERENCES categories (category_code)
                          ON DELETE RESTRICT,
    sku           TEXT    NOT NULL UNIQUE,
    product_name  TEXT    NOT NULL,
    description   TEXT,
    unit_price    REAL    NOT NULL CHECK (unit_price >= 0),
    cost_price    REAL    NOT NULL CHECK (cost_price >= 0),
    -- GENERATED margin (virtual)
    margin_pct    REAL    GENERATED ALWAYS AS (
                              CASE WHEN unit_price = 0 THEN 0
                                   ELSE round((unit_price - cost_price)
                                         / unit_price * 100, 2)
                              END
                          ) VIRTUAL,
    weight_kg     REAL    CHECK (weight_kg > 0),
    is_active     INTEGER NOT NULL DEFAULT 1
                          CHECK (is_active IN (0,1)),
    tags_json     TEXT,                              -- JSON array as TEXT
    created_at    TEXT    NOT NULL
                          DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),

    CONSTRAINT chk_price_gt_cost CHECK (unit_price >= cost_price)
);

-- ---------------------------------------------------------------------------
-- 1.7  inventory  –  composite PRIMARY KEY, NUMERIC affinity
-- ---------------------------------------------------------------------------
CREATE TABLE inventory (
    product_id    INTEGER NOT NULL REFERENCES products (product_id)
                          ON DELETE CASCADE,
    location      TEXT    NOT NULL,
    quantity      INTEGER NOT NULL DEFAULT 0 CHECK (quantity >= 0),
    reorder_level INTEGER NOT NULL DEFAULT 10,
    last_counted  TEXT,

    PRIMARY KEY (product_id, location)
);

-- ---------------------------------------------------------------------------
-- 1.8  tags & product_tags  –  many-to-many junction, WITHOUT ROWID
-- ---------------------------------------------------------------------------
CREATE TABLE tags (
    tag_id   INTEGER PRIMARY KEY,
    tag_name TEXT    NOT NULL UNIQUE COLLATE NOCASE
);

CREATE TABLE product_tags (
    product_id INTEGER NOT NULL REFERENCES products (product_id)
                       ON DELETE CASCADE,
    tag_id     INTEGER NOT NULL REFERENCES tags    (tag_id)
                       ON DELETE CASCADE,
    added_at   TEXT    NOT NULL
                       DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),

    PRIMARY KEY (product_id, tag_id)
) WITHOUT ROWID;

-- ---------------------------------------------------------------------------
-- 1.9  orders  –  NUMERIC column, complex CHECKs, multiple FKs
-- ---------------------------------------------------------------------------
CREATE TABLE orders (
    order_id     INTEGER PRIMARY KEY AUTOINCREMENT,
    customer_id  INTEGER NOT NULL
                         REFERENCES customers (customer_id)
                         ON DELETE RESTRICT,
    order_date   TEXT    NOT NULL
                         DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    status       TEXT    NOT NULL DEFAULT 'pending'
                         CHECK (status IN
                           ('pending','confirmed','shipped',
                            'delivered','cancelled','refunded')),
    ship_address INTEGER REFERENCES addresses (address_id),
    discount_pct REAL    NOT NULL DEFAULT 0.0
                         CHECK (discount_pct BETWEEN 0 AND 100),
    tax_pct      REAL    NOT NULL DEFAULT 0.0
                         CHECK (tax_pct >= 0),
    notes        TEXT,
    shipped_at   TEXT,
    delivered_at TEXT,

    CONSTRAINT chk_dates CHECK (
        shipped_at   IS NULL OR shipped_at   >= order_date AND
        delivered_at IS NULL OR delivered_at >= order_date
    )
);

-- ---------------------------------------------------------------------------
-- 1.10 order_items  –  composite PK, derived totals via generated columns
-- ---------------------------------------------------------------------------
CREATE TABLE order_items (
    order_id    INTEGER NOT NULL REFERENCES orders   (order_id)
                        ON DELETE CASCADE,
    product_id  INTEGER NOT NULL REFERENCES products (product_id)
                        ON DELETE RESTRICT,
    quantity    INTEGER NOT NULL CHECK (quantity > 0),
    unit_price  REAL    NOT NULL CHECK (unit_price >= 0),  -- price at time of sale
    discount    REAL    NOT NULL DEFAULT 0.0
                        CHECK (discount BETWEEN 0 AND 1),  -- fraction 0..1
    line_total  REAL    GENERATED ALWAYS AS
                        (round(quantity * unit_price * (1 - discount), 2)) STORED,

    PRIMARY KEY (order_id, product_id)
) WITHOUT ROWID;

-- ---------------------------------------------------------------------------
-- 1.11 audit_log  –  BLOB column, STRICT table (type enforcement)
-- ---------------------------------------------------------------------------
CREATE TABLE audit_log (
    log_id      INTEGER PRIMARY KEY,
    table_name  TEXT    NOT NULL,
    record_id   INTEGER NOT NULL,
    action      TEXT    NOT NULL CHECK (action IN ('INSERT','UPDATE','DELETE')),
    old_data    TEXT,                    -- JSON
    new_data    TEXT,                    -- JSON
    changed_by  TEXT,
    ip_address  TEXT,
    payload     BLOB,                    -- raw binary payload (BLOB affinity)
    logged_at   TEXT    NOT NULL
                        DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now'))
);

-- ---------------------------------------------------------------------------
-- 1.12 settings  –  key/value store, STRICT (SQLite ≥ 3.37)
-- ---------------------------------------------------------------------------
CREATE TABLE settings (
    key         TEXT    PRIMARY KEY,
    value       TEXT,
    description TEXT,
    updated_at  TEXT    NOT NULL
                        DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now'))
) STRICT;

-- ---------------------------------------------------------------------------
-- 1.13 sessions  –  demonstrates INTEGER STRICT affinity
-- ---------------------------------------------------------------------------
CREATE TABLE sessions (
    session_id  TEXT    PRIMARY KEY,
    customer_id INTEGER NOT NULL REFERENCES customers (customer_id)
                        ON DELETE CASCADE,
    created_at  TEXT    NOT NULL
                        DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    expires_at  TEXT    NOT NULL,
    ip_address  TEXT,
    user_agent  TEXT,
    is_valid    INTEGER NOT NULL DEFAULT 1
                        CHECK (is_valid IN (0,1))
);

-- ---------------------------------------------------------------------------
-- 1.14 attachments  –  stores file blobs
-- ---------------------------------------------------------------------------
CREATE TABLE attachments (
    attachment_id INTEGER PRIMARY KEY AUTOINCREMENT,
    order_id      INTEGER REFERENCES orders (order_id) ON DELETE SET NULL,
    file_name     TEXT    NOT NULL,
    mime_type     TEXT    NOT NULL,
    file_size     INTEGER NOT NULL CHECK (file_size > 0),
    file_data     BLOB    NOT NULL,
    uploaded_at   TEXT    NOT NULL
                          DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now'))
);


-- =============================================================================
-- 2. INDEXES
-- =============================================================================

-- Regular index
CREATE INDEX idx_customers_email      ON customers  (email);
CREATE INDEX idx_orders_customer      ON orders     (customer_id);
CREATE INDEX idx_orders_date          ON orders     (order_date);
CREATE INDEX idx_employees_dept       ON employees  (dept_id);
CREATE INDEX idx_products_category    ON products   (category_code);

-- Partial index – only index active customers
CREATE INDEX idx_customers_active     ON customers  (loyalty_pts DESC)
    WHERE tier IN ('gold','platinum');

-- Partial index – only pending orders
CREATE INDEX idx_orders_pending       ON orders     (order_date)
    WHERE status = 'pending';

-- Expression index – case-insensitive search on last name
CREATE INDEX idx_employees_lastname   ON employees  (lower(last_name));

-- Composite index
CREATE INDEX idx_inventory_reorder    ON inventory  (product_id, location)
    WHERE quantity <= reorder_level;

-- Unique index on expression
CREATE UNIQUE INDEX uidx_products_sku_upper ON products (upper(sku));


-- =============================================================================
-- 3. TRIGGERS
-- =============================================================================

-- ---------------------------------------------------------------------------
-- 3.1  Auto-update updated_at on customers
-- ---------------------------------------------------------------------------
CREATE TRIGGER IF NOT EXISTS trg_customers_updated_at
    AFTER UPDATE ON customers
    FOR EACH ROW
BEGIN
    UPDATE customers
       SET updated_at = strftime('%Y-%m-%dT%H:%M:%fZ', 'now')
     WHERE customer_id = NEW.customer_id;
END;

-- ---------------------------------------------------------------------------
-- 3.2  Audit log – capture every INSERT on orders
-- ---------------------------------------------------------------------------
CREATE TRIGGER IF NOT EXISTS trg_orders_audit_insert
    AFTER INSERT ON orders
    FOR EACH ROW
BEGIN
    INSERT INTO audit_log (table_name, record_id, action, new_data)
    VALUES (
        'orders',
        NEW.order_id,
        'INSERT',
        json_object(
            'order_id',    NEW.order_id,
            'customer_id', NEW.customer_id,
            'status',      NEW.status,
            'order_date',  NEW.order_date
        )
    );
END;

-- ---------------------------------------------------------------------------
-- 3.3  Audit log – capture every DELETE on orders
-- ---------------------------------------------------------------------------
CREATE TRIGGER IF NOT EXISTS trg_orders_audit_delete
    BEFORE DELETE ON orders
    FOR EACH ROW
BEGIN
    INSERT INTO audit_log (table_name, record_id, action, old_data)
    VALUES (
        'orders',
        OLD.order_id,
        'DELETE',
        json_object(
            'order_id',   OLD.order_id,
            'status',     OLD.status,
            'order_date', OLD.order_date
        )
    );
END;

-- ---------------------------------------------------------------------------
-- 3.4  INSTEAD OF trigger on a view – make vw_product_inventory updatable
-- ---------------------------------------------------------------------------
-- (defined after the view below – forward-declaration note)


-- =============================================================================
-- 4. VIRTUAL TABLE – Full-Text Search (FTS5)
-- =============================================================================

CREATE VIRTUAL TABLE IF NOT EXISTS products_fts
    USING fts5 (
        product_name,
        description,
        sku,
        content     = 'products',         -- content table
        content_rowid = 'product_id',
        tokenize    = 'porter unicode61'  -- Porter stemmer + Unicode
    );

-- Keep FTS in sync via triggers
CREATE TRIGGER IF NOT EXISTS trg_products_fts_insert
    AFTER INSERT ON products
BEGIN
    INSERT INTO products_fts (rowid, product_name, description, sku)
    VALUES (NEW.product_id, NEW.product_name, NEW.description, NEW.sku);
END;

CREATE TRIGGER IF NOT EXISTS trg_products_fts_delete
    AFTER DELETE ON products
BEGIN
    INSERT INTO products_fts (products_fts, rowid, product_name, description, sku)
    VALUES ('delete', OLD.product_id, OLD.product_name, OLD.description, OLD.sku);
END;

CREATE TRIGGER IF NOT EXISTS trg_products_fts_update
    AFTER UPDATE ON products
BEGIN
    INSERT INTO products_fts (products_fts, rowid, product_name, description, sku)
    VALUES ('delete', OLD.product_id, OLD.product_name, OLD.description, OLD.sku);
    INSERT INTO products_fts (rowid, product_name, description, sku)
    VALUES (NEW.product_id, NEW.product_name, NEW.description, NEW.sku);
END;


-- =============================================================================
-- 5. VIEWS
-- =============================================================================

-- ---------------------------------------------------------------------------
-- 5.1  vw_order_summary
--      Uses: JOIN, aggregate, CASE, ROUND, window function (ROW_NUMBER)
-- ---------------------------------------------------------------------------
CREATE VIEW vw_order_summary AS
WITH ranked AS (
    SELECT
        o.order_id,
        o.customer_id,
        c.first_name || ' ' || c.last_name      AS customer_name,
        c.tier,
        o.order_date,
        o.status,
        count(oi.product_id)                    AS line_count,
        sum(oi.line_total)                      AS subtotal,
        round(sum(oi.line_total)
              * (1 - o.discount_pct / 100.0), 2) AS discounted_total,
        round(sum(oi.line_total)
              * (1 - o.discount_pct / 100.0)
              * (1 + o.tax_pct    / 100.0), 2)  AS grand_total,
        row_number() OVER (
            PARTITION BY o.customer_id
            ORDER BY o.order_date DESC
        )                                        AS rn_per_customer
    FROM       orders      o
    JOIN       customers   c  USING (customer_id)
    LEFT JOIN  order_items oi USING (order_id)
    GROUP BY   o.order_id
)
SELECT
    order_id,
    customer_id,
    customer_name,
    tier,
    order_date,
    status,
    line_count,
    subtotal,
    discounted_total,
    grand_total,
    rn_per_customer,
    CASE rn_per_customer WHEN 1 THEN 1 ELSE 0 END AS is_latest_order
FROM ranked;

-- ---------------------------------------------------------------------------
-- 5.2  vw_employee_hierarchy
--      Uses: recursive CTE to walk the manager → employee tree
-- ---------------------------------------------------------------------------
CREATE VIEW vw_employee_hierarchy AS
WITH RECURSIVE hierarchy (
    employee_id, full_name, job_title, manager_id,
    dept_id, depth, path
) AS (
    -- Anchor: top-level employees (no manager)
    SELECT
        employee_id, full_name, job_title, manager_id,
        dept_id, 0,
        full_name
    FROM employees
    WHERE manager_id IS NULL

    UNION ALL

    -- Recursive: employees who have a manager
    SELECT
        e.employee_id, e.full_name, e.job_title, e.manager_id,
        e.dept_id, h.depth + 1,
        h.path || ' > ' || e.full_name
    FROM employees e
    JOIN hierarchy h ON e.manager_id = h.employee_id
)
SELECT
    h.employee_id,
    h.full_name,
    h.job_title,
    h.manager_id,
    d.dept_name,
    h.depth            AS hierarchy_depth,
    h.path             AS org_path
FROM      hierarchy   h
JOIN      departments d USING (dept_id)
ORDER BY  h.path;

-- ---------------------------------------------------------------------------
-- 5.3  vw_product_inventory
--      Uses: LEFT JOIN, COALESCE, CASE, generated column reference
-- ---------------------------------------------------------------------------
CREATE VIEW vw_product_inventory AS
SELECT
    p.product_id,
    p.sku,
    p.product_name,
    p.category_code,
    cat.category_name,
    p.unit_price,
    p.cost_price,
    p.margin_pct,                              -- virtual generated column
    p.is_active,
    coalesce(sum(i.quantity), 0)          AS total_stock,
    coalesce(count(i.location), 0)        AS location_count,
    CASE
        WHEN coalesce(sum(i.quantity), 0) = 0         THEN 'out_of_stock'
        WHEN sum(i.quantity) <= sum(i.reorder_level)  THEN 'low_stock'
        ELSE                                               'in_stock'
    END                                   AS stock_status,
    group_concat(i.location, ', ')        AS locations
FROM       products    p
JOIN       categories  cat USING (category_code)
LEFT JOIN  inventory   i   USING (product_id)
GROUP BY   p.product_id;

-- ---------------------------------------------------------------------------
-- 5.4  vw_customer_lifetime
--      Uses: subquery, window SUM, JSON functions
-- ---------------------------------------------------------------------------
CREATE VIEW vw_customer_lifetime AS
SELECT
    c.customer_id,
    c.first_name || ' ' || c.last_name          AS customer_name,
    c.email,
    c.tier,
    c.loyalty_pts,
    count(DISTINCT o.order_id)                  AS total_orders,
    coalesce(sum(os.grand_total), 0)            AS lifetime_value,
    coalesce(avg(os.grand_total), 0)            AS avg_order_value,
    min(o.order_date)                           AS first_order_date,
    max(o.order_date)                           AS last_order_date,
    -- JSON object from metadata column
    json_extract(c.metadata, '$.referral_code') AS referral_code
FROM      customers        c
LEFT JOIN orders           o  USING (customer_id)
LEFT JOIN vw_order_summary os USING (order_id)
GROUP BY  c.customer_id;

-- ---------------------------------------------------------------------------
-- 5.5  vw_monthly_revenue
--      Uses: strftime date truncation, window functions (SUM OVER, LAG)
-- ---------------------------------------------------------------------------
CREATE VIEW vw_monthly_revenue AS
WITH monthly AS (
    SELECT
        strftime('%Y-%m', o.order_date)  AS month,
        round(sum(os.grand_total), 2)    AS revenue,
        count(DISTINCT o.order_id)       AS order_count,
        count(DISTINCT o.customer_id)    AS unique_customers
    FROM       orders           o
    JOIN       vw_order_summary os USING (order_id)
    WHERE      o.status NOT IN ('cancelled','refunded')
    GROUP BY   month
)
SELECT
    month,
    revenue,
    order_count,
    unique_customers,
    round(revenue / order_count, 2)          AS avg_order_value,
    sum(revenue) OVER (
        ORDER BY month
        ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
    )                                         AS cumulative_revenue,
    lag(revenue, 1) OVER (ORDER BY month)    AS prev_month_revenue,
    CASE
        WHEN lag(revenue,1) OVER (ORDER BY month) IS NULL THEN NULL
        ELSE round(
            (revenue - lag(revenue,1) OVER (ORDER BY month))
            / lag(revenue,1) OVER (ORDER BY month) * 100, 2
        )
    END                                       AS mom_growth_pct
FROM monthly
ORDER BY month;

-- ---------------------------------------------------------------------------
-- 5.6  vw_audit_log  –  human-readable audit log with JSON pretty-print
-- ---------------------------------------------------------------------------
CREATE VIEW vw_audit_log AS
SELECT
    a.log_id,
    a.table_name,
    a.record_id,
    a.action,
    a.changed_by,
    a.ip_address,
    a.logged_at,
    -- Extract a handful of common fields from the JSON blobs
    json_extract(a.old_data, '$.status') AS old_status,
    json_extract(a.new_data, '$.status') AS new_status,
    CASE
        WHEN a.old_data IS NULL AND a.new_data IS NOT NULL THEN 'created'
        WHEN a.old_data IS NOT NULL AND a.new_data IS NULL THEN 'removed'
        ELSE                                                     'modified'
    END                                  AS change_type
FROM audit_log a
ORDER BY a.logged_at DESC;


-- =============================================================================
-- 6. INSTEAD OF TRIGGER on vw_product_inventory
--    Allows UPDATE of unit_price & cost_price through the view
-- =============================================================================
CREATE TRIGGER IF NOT EXISTS trg_vw_product_inventory_update
    INSTEAD OF UPDATE OF unit_price, cost_price ON vw_product_inventory
    FOR EACH ROW
BEGIN
    UPDATE products
       SET unit_price = NEW.unit_price,
           cost_price = NEW.cost_price
     WHERE product_id = OLD.product_id;
END;


-- =============================================================================
-- 7. SAMPLE DATA
-- =============================================================================

-- PRAGMA (enable FK enforcement at runtime – not stored in schema)
PRAGMA foreign_keys = ON;

INSERT INTO addresses (street, city, state, postal_code, country, latitude, longitude, is_verified)
VALUES
    ('123 Main St',      'New York',    'NY', '10001', 'US',  40.7128,  -74.0060, 1),
    ('456 Oak Ave',      'Los Angeles', 'CA', '90001', 'US',  34.0522, -118.2437, 1),
    ('789 Pine Rd',      'Chicago',     'IL', '60601', 'US',  41.8781,  -87.6298, 0),
    ('Rue de Rivoli 1',  'Paris',       NULL, '75001', 'FR',  48.8606,    2.3376, 1);

INSERT INTO departments (dept_id, dept_name, parent_id, budget, cost_center)
VALUES
    (1, 'Executive',   NULL, 500000, 'CC-001'),
    (2, 'Engineering', 1,    800000, 'CC-002'),
    (3, 'Sales',       1,    300000, 'CC-003'),
    (4, 'Support',     3,    150000, 'CC-004');

INSERT INTO employees (dept_id, first_name, last_name, email, job_title, salary, hire_date, manager_id, is_active)
VALUES
    (1, 'Alice',   'Smith',   'alice@corp.com',   'CEO',             15000, '2015-01-10', NULL, 1),
    (2, 'Bob',     'Johnson', 'bob@corp.com',     'VP Engineering',  10000, '2016-03-15', 1,    1),
    (2, 'Carol',   'White',   'carol@corp.com',   'Senior Engineer',  7000, '2018-07-01', 2,    1),
    (3, 'David',   'Brown',   'david@corp.com',   'Sales Director',   8000, '2017-05-20', 1,    1),
    (4, 'Eve',     'Davis',   'eve@corp.com',     'Support Lead',     5000, '2019-11-01', 4,    1);

INSERT INTO customers (first_name, last_name, email, phone, address_id, loyalty_pts, tier, metadata)
VALUES
    ('John',  'Doe',    'john@example.com',  '+1-555-0101', 1, 1200, 'gold',    '{"referral_code":"REF001","newsletter":true}'),
    ('Jane',  'Roe',    'jane@example.com',  '+1-555-0202', 2,  350, 'silver',  '{"referral_code":null,"newsletter":false}'),
    ('Henri', 'Dupont', 'henri@example.fr',  '+33-1-4200',  4,   50, 'bronze',  '{}');

INSERT INTO categories (category_code, category_name, description, is_active)
VALUES
    ('ELEC', 'Electronics',  'Electronic devices and accessories', 1),
    ('BOOK', 'Books',        'Printed and digital publications',   1),
    ('CLTH', 'Clothing',     'Apparel and accessories',            1);

INSERT INTO tags (tag_name) VALUES ('wireless'), ('bestseller'), ('new-arrival'), ('sale');

INSERT INTO products (category_code, sku, product_name, description, unit_price, cost_price, weight_kg, is_active, tags_json)
VALUES
    ('ELEC', 'SKU-001', 'Wireless Headphones', 'Over-ear noise cancelling',  149.99,  60.00, 0.35, 1, '["wireless","bestseller"]'),
    ('ELEC', 'SKU-002', 'USB-C Hub 7-in-1',    '4K HDMI, PD, USB 3.0 ports',  49.99,  18.00, 0.12, 1, '["new-arrival"]'),
    ('BOOK', 'SKU-003', 'SQLite in Depth',      'Complete SQLite reference',    34.99,  10.00, 0.55, 1, '["bestseller"]'),
    ('CLTH', 'SKU-004', 'Merino Wool Sweater',  'Fine merino, crew neck',        89.99,  35.00, 0.40, 1, '["sale"]');

INSERT INTO inventory (product_id, location, quantity, reorder_level, last_counted)
VALUES
    (1, 'Warehouse-A', 120,  20, '2026-03-01'),
    (1, 'Warehouse-B',  30,  10, '2026-03-01'),
    (2, 'Warehouse-A',  55,  15, '2026-03-15'),
    (3, 'Warehouse-C', 200,  30, '2026-02-28'),
    (4, 'Warehouse-A',   8,  25, '2026-03-10');   -- low stock!

INSERT INTO product_tags (product_id, tag_id)
VALUES (1,1),(1,2),(2,3),(3,2),(4,4);

INSERT INTO orders (customer_id, status, ship_address, discount_pct, tax_pct, notes)
VALUES
    (1, 'delivered', 1,  5.0, 8.875, 'Gift wrap requested'),
    (1, 'shipped',   1,  0.0, 8.875, NULL),
    (2, 'pending',   2, 10.0, 9.0,   'First-time buyer discount'),
    (3, 'confirmed', 4,  0.0, 20.0,  'International order');

INSERT INTO order_items (order_id, product_id, quantity, unit_price, discount)
VALUES
    (1, 1, 2, 149.99, 0.05),
    (1, 3, 1,  34.99, 0.00),
    (2, 2, 3,  49.99, 0.00),
    (3, 4, 1,  89.99, 0.10),
    (4, 1, 1, 149.99, 0.00),
    (4, 2, 2,  49.99, 0.00);

INSERT INTO settings (key, value, description)
VALUES
    ('site_name',       'MyStore',  'Public name of the store'),
    ('currency',        'USD',      'Default currency code'),
    ('tax_rate_default','8.875',    'Default tax rate (%)'),
    ('max_sessions',    '5',        'Max concurrent sessions per user');


-- =============================================================================
-- 8. USEFUL QUERY EXAMPLES (commented out – run individually as needed)
-- =============================================================================

/*
-- Full-text search
SELECT product_id, product_name, description
  FROM products_fts
 WHERE products_fts MATCH 'noise OR USB'
 ORDER BY rank;

-- Customer lifetime value
SELECT customer_name, tier, total_orders,
       lifetime_value, avg_order_value
  FROM vw_customer_lifetime
 ORDER BY lifetime_value DESC;

-- Monthly revenue with MoM growth
SELECT month, revenue, mom_growth_pct, cumulative_revenue
  FROM vw_monthly_revenue;

-- Org chart path
SELECT hierarchy_depth, org_path, job_title
  FROM vw_employee_hierarchy;

-- Low / out-of-stock products
SELECT product_name, sku, total_stock, stock_status
  FROM vw_product_inventory
 WHERE stock_status <> 'in_stock';

-- JSON extraction
SELECT customer_name,
       json_extract(metadata, '$.referral_code') AS ref,
       json_extract(metadata, '$.newsletter')    AS newsletter
  FROM customers
 WHERE metadata IS NOT NULL;

-- Window function: rank customers by spend within their tier
SELECT customer_name, tier, lifetime_value,
       rank() OVER (PARTITION BY tier ORDER BY lifetime_value DESC) AS rank_in_tier
  FROM vw_customer_lifetime;
*/