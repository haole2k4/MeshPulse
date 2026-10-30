# MeshPulse

MeshPulse is an off-grid peer-to-peer and multi-hop mesh messaging system that enables nearby devices to communicate and relay messages without internet infrastructure.

## Identity & Topology

**Node**:
A single participating device in the off-grid network.
_Avoid_: Client, user, host, station

**Node ID**:
The immutable, unique identifier assigned to a Node across sessions.
_Avoid_: Device name, peer name, username

**Display Name**:
The human-readable alias chosen for a Node shown to people in conversations and maps.
_Avoid_: Node ID, hostname

**Direct Link**:
An active, single-hop radio connection between two adjacent Nodes.
_Avoid_: P2P mode, Wi-Fi link, local socket

**Relayed Route**:
A multi-hop path between two Nodes that communicates through one or more intermediate Nodes.
_Avoid_: Bridge, proxy, tunnel

**Topology Blocker**:
A deliberate rule on a Node that suppresses Direct Links with selected Nodes so traffic must travel over a Relayed Route.
_Avoid_: Firewall, blacklist, ban

## Messaging & Routing

**Mesh Packet**:
The self-contained envelope carrying a message or control signal, routing metadata, and hop budget across the network.
_Avoid_: Frame, segment, datagram, event

**Route Path**:
The ordered list of Node IDs a Mesh Packet has traversed from its origin to its current holder.
_Avoid_: Trace, call stack, history

**TTL (Time-To-Live)**:
The remaining number of hops a Mesh Packet is permitted to take before Nodes stop forwarding it.
_Avoid_: Timeout, expiration date, retry count

**Remaining Copies**:
The quota of packet replicas a Node may still distribute under Spray-and-Wait routing.
_Avoid_: Retry budget, fanout count

**Broadcast**:
A message addressed to every reachable Node within its hop budget.
_Avoid_: Multicast, push notification, announcement

**Direct Message**:
An end-to-end encrypted 1-to-1 message addressed to a single target Node ID.
_Avoid_: DM, private room, whisper

**Delivery Receipt (ACK)**:
A confirmation packet returned from the target Node of a Direct Message back to its origin Node.
_Avoid_: Read receipt, HTTP 200, ping reply

## Delay-Tolerant Networking & Safety

**DTN Outbox**:
A Node's local holding queue of undelivered packets waiting for an opportunistic path to their destination.
_Avoid_: Drafts, dead-letter queue, offline cache

**Summary Vector**:
A compact inventory of packet identifiers currently held by a Node, exchanged upon meeting another Node to reconcile missing messages.
_Avoid_: Sync table, manifest, diff

**SOS Signal**:
A high-priority emergency Broadcast carrying the sender's offline geographic coordinates and distress message.
_Avoid_: Alert, alarm, crash report
