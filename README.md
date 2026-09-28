# Helix

```
  _    _ ______ _      _______   __
 | |  | |  ____| |    |_   _\ \ / /
 | |__| | |__  | |      | |  \ V / 
 |  __  |  __| | |      | |   > <  
 | |  | | |____| |____ _| |_ / . \ 
 |_|  |_|______|______|_____/_/ \_\
```

> **A high-concurrency, leaderless distributed transaction kernel written from scratch in pure Elixir, featuring Egalitarian Paxos consensus, Block-STM optimistic parallel execution, 256-bit authenticated Sparse Merkle Trees, delta-state CRDTs, and Jepsen-style deterministic chaos simulation.**

---

## Architectural Topology

```
+=============================================================================+
|                                HELIX KERNEL                                 |
+=============================================================================+
|                                                                             |
|   +-----------------------+              +------------------------------+   |
|   |   Binary TCP Server   |              |   Multi-Language Clients     |   |
|   |  (HLX1 Framing/CRC)   |              |   (Elixir / Python / TS)     |   |
|   +-----------+-----------+              +--------------+---------------+   |
|               |                                         |                   |
|               +--------------------+--------------------+                   |
|                                    |                                        |
|                     +--------------v--------------+                         |
|                     |     Cluster Request Router  |                         |
|                     |   (Consistent Hash Ring)    |                         |
|                     +--------------+--------------+                         |
|                                    |                                        |
|      +-----------------------------+-----------------------------+          |
|      |                                                           |          |
|   +--v--------------------------+             +------------------v-------+  |
|   |     Egalitarian Paxos       |             |    Delta-State CRDTs     |  |
|   |  - 1-RTT Fast-Path Consensus|             |  - AWSet (Add-Wins)      |  |
|   |  - 2-RTT Slow-Path Fallback |             |  - PNCounter             |  |
|   |  - Dynamic Conflict Detector|             |  - MVRegister / LWW      |  |
|   |  - Tarjan SCC Linearization |             |  - Causal Dot Stores     |  |
|   +--------------+--------------+             +------------------+-------+  |
|                  |                                               |          |
|   +--------------v--------------+                                |          |
|   |      Execution Queue        |                                |          |
|   |  (Topological Dependency)   |                                |          |
|   +--------------+--------------+                                |          |
|                  |                                               |          |
|   +--------------v-----------------------------------------------+-------+  |
|   |            Block-STM Optimistic Parallel Execution Engine            |  |
|   |  - Speculative Multi-Core Task Pools                                 |  |
|   |  - Multi-Version In-Memory State Store (MVMemory)                    |  |
|   |  - Read-Set Validation & Cascading Abort Rollback                    |  |
|   |  - Deterministic State Commit Pipeline                               |  |
|   +------------------------------+---------------------------------------+  |
|                                  |                                          |
|      +---------------------------+---------------------------+              |
|      |                                                       |              |
|   +--v--------------------------+             +--------------v-----------+  |
|   |  Sparse Merkle Tree (SMT)   |             |   Durability Subsystem   |  |
|   |  - 256-Bit Trie Commitments |             |  - Segmented WAL / CRC   |  |
|   |  - Inclusion Proofs         |             |  - Point-in-Time Snapshots| |
|   |  - Exclusion Proofs         |             |  - MVCC History Vacuum   |  |
|   +-----------------------------+             +--------------------------+  |
|                                                                             |
|   +----------------------------------------------------------------------+  |
|   |         Deterministic Chaos & Invariant Verification Suite           |  |
|   |   Discrete Virtual Clock | Network Partitions | Wing-Gong Checker    |  |
|   +----------------------------------------------------------------------+  |
+=============================================================================+
```

---

## Core Systems & Theoretical Primitives

### 1. Egalitarian Paxos Consensus (EPaxos)
Traditional distributed consensus engines (such as Raft or Multi-Paxos) funnel all client proposals through a single leader replica, creating an inherent throughput bottleneck and adding multi-region cross-datacenter round-trips.

