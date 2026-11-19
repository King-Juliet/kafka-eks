import logging
import os
import sys
import time
import traceback
from typing import Optional

import psycopg2
import requests
from dotenv import load_dotenv

load_dotenv()


# configurations

BLOCKSTREAM_API = "https://blockstream.info/api"
DB_HOST = os.getenv("DB_HOST")
DB_PORT = os.getenv("DB_PORT")
DB_NAME = os.getenv("DB_NAME")
DB_USER = os.getenv("DB_USER")
DB_PASS = os.getenv("DB_PASS")

# Choose one of:
START_HEIGHT: Optional[int] = None  # or specify any block height to start from
START_DATE: Optional[str] = "2021-01-01"  # format YYYY-MM-DD or None

POLL_INTERVAL = 30  # seconds between checks
REQUEST_TIMEOUT = 30  # seconds for API request timeout


# LOGGING SETUP

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s",
    handlers=[
        logging.StreamHandler(sys.stdout),
        logging.FileHandler("etl_bitcoin.log", mode="a", encoding="utf-8"),
    ],
)
logger = logging.getLogger(__name__)


# DB HELPERS


def get_connection():
    """Create and return a PostgreSQL database connection.

    Establishes a connection using configured database credentials and
    returns a psycopg2 connection object.
    """
    return psycopg2.connect(
        host=DB_HOST, port=DB_PORT, dbname=DB_NAME, user=DB_USER, password=DB_PASS
    )


def ensure_state_table():
    """Ensure the ETL state table and datamart schema exist.

    Creates the datamart schema and etl_state table if they do not already
    exist. Commits the transaction on success and rolls back on failure.
    """
    conn = get_connection()
    cur = conn.cursor()
    try:
        cur.execute("CREATE SCHEMA IF NOT EXISTS datamart;")
        cur.execute("""
        CREATE TABLE IF NOT EXISTS etl_state (
            id SERIAL PRIMARY KEY,
            last_block_height BIGINT,
            updated_at TIMESTAMP DEFAULT now()
        );
        """)
        conn.commit()
    except Exception:
        conn.rollback()
        logger.error("Failed to ensure etl_state or datamart schema exists")
        logger.error(traceback.format_exc())
        raise
    finally:
        cur.close()
        conn.close()


def get_last_processed_height() -> Optional[int]:
    """Retrieve the most recent processed block height.

    Queries the etl_state table for the latest recorded block height.
    Returns the height as an integer or None if no value exists.
    """
    conn = get_connection()
    cur = conn.cursor()
    try:
        cur.execute("SELECT last_block_height FROM etl_state ORDER BY id DESC LIMIT 1;")
        row = cur.fetchone()
        return int(row[0]) if row and row[0] is not None else None
    finally:
        cur.close()
        conn.close()


def update_last_processed_height(height: int):
    """Insert a new last processed block height record.

    Inserts the provided block height into the etl_state table and commits
    the transaction. Rolls back and raises an exception if insertion fails.
    """
    conn = get_connection()
    cur = conn.cursor()
    try:
        cur.execute("INSERT INTO etl_state (last_block_height) VALUES (%s);", (height,))
        conn.commit()
        logger.info(f"Updated checkpoint: last_block_height = {height}")
    except Exception:
        conn.rollback()
        logger.error(f"Failed to update checkpoint for height {height}")
        logger.error(traceback.format_exc())
        raise
    finally:
        cur.close()
        conn.close()


# BLOCK HEIGHT - DATE helper


def get_height_from_date(date_str: str) -> int:
    """Fetch the earliest block height for a given date.

    Calls the Blockstream API endpoint for the specified date and returns
    the earliest block height found for that day.

    Raises:
        Exception: If no blocks are found or the API request fails.

    """
    retries = 3
    for attempt in range(retries):
        try:
            url = f"{BLOCKSTREAM_API}/blocks/{date_str}"
            resp = requests.get(url, timeout=REQUEST_TIMEOUT)
            resp.raise_for_status()
            blocks = resp.json()
            if not blocks:
                raise Exception(f"No blocks found for {date_str}")
            # API returns most recent first; take the last one for earliest of day
            block = blocks[-1]
            height = int(block["height"])
            logger.info(f"Using block {height} for date {date_str}")
            return height
        except (requests.exceptions.Timeout, requests.exceptions.ConnectionError) as e:
            wait_time = 2**attempt  # exponential backoff: 1s, 2s, 4s
            logger.warning(
                f"Attempt {attempt + 1}/{retries} failed for {date_str}: {e}. "
                f"Retrying in {wait_time}s..."
            )
            time.sleep(wait_time)
        except Exception as e:
            logger.error(f"Failed to fetch block height for date {date_str}: {e}")
            logger.error(traceback.format_exc())
            raise
    # If all retries fail
    logger.error(f"All retries failed for date {date_str}")
    raise Exception(
        f"Failed to fetch block height for {date_str} after {retries} attempts"
    )


# GET LATEST BLOCK HEIGHT


def get_latest_height() -> int:
    """Fetch the latest Bitcoin block height.

    Calls the Blockstream API tip endpoint and returns the most recent
    block height as an integer.
    """
    retries = 3
    for attempt in range(retries):
        try:
            resp = requests.get(
                f"{BLOCKSTREAM_API}/blocks/tip/height", timeout=REQUEST_TIMEOUT
            )
            resp.raise_for_status()
            return int(resp.text.strip())
        except requests.exceptions.Timeout as e:
            logger.error(f"Timeout when calling {BLOCKSTREAM_API}/blocks/tip/height")
            wait_time = 2**attempt  # exponential backoff: 1s, 2s, 4s
            logger.warning(
                f"Attempt {attempt + 1}/{retries} failed for latest height: {e}. "
                f"Retrying in {wait_time}s..."
            )
            time.sleep(wait_time)
    logger.error("All retries failed for latest height")
    raise Exception(
        f"Failed to fetch block height for latest height after {retries} attempts"
    )