-- Fashion-MNIST lab: schema + reference data for the PostgreSQL container.
-- Load it with:  podman cp db/init.sql fashion-db:/tmp/init.sql
--                podman exec fashion-db psql -d fashion -f /tmp/init.sql
-- Safe to run more than once.

CREATE TABLE IF NOT EXISTS fashion_classes (
    id        SMALLINT PRIMARY KEY,
    name      VARCHAR(20) UNIQUE NOT NULL,
    category  VARCHAR(20) NOT NULL
);

INSERT INTO fashion_classes (id, name, category) VALUES
    (0, 'T-shirt/top', 'tops'),
    (1, 'Trouser',     'bottoms'),
    (2, 'Pullover',    'tops'),
    (3, 'Dress',       'dresses'),
    (4, 'Coat',        'outerwear'),
    (5, 'Sandal',      'footwear'),
    (6, 'Shirt',       'tops'),
    (7, 'Sneaker',     'footwear'),
    (8, 'Bag',         'accessories'),
    (9, 'Ankle boot',  'footwear')
ON CONFLICT (id) DO NOTHING;

-- Same definition the API creates on first use
CREATE TABLE IF NOT EXISTS predictions (
    id          SERIAL PRIMARY KEY,
    created_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
    source      VARCHAR(10) NOT NULL,
    test_index  INTEGER,
    predicted   VARCHAR(20) NOT NULL,
    true_label  VARCHAR(20),
    confidence  REAL NOT NULL,
    api_host    VARCHAR(64)
);

-- Accuracy per clothing category, from the predictions on labelled test images
CREATE OR REPLACE VIEW accuracy_by_category AS
SELECT c.category,
       count(*)                                         AS predictions,
       count(*) FILTER (WHERE p.predicted = p.true_label) AS correct,
       round(100.0 * count(*) FILTER (WHERE p.predicted = p.true_label) / count(*), 1) AS accuracy_pct
FROM predictions p
JOIN fashion_classes c ON c.name = p.true_label
GROUP BY c.category
ORDER BY accuracy_pct DESC;