Helix implements **Egalitarian Paxos** from first principles:
- **Leaderless Coordination**: Every node in the cluster acts as a command leader for transactions arriving locally.
- **1-RTT Fast Path**: When a transaction does not conflict with active concurrent proposals, consensus commits in a single round-trip (1 RTT) across a fast quorum:
  $$Q_{fast} = F + \lfloor (F + 1) / 2 \rfloor$$
- **Conflict Graph Resolution**: If concurrent transactions touch intersecting read/write keys, nodes take the 2-RTT slow path to merge dependency sets and sequence numbers:
  $$seq = 1 + \max(\text{deps}.seq)$$
- **Cycle Resolution via Tarjan's SCC**: Cyclic dependencies (such as mutual dependency loops between concurrent transactions) are decomposed into Strongly Connected Components (SCCs) in linear $O(V + E)$ time and topologically sorted with deterministic sequence number tie-breaking.

```
Fast Path (1 RTT):
  Client ----> Coordinator ----(PreAccept)----> Fast Quorum Replicas
           <--(Committed)--- <---(PreAcceptOK)--- (All agree on deps & seq)

Slow Path (2 RTT):
  Coordinator ----(Accept)----> Classic Quorum Replicas
          <---(AcceptOK)--- (Majority consensus on merged deps & max seq)
  Coordinator ----(Commit)----> Broadcast to All Replicas
```

### 2. Block-STM Optimistic Parallel State Execution
Executing ordered transactions sequentially limits throughput to a single CPU core. Helix utilizes the **Block-STM** speculative concurrency control algorithm to parallelize execution across all BEAM schedulers.
- **Speculative Scheduling**: Transactions within an ordered block execute concurrently in parallel worker tasks.
- **Multi-Version In-Memory Memory (MVMemory)**: Key-value updates are stored with writer transaction indices and incarnation tags. Reads query the highest predecessor write $T_j < T_i$.
- **Dynamic Dependency Tracking**: Reader transactions record observed version tags. If a predecessor writer aborts and produces a different write-set, all affected downstream readers are marked for re-execution.
- **Cascading Rollback**: Conflicting transactions increment their incarnation counters, discard speculative writes, and re-execute until an invariant validation sweep confirms zero stale reads.
- **Zero-Contention Commits**: Once validated, state transitions are materialized into storage in strict transaction order, guaranteeing strict serializability.

### 3. Authenticated Sparse Merkle Trees (SMT)
Helix binds its state to cryptographic commitments using a **256-bit Sparse Merkle Tree**:
- Every key is hashed to a 32-byte binary path using SHA-256.
- Cached branch node hashes eliminate redundant computations:
  $$\text{branch\_hash} = H(2 \mid\mid H_{left} \mid\mid H_{right})$$
- **Cryptographic Inclusion Proofs**: Proves that a given key-value pair exists in the committed state root with $O(\log N)$ sibling hashes.
- **Cryptographic Exclusion Proofs**: Mathematically proves non-membership for unpopulated keys by presenting audit paths to empty slots or conflicting leaves.

### 4. Delta-State Conflict-Free Replicated Data Types (CRDTs)
In addition to linearizable transactional registers, Helix includes a standalone delta-CRDT library:
- **Add-Wins Set (AWSet)**: Resolves concurrent additions and deletions using causal dot stores $(node, counter)$ without retaining persistent tombstones.
- **Positive-Negative Counter (PNCounter)**: Commutative join-semilattice supporting distributed increment and decrement mutations.
- **Multi-Value Register (MVRegister)**: Preserves concurrent conflicting updates until explicitly resolved by a successor write.
- **Last-Write-Wins Register (LWWRegister)**: Resolves concurrent updates deterministically using Hybrid Logical Clock (HLC) timestamps.
- **Observed-Remove Map (ORMap)**: Supports recursive CRDT composition with nested counters, sets, and registers.
- **Anti-Entropy Engine**: Periodically extracts and disseminates compressed delta payloads.

