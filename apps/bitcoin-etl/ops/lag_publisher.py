#!/usr/bin/env python3
"""Publish consumer-group lag to CloudWatch so the consumer ASGs can scale on it.

Runs as a systemd unit on the producer instance (via launcher.py, which injects
the SASL_SSL settings). Every LAG_INTERVAL_SECONDS it computes, per consumer
group, the total lag across the group's topics and writes it as

    Namespace  KafkaEks
    Metric     ConsumerLag        (Count)
    Dimension  GroupId = <consumer group id>

lag(partition) = log_end_offset - max(committed_offset, log_start_offset)

- A group that has never committed counts everything still retained as lag.
- A committed offset that fell behind retention is clamped to the log start,
  so lag can never exceed what is actually left to read.
- If a group cannot be measured this round nothing is published for it. The
  "metric missing" alarm in Terraform catches that; publishing 0 would hide it.

Environment:
    LAG_TARGETS            "group=topic[,topic];group2=topic2" (defaults below)
    LAG_INTERVAL_SECONDS   default 60
    CLOUDWATCH_NAMESPACE   default KafkaEks
    plus the KAFKA_* variables read by launcher.py and the usual AWS region vars.
"""

from __future__ import annotations

import logging
import os
import signal
import sys
import threading
from collections.abc import Mapping, Sequence
from typing import Any

log = logging.getLogger("lag_publisher")

DEFAULT_TARGETS = (
    "bitcoin_block_consumer_group=bitcoin_block_data;"
    "bitcoin_address_consumer_group=bitcoin_transaction_data;"
    "bitcoin_consumer_group=bitcoin_block_data,bitcoin_transaction_data"
)
METRIC_NAME = "ConsumerLag"
KAFKA_TIMEOUT_S = 15


def parse_targets(spec: str) -> dict[str, list[str]]:
    """'g1=t1,t2;g2=t3' -> {'g1': ['t1', 't2'], 'g2': ['t3']}"""
    targets: dict[str, list[str]] = {}
    for part in filter(None, (p.strip() for p in spec.split(";"))):
        group, sep, topics = part.partition("=")
        names = [t.strip() for t in topics.split(",") if t.strip()]
        if not sep or not group.strip() or not names:
            raise ValueError(f"bad LAG_TARGETS entry: {part!r}")
        targets[group.strip()] = names
    if not targets:
        raise ValueError("LAG_TARGETS is empty")
    return targets


def compute_lag(
    committed: Mapping[int, int], low: Mapping[int, int], high: Mapping[int, int]
) -> int:
    """Total lag over the partitions in `high`. Negative committed = never committed."""
    total = 0
    for partition, end in high.items():
        start = low.get(partition, 0)
        position = max(committed.get(partition, -1), start)
        total += max(end - position, 0)
    return total


# --- Kafka reads -------------------------------------------------------------


def topic_partitions(admin: Any, topic: str) -> list[int]:
    meta = admin.list_topics(topic, timeout=KAFKA_TIMEOUT_S).topics.get(topic)
    if meta is None or meta.error is not None or not meta.partitions:
        raise RuntimeError(f"cannot read metadata for topic {topic}: {meta and meta.error}")
    return sorted(meta.partitions)


def log_offsets(admin: Any, topic: str, partitions: Sequence[int], spec: Any) -> dict[int, int]:
    from confluent_kafka import TopicPartition

    futures = admin.list_offsets({TopicPartition(topic, p): spec for p in partitions})
    return {tp.partition: fut.result(timeout=KAFKA_TIMEOUT_S).offset for tp, fut in futures.items()}


def committed_offsets(
    admin: Any, group: str, topic: str, partitions: Sequence[int]
) -> dict[int, int]:
    from confluent_kafka import ConsumerGroupTopicPartitions, TopicPartition

    request = ConsumerGroupTopicPartitions(group, [TopicPartition(topic, p) for p in partitions])
    result = admin.list_consumer_group_offsets([request])[group].result(timeout=KAFKA_TIMEOUT_S)
    return {tp.partition: tp.offset for tp in result.topic_partitions if tp.topic == topic}


def group_lag(admin: Any, group: str, topics: Sequence[str]) -> int:
    from confluent_kafka.admin import OffsetSpec

    total = 0
    for topic in topics:
        partitions = topic_partitions(admin, topic)
        low = log_offsets(admin, topic, partitions, OffsetSpec.earliest())
        high = log_offsets(admin, topic, partitions, OffsetSpec.latest())
        committed = committed_offsets(admin, group, topic, partitions)
        total += compute_lag(committed, low, high)
    return total


# --- CloudWatch --------------------------------------------------------------


def publish(cloudwatch: Any, namespace: str, lags: Mapping[str, int]) -> None:
    if not lags:
        return
    cloudwatch.put_metric_data(
        Namespace=namespace,
        MetricData=[
            {
                "MetricName": METRIC_NAME,
                "Dimensions": [{"Name": "GroupId", "Value": group}],
                "Value": float(lag),
                "Unit": "Count",
            }
            for group, lag in lags.items()
        ],
    )


def run_once(
    admin: Any, cloudwatch: Any, targets: Mapping[str, Sequence[str]], namespace: str
) -> dict[str, int]:
    lags: dict[str, int] = {}
    for group, topics in targets.items():
        try:
            lags[group] = group_lag(admin, group, topics)
        except Exception:  # one bad group must not stop the others
            log.exception("could not measure lag for group %s", group)
    try:
        publish(cloudwatch, namespace, lags)
    except Exception:
        log.exception("put_metric_data failed")
        return {}
    log.info("published lag %s", lags)
    return lags


def main() -> int:
    logging.basicConfig(
        level=logging.INFO, format="%(asctime)s [%(levelname)s] %(name)s: %(message)s"
    )
    import boto3
    from confluent_kafka.admin import AdminClient

    targets = parse_targets(os.environ.get("LAG_TARGETS", DEFAULT_TARGETS))
    interval = int(os.environ.get("LAG_INTERVAL_SECONDS", "60"))
    namespace = os.environ.get("CLOUDWATCH_NAMESPACE", "KafkaEks")

    # AdminClient is the launcher-patched class: SASL_SSL settings are merged in.
    admin = AdminClient({"client.id": "lag-publisher"})
    cloudwatch = boto3.client("cloudwatch")

    stop = threading.Event()
    for sig in (signal.SIGINT, signal.SIGTERM):
        signal.signal(sig, lambda *_: stop.set())

    log.info("starting: targets=%s interval=%ss namespace=%s", targets, interval, namespace)
    while not stop.is_set():
        run_once(admin, cloudwatch, targets, namespace)
        stop.wait(interval)
    return 0


if __name__ == "__main__":
    sys.exit(main())
