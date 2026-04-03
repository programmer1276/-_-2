CREATE TABLE test_data (
    id SERIAL PRIMARY KEY,
    info TEXT,
    created_at TIMESTAMP DEFAULT current_timestamp
);

INSERT INTO test_data (info) VALUES 
('Initial data 1'),
('Initial data 2'),
('Initial data 3');

CREATE TABLESPACE ts1 LOCATION '/var/lib/postgresql/tablespace1';

CREATE TABLE test_data_ts (
    id SERIAL PRIMARY KEY,
    info TEXT
) TABLESPACE ts1;

INSERT INTO test_data_ts (info) VALUES 
('TS data 1'),
('TS data 2');