### 5. SWIM Cluster Membership & Gossip
Cluster membership is maintained using an implementation of the **SWIM** failure detection protocol:
- **Monotonic Incarnations**: Nodes refute erroneous suspicions by advancing their incarnation number and broadcasting alive events.
- **Indirect Probing (ping-req)**: If a direct ping fails, auxiliary peers attempt indirect probing to eliminate local network flake false-positives.
- **Bounded Epidemic Dissemination**: Membership events and state digests are piggybacked onto protocol messages with bounded retransmission limits.
- **Consistent Hash Ring**: Key ownership and replica quorums are assigned using a consistent hashing circle with configurable virtual nodes (vnodes).

### 6. Complex Event Processing (CEP) & Reactive Streaming
State transitions emit events into a backpressured stream processing kernel:
- **Tumbling, Sliding, and Session Windows**: Evaluates stream aggregations across event-time intervals and activity bursts.
- **Finite State Automaton (FSA) Pattern Matcher**: Detects temporal event correlations (e.g., $A \to B \to C$ within duration limits).
- **Demand-Driven Flow Control**: GenStage-style reactive backpressure preventing consumer process mailbox saturation.

### 7. Deterministic Simulation Testing (DST) & Jepsen Verification
Helix incorporates a built-in deterministic chaos harness inspired by FoundationDB and Jepsen:
- **Discrete Virtual Clock**: Advances simulated time in discrete ticks without wall-clock pauses.
- **Simulated Network Mesh**: Injects asymmetric partitions, packet drop rates, jitter delay, and duplicate message delivery.
- **Fault Injector**: Simulates ungraceful process terminations, clock skews, and single-bit payload flips.
- **Wing-Gong Linearizability Checker**: Validates that concurrent execution histories satisfy the real-time precedence partial order.

---

## Directory Structure

```
helix/
├── c_src/                         # Hardware-accelerated CRC-32C native utility
│   ├── helix_crc32c.c
│   ├── helix_crc32c.h
│   ├── main.c
│   └── Makefile
├── clients/
│   ├── python/                    # Python 3 wire client and benchmarks
│   │   ├── helix_client.py
│   │   └── test_client.py
│   └── typescript/                # TypeScript wire client
│       ├── package.json
│       ├── tsconfig.json
│       └── src/client.ts
├── lib/
│   ├── helix/
│   │   ├── application.ex         # Root OTP supervision tree
│   │   ├── benchmark.ex           # Performance benchmarking harness
│   │   ├── client.ex              # Native Elixir client SDK
│   │   ├── chaos/                 # Deterministic chaos and simulation
│   │   │   ├── fault_injector.ex
│   │   │   ├── linearizability_checker.ex
│   │   │   ├── scenario_runner.ex
│   │   │   ├── simulated_network.ex
│   │   │   └── virtual_clock.ex
│   │   ├── cluster/               # SWIM mesh and consistent hashing
│   │   │   ├── gossip.ex
│   │   │   ├── membership.ex
│   │   │   ├── node.ex
│   │   │   ├── partitioner.ex
│   │   │   └── router.ex
│   │   ├── consensus/             # Egalitarian Paxos engine
│   │   │   ├── ballot.ex
│   │   │   ├── conflict_detector.ex
│   │   │   ├── execution_queue.ex
│   │   │   ├── instance.ex
│   │   │   ├── messages.ex
│   │   │   ├── quorum.ex
│   │   │   ├── recovery.ex
│   │   │   └── replica.ex
│   │   ├── core/                  # Cryptography and data structures
│   │   │   ├── bitset.ex
│   │   │   ├── bloom_filter.ex
│   │   │   ├── conflict_graph.ex
│   │   │   ├── crc32c.ex
│   │   │   ├── hybrid_logical_clock.ex
│   │   │   ├── merkle_proof.ex
│   │   │   ├── sparse_merkle_tree.ex
│   │   │   ├── tarjan_scc.ex
│   │   │   ├── types.ex
│   │   │   ├── varint.ex
│   │   │   └── vector_clock.ex
│   │   ├── crdt/                  # Delta-state CRDT library
│   │   │   ├── aw_set.ex
│   │   │   ├── causal_context.ex
│   │   │   ├── lww_register.ex
│   │   │   ├── mv_register.ex
│   │   │   ├── or_map.ex
│   │   │   ├── pn_counter.ex
│   │   │   ├── replication_engine.ex
│   │   │   └── type.ex
│   │   ├── net/                   # Binary wire protocol and TCP server
│   │   │   ├── codec.ex
│   │   │   ├── protocol.ex
│   │   │   └── server.ex
│   │   ├── stm/                   # Block-STM parallel state execution
│   │   │   ├── dependency_tracker.ex
│   │   │   ├── engine.ex
│   │   │   ├── mv_memory.ex
│   │   │   ├── transaction.ex
│   │   │   └── validator.ex
│   │   ├── storage/               # Persistence and storage engines
│   │   │   ├── engine.ex
│   │   │   ├── memory_engine.ex
│   │   │   ├── mvcc_store.ex
│   │   │   ├── snapshot.ex
│   │   │   └── wal.ex
│   │   ├── stream/                # Complex Event Processing (CEP)
│   │   │   ├── event.ex
│   │   │   ├── pattern.ex
│   │   │   ├── pipeline.ex
│   │   │   ├── query_compiler.ex
│   │   │   └── window.ex
│   │   ├── telemetry/             # Latency histograms and metrics
│   │   │   └── metrics.ex
│   │   └── tui/                   # Live terminal dashboard
│   │       └── dashboard.ex
│   └── helix.ex                   # Top-level API module
├── test/                          # Unit and integration test suites
│   ├── helix/
│   │   ├── chaos_test.exs
│   │   ├── cluster_test.exs
│   │   ├── consensus_test.exs
│   │   ├── core_test.exs
│   │   ├── crdt_test.exs
│   │   ├── integration_test.exs
│   │   ├── net_test.exs
│   │   ├── storage_test.exs
│   │   ├── stm_test.exs
│   │   ├── stream_test.exs
│   │   └── telemetry_test.exs
│   └── test_helper.exs
├── .formatter.exs
├── LICENSE
└── mix.exs
```

---

## Wire Protocol Framing

Every packet transmitted over TCP follows the 23-byte header structure:

```
 0                   1                   2                   3
 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
|                       Magic (0x484C5831)                      |
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
|    Version    |          Opcode               |               |
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+               +
|                     Correlation ID (64-bit)                   |
|                               +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
|                               |       Payload Length          |
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
|       Payload Length (cont)   |       CRC-32C Checksum        |
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
|       CRC-32C (cont)          |       Payload Bytes ...       |
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
```

---

## Performance Benchmarks

Benchmarks executed on Apple Silicon (M-series, 8 cores):

| Subsystem | Metric | Throughput / Latency |
|:---|:---|:---|
| **Sparse Merkle Tree (SMT)** | Insert Throughput | `185,500+ ops/sec` |
| **Sparse Merkle Tree (SMT)** | Proof Verification | `439,000+ ops/sec` |
| **Block-STM Parallel Engine** | Concurrent Transactions | `133,000+ TPS` |
| **Delta-CRDT Subsystem** | Join-Semilattice Merge | `< 1 us per merge` |
| **Egalitarian Paxos (EPaxos)** | 1-RTT Fast-Path Consensus | `< 250 us commit` |
| **CRC-32C Castagnoli** | Frame Integrity Verification | `> 1.2 GB/sec` |

---

## Quickstart & Verification

### Prerequisites
- Elixir 1.15+ / Erlang OTP 25+
- Zero external third-party dependencies required.

### 1. Run Complete Test Suite
```bash
mix test
```

### 2. Run Jepsen-Style Chaos Invariant Suite
```bash
mix chaos
```

### 3. Run Performance Benchmarks
```bash
mix bench
```

### 4. Launch Live Terminal TUI Dashboard
```bash
mix tui
```

### 5. Multi-Language Client Verification
```bash
# Python client tests
python3 clients/python/test_client.py

# Native C hardware verification
make -C c_src && ./c_src/helix_crc_test
```

---

## License

MIT License. Copyright (c) 2026 Aneesh Krishna.
