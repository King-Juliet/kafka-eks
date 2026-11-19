"""Real-time Bitcoin ETL (Blockstream API) with incremental datamarts.

Features:
- Polls Blockstream API for new blocks
- Extract -> Transform -> Load into Postgres raw tables
- Uses bulk inserts (execute_batch) for performance
- Checkpointing in `etl_state` table
- Start from START_HEIGHT, START_DATE, or resume from checkpoint
- Graceful shutdown (KeyboardInterrupt)
- Robust logging and error handling
"""

# bitcoin_db

import os
import sys
import time
import traceback

import pandas as pd
import requests

# Adjust sys.path before importing local modules
sys.path.append(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
from psycopg2.extras import execute_batch

from .bitcoin_etl_helpers import (
    BLOCKSTREAM_API,
    REQUEST_TIMEOUT,
    get_connection,
    logger,
)

# EXTRACT


def extract_block(block_height: int):
    """Extract block and transaction data for a given block height.

    Fetches the block hash, block metadata, and associated transactions
    from the Blockstream API, including detailed transaction data.
    """
    retries = 3
    for attempt in range(retries):
        try:
            logger.info(f"Extracting block {block_height}")
            r = requests.get(
                f"{BLOCKSTREAM_API}/block-height/{block_height}",
                timeout=REQUEST_TIMEOUT,
            )
            r.raise_for_status()
            block_hash = r.text.strip()
            logger.info(f"Got block hash: {block_hash}")

            r2 = requests.get(
                f"{BLOCKSTREAM_API}/block/{block_hash}", timeout=REQUEST_TIMEOUT
            )
            r2.raise_for_status()
            block_data = r2.json()

            r3 = requests.get(
                f"{BLOCKSTREAM_API}/block/{block_hash}/txs", timeout=REQUEST_TIMEOUT
            )
            r3.raise_for_status()
            txs = r3.json()
            logger.info(
                f"Found {len(txs)} transactions in block {block_height} (first page)"
            )

            detailed_txs = []
            for tx in txs:
                txid = tx.get("txid")
                if not txid:
                    continue
                try:
                    rtx = requests.get(
                        f"{BLOCKSTREAM_API}/tx/{txid}", timeout=REQUEST_TIMEOUT
                    )
                    rtx.raise_for_status()
                    detailed_txs.append(rtx.json())
                except Exception as e:
                    logger.error(f"Failed to fetch tx {txid}: {e}")
                    logger.error(traceback.format_exc())

            logger.info(
                f"Extracted {len(detailed_txs)} detailed transactions for block {block_height}"
            )
            return block_data, detailed_txs

        except Exception as e:
            logger.error(
                f"Attempt {attempt + 1}/{retries} failed for block {block_height}: {e}"
            )
            logger.error(traceback.format_exc())
            # Exponential backoff
            wait_time = 2**attempt
            logger.info(f"Retrying in {wait_time} seconds...")
            time.sleep(wait_time)


# TRANSFORM


def transform_block(block_data):
    """Transform raw block data into a structured DataFrame.

    Converts block-level fields into a pandas DataFrame with standardized
    column names and appropriate data types.
    """
    try:
        logger.info("Transforming block data")
        block_df = pd.DataFrame(
            [
                {
                    "block_id": block_data.get("id"),
                    "height": int(block_data.get("height")),
                    "timestamp": pd.to_datetime(block_data.get("timestamp"), unit="s"),
                    "tx_count": int(block_data.get("tx_count", 0)),
                    "size": int(block_data.get("size", 0)),
                    "weight": int(block_data.get("weight", 0)),
                }
            ]
        )
        return block_df
    except Exception:
        logger.error("Transform step failed")
        logger.error(traceback.format_exc())
        raise


def transform_transactions_data(block_data, detailed_txs):
    """Transform transaction data into a structured DataFrame.

    Extracts relevant transaction fields and returns a DataFrame
    representing all transactions associated with a block.
    """
    try:
        logger.info("Transforming transactions data")
        tx_list = []

        for tx in detailed_txs:
            # block_time = tx.get("status", {}).get("block_time")
            # tx_time = pd.to_datetime(block_time, unit="s") if block_time else None

            tx_list.append(
                {
                    "txid": tx.get("txid"),
                    "block_id": block_data.get("id"),
                    "fee": tx.get("fee"),
                    "size": tx.get("size"),
                    "weight": tx.get("weight"),
                    "version": tx.get("version"),
                    "locktime": tx.get("locktime"),
                }
            )
        tx_df = (
            pd.DataFrame(tx_list)
            if tx_list
            else pd.DataFrame(
                columns=[
                    "txid",
                    "block_id",
                    "fee",
                    "size",
                    "weight",
                    "version",
                    "locktime",
                ]
            )
        )
        logger.info(f"Transform complete: {len(tx_df)} txs")
        return tx_df
    except Exception:
        logger.error("Transform step failed")
        logger.error(traceback.format_exc())
        raise


def transform_address_data(detailed_txs):
    """Transform transaction data into inputs, outputs, and address DataFrames.

    Processes transaction inputs and outputs to generate structured
    DataFrames and aggregates address-level statistics such as balances
    and activity timestamps.
    """
    try:
        logger.info("Transforming address data")

        input_list, output_list = [], []
        address_dict = {}

        for tx in detailed_txs:
            block_time = tx.get("status", {}).get("block_time")
            tx_time = pd.to_datetime(block_time, unit="s") if block_time else None

            # Inputs
            for vin in tx.get("vin", []):
                prevout = vin.get("prevout") or {}
                input_list.append(
                    {
                        "txid": tx.get("txid"),
                        "prev_txid": vin.get("txid"),
                        "prev_index": vin.get("vout"),
                        "input_address": prevout.get("scriptpubkey_address"),
                        "input_value": prevout.get("value"),
                    }
                )
                addr = prevout.get("scriptpubkey_address")
                if addr:
                    address_dict.setdefault(
                        addr,
                        {
                            "total_received": 0,
                            "total_sent": 0,
                            "first_seen": tx_time,
                            "last_seen": tx_time,
                        },
                    )
                    address_dict[addr]["total_sent"] += prevout.get("value", 0) or 0
                    address_dict[addr]["last_seen"] = (
                        tx_time or address_dict[addr]["last_seen"]
                    )

            # Outputs
            for idx, vout in enumerate(tx.get("vout", [])):
                output_list.append(
                    {
                        "txid": tx.get("txid"),
                        "vout_index": idx,
                        "output_address": vout.get("scriptpubkey_address"),
                        "output_value": vout.get("value"),
                        "spent": vout.get("spent", False),
                    }
                )
                addr = vout.get("scriptpubkey_address")
                if addr:
                    address_dict.setdefault(
                        addr,
                        {
                            "total_received": 0,
                            "total_sent": 0,
                            "first_seen": tx_time,
                            "last_seen": tx_time,
                        },
                    )
                    address_dict[addr]["total_received"] += vout.get("value", 0) or 0
                    if address_dict[addr]["first_seen"] is None:
                        address_dict[addr]["first_seen"] = tx_time
                    address_dict[addr]["last_seen"] = (
                        tx_time or address_dict[addr]["last_seen"]
                    )
        inputs_df = (
            pd.DataFrame(input_list)
            if input_list
            else pd.DataFrame(
                columns=[
                    "txid",
                    "prev_txid",
                    "prev_index",
                    "input_address",
                    "input_value",
                ]
            )
        )
        outputs_df = (
            pd.DataFrame(output_list)
            if output_list
            else pd.DataFrame(
                columns=[
                    "txid",
                    "vout_index",
                    "output_address",
                    "output_value",
                    "spent",
                ]
            )
        )

        addr_list = []
        for addr, stats in address_dict.items():
            balance = (stats.get("total_received", 0) or 0) - (
                stats.get("total_sent", 0) or 0
            )
            addr_list.append(
                {
                    "address": addr,
                    "total_received": stats.get("total_received", 0) or 0,
                    "total_sent": stats.get("total_sent", 0) or 0,
                    "balance": balance,
                    "first_seen": stats.get("first_seen"),
                    "last_seen": stats.get("last_seen"),
                }
            )
        address_df = (
            pd.DataFrame(addr_list)
            if addr_list
            else pd.DataFrame(
                columns=[
                    "address",
                    "total_received",
                    "total_sent",
                    "balance",
                    "first_seen",
                    "last_seen",
                ]
            )
        )

        logger.info(
            f"Transform complete: {len(inputs_df)} inputs, {len(outputs_df)} outputs, {len(address_df)} addresses"
        )
        return inputs_df, outputs_df, address_df

    except Exception:
        logger.error("Transform step failed")
        logger.error(traceback.format_exc())
        raise


# LOAD DATA


def load_block_data_to_postgres(block_df):
    """Load block data into PostgreSQL raw tables.

    Inserts block records into the bitcoin_blocks table using batch
    operations and commits the transaction on success.
    """
    try:
        logger.info("Loading block and related records into Postgres (raw tables)")
        conn = get_connection()
        cur = conn.cursor()
        if not block_df.empty:
            block_rows = [
                (
                    row.block_id,
                    row.height,
                    (
                        row.timestamp.to_pydatetime()
                        if not pd.isna(row.timestamp)
                        else None
                    ),
                    row.tx_count,
                    row.size,
                    row.weight,
                )
                for _, row in block_df.iterrows()
            ]
            execute_batch(
                cur,
                """
                INSERT INTO bitcoin_blocks (block_id, height, timestamp, tx_count, size, weight)
                VALUES (%s, %s, %s, %s, %s, %s)
                ON CONFLICT (block_id) DO NOTHING;
                """,
                block_rows,
                page_size=100,
            )
        conn.commit()
        logger.info("Load completed into raw tables.")
    except Exception:
        conn.rollback()
        logger.error("Load step failed")
        logger.error(traceback.format_exc())
        raise
    finally:
        try:
            cur.close()
            conn.close()
        except Exception as e:
            logger.warning(f"Error closing DB resources: {e}")


def load_transactions_data_to_postgres(tx_df):
    try:
        logger.info("Loading transactions df into Postgres (raw tables)")
        conn = get_connection()
        cur = conn.cursor()

        if not tx_df.empty:
            tx_rows = [
                (
                    row.txid,
                    row.block_id,
                    row.fee,
                    row.size,
                    row.weight,
                    row.version,
                    row.locktime,
                )
                for _, row in tx_df.iterrows()
            ]
            execute_batch(
                cur,
                """
                INSERT INTO bitcoin_transactions (txid, block_id, fee, size, weight, version, locktime)
                VALUES (%s, %s, %s, %s, %s, %s, %s)
                ON CONFLICT (txid) DO NOTHING;
                """,
                tx_rows,
                page_size=200,
            )
        conn.commit()
        logger.info("Load completed into raw tables.")
    except Exception:
        conn.rollback()
        logger.error("Load step failed")
        logger.error(traceback.format_exc())
        raise
    finally:
        try:
            cur.close()
            conn.close()
        except Exception as e:
            logger.warning(f"Error closing DB resources: {e}")


def load_addrress_data_to_postgres(inputs_df, outputs_df, address_df):
    """Load block data into PostgreSQL raw tables.

    Inserts block records into the bitcoin_blocks table using batch
    operations and commits the transaction on success.
    """
    try:
        logger.info(
            "Loading address data and related records into Postgres (raw tables)"
        )
        conn = get_connection()
        cur = conn.cursor()

        # Insert inputs
        if not inputs_df.empty:
            input_rows = [
                (
                    row.txid,
                    row.prev_txid,
                    row.prev_index,
                    row.input_address,
                    row.input_value,
                )
                for _, row in inputs_df.iterrows()
            ]
            execute_batch(
                cur,
                """
                INSERT INTO bitcoin_inputs (txid, prev_txid, prev_index, input_address, input_value)
                VALUES (%s, %s, %s, %s, %s)
                """,
                input_rows,
                page_size=500,
            )

        # Insert outputs
        if not outputs_df.empty:
            output_rows = [
                (
                    row.txid,
                    row.vout_index,
                    row.output_address,
                    row.output_value,
                    row.spent,
                )
                for _, row in outputs_df.iterrows()
            ]
            execute_batch(
                cur,
                """
                INSERT INTO bitcoin_outputs (txid, vout_index, output_address, output_value, spent)
                VALUES (%s, %s, %s, %s, %s)
                """,
                output_rows,
                page_size=500,
            )

        # Upsert addresses: we store cumulative totals coming from transform
        if not address_df.empty:
            addr_rows = [
                (
                    row.address,
                    row.total_received,
                    row.total_sent,
                    row.balance,
                    (
                        row.first_seen.to_pydatetime()
                        if not pd.isna(row.first_seen)
                        else None
                    ),
                    (
                        row.last_seen.to_pydatetime()
                        if not pd.isna(row.last_seen)
                        else None
                    ),
                )
                for _, row in address_df.iterrows()
            ]
            # We'll upsert by summing totals (the transform already computed per-block deltas)
            execute_batch(
                cur,
                """
                INSERT INTO bitcoin_addresses (address, total_received, total_sent, balance, first_seen, last_seen)
                VALUES (%s, %s, %s, %s, %s, %s)
                ON CONFLICT (address)
                DO UPDATE SET
                    total_received = bitcoin_addresses.total_received + EXCLUDED.total_received,
                    total_sent = bitcoin_addresses.total_sent + EXCLUDED.total_sent,
                    balance = bitcoin_addresses.balance + EXCLUDED.balance,
                    last_seen = GREATEST(bitcoin_addresses.last_seen, EXCLUDED.last_seen);
                """,
                addr_rows,
                page_size=200,
            )

        conn.commit()
        logger.info("Load completed into raw tables.")
    except Exception:
        conn.rollback()
        logger.error("Load step failed")
        logger.error(traceback.format_exc())
        raise
    finally:
        try:
            cur.close()
            conn.close()
        except Exception as e:
            logger.warning(f"Error closing DB resources: {e}")


# MAIN TRANSFORM AND LOAD WRAPPERS


def transform_n_load_block_data(block_data):
    """Transform and load block data.

    Applies transformation to raw block data and loads the result into
    PostgreSQL in a single workflow.
    """
    try:
        logger.info("Transforming and loading Block data")
        block_df = transform_block(block_data)
        load_block_data_to_postgres(block_df)
    except Exception:
        logger.error("Failed")
        logger.error(traceback.format_exc())
        raise


def transform_n_load_transaction_data(block_data, detailed_txs):
    """Transform and load transaction data.

    Processes raw transaction data and loads the resulting DataFrame
    into PostgreSQL.
    """
    try:
        logger.info("Transforming and loading transaction data")
        tx_df = transform_transactions_data(block_data, detailed_txs)
        load_transactions_data_to_postgres(tx_df)
    except Exception:
        logger.error("Failed")
        logger.error(traceback.format_exc())
        raise


def transform_n_load_address_data(detailed_txs):
    """Transform and load address data.

    Converts transaction data into address-related DataFrames and loads
    them into PostgreSQL tables.
    """
    try:
        logger.info("Transforming and loading address data")
        inputs_df, outputs_df, address_df = transform_address_data(detailed_txs)
        load_addrress_data_to_postgres(inputs_df, outputs_df, address_df)
    except Exception:
        logger.error("Failed")
        logger.error(traceback.format_exc())
        raise