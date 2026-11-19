-- INFERRED, NOT YOUR REAL DDL.
-- The ETL scripts were handed over without their table definitions, so these tables are reconstructed from the
-- INSERT statements in bitcoin_etl_main.py (column names and ON CONFLICT targets). Column TYPES are guesses
-- (values are satoshis, so BIGINT). Compare with the schema you tested against, and if it differs, replace this file
-- BEFORE the first deploy (or add a V002 that corrects it). The ETL's own etl_state table and datamart schema are
-- created by the scripts themselves (CREATE ... IF NOT EXISTS), so they are not repeated here.
--
-- Deliberately NO unique constraint on bitcoin_inputs / bitcoin_outputs: their INSERTs have no ON CONFLICT clause,
-- so a redelivered Kafka message would then crash the consumer instead of adding duplicate rows.

CREATE TABLE IF NOT EXISTS bitcoin_blocks (
    block_id   TEXT PRIMARY KEY,
    height     BIGINT NOT NULL,
    "timestamp" TIMESTAMP,
    tx_count   INTEGER,
    size       BIGINT,
    weight     BIGINT
);

CREATE TABLE IF NOT EXISTS bitcoin_transactions (
    txid     TEXT PRIMARY KEY,
    block_id TEXT,
    fee      BIGINT,
    size     INTEGER,
    weight   INTEGER,
    version  BIGINT,
    locktime BIGINT
);

CREATE TABLE IF NOT EXISTS bitcoin_inputs (
    txid          TEXT NOT NULL,
    prev_txid     TEXT,
    prev_index    INTEGER,
    input_address TEXT,
    input_value   BIGINT
);

CREATE TABLE IF NOT EXISTS bitcoin_outputs (
    txid           TEXT NOT NULL,
    vout_index     INTEGER,
    output_address TEXT,
    output_value   BIGINT,
    spent          BOOLEAN
);

CREATE TABLE IF NOT EXISTS bitcoin_addresses (
    address        TEXT PRIMARY KEY,
    total_received BIGINT NOT NULL DEFAULT 0,
    total_sent     BIGINT NOT NULL DEFAULT 0,
    balance        BIGINT NOT NULL DEFAULT 0,
    first_seen     TIMESTAMP,
    last_seen      TIMESTAMP
);

CREATE INDEX IF NOT EXISTS idx_bitcoin_blocks_height       ON bitcoin_blocks (height);
CREATE INDEX IF NOT EXISTS idx_bitcoin_transactions_block  ON bitcoin_transactions (block_id);
CREATE INDEX IF NOT EXISTS idx_bitcoin_inputs_txid         ON bitcoin_inputs (txid);
CREATE INDEX IF NOT EXISTS idx_bitcoin_outputs_txid        ON bitcoin_outputs (txid);