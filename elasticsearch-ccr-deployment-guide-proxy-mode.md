# Elasticsearch Cross-Cluster Replication (CCR) Deployment Guide --- Proxy Mode

## 1. Scope and architecture

This guide describes a one-way CCR deployment between two self-managed
Elasticsearch 9.x clusters hosted on Google Cloud Platform (GCP), using
**Proxy mode** for the remote-cluster connection.

-   **Leader:** Existing production cluster with 3 VMs, existing TLS
    configuration, 40 existing indices, and aliases.
-   **Follower:** New cluster with 3 VMs.
-   **Connectivity:** Private network.
-   **Remote cluster mode:** Proxy.
-   **Authentication:** Cross-cluster API key.
-   **Remote Cluster Interface:** TCP port `9443` (default).
-   **TLS:** Reuse the existing Leader CA and certificates only if they
    satisfy the Remote Cluster Server TLS requirements.
-   **Existing indices:** Create follower indices manually.
-   **New indices:** Use Auto-follow patterns.

CCR replicates data from Leader to Follower. Follower indices are
read-only while following.

## 2. Proxy mode architecture

In Proxy mode, the Follower connects to a single TCP proxy endpoint. The
proxy forwards the TCP connection to the Remote Cluster Interface on the
Leader nodes.

``` text
Follower Elasticsearch cluster
  ├── Follower node 1
  ├── Follower node 2
  └── Follower node 3
          |
          | TCP connection to proxy endpoint
          | e.g. 10.30.0.10:9443
          v
GCP Internal TCP Proxy Load Balancer
          |
          +------> Leader node 1:9443
          +------> Leader node 2:9443
          +------> Leader node 3:9443
```

The proxy must be a TCP L4 proxy that forwards the Remote Cluster
Interface traffic. A Layer 7 HTTP/HTTPS load balancer or a passthrough
Network Load Balancer is not automatically equivalent to the TCP proxy
required by Elasticsearch Proxy mode. Confirm the exact GCP
load-balancer product and forwarding behavior before using an existing
load balancer.

In Proxy mode: - The Follower is configured with the proxy endpoint. -
The Follower does not need to connect directly to every Leader gateway
publish address. - The proxy must forward TCP connections to healthy
Leader nodes listening on port `9443`. - The proxy must preserve the TLS
stream end-to-end. It should not terminate and re-originate TLS unless
the design is explicitly configured and supported for the Elasticsearch
remote-cluster interface. - The proxy endpoint must be reachable from
all Follower nodes.

## 3. Deployment decisions

  Item                            Decision
  ------------------------------- -----------------------------------------------
  Replication direction           Leader → Follower
  Elasticsearch deployment        Self-managed, Elasticsearch 9.x
  Number of nodes                 3 Leader VMs and 3 Follower VMs
  Network                         GCP private network
  Connection mode                 Proxy
  Authentication                  Cross-cluster API key
  Remote Cluster Interface port   TCP 9443
  Proxy endpoint                  One stable private TCP proxy address and port
  Follower administration         Existing `elastic` superuser
  Existing indices                Manually create follower indices
  New indices                     Auto-follow

## 4. Prerequisites and pre-checks

### 4.1. Check Elasticsearch version and license

Run on both clusters:

``` http
GET /
```

Check the license:

``` http
GET /_license
```

Confirm compatible Elasticsearch versions and a license that supports
CCR and the required cross-cluster features.

### 4.2. Inventory existing indices and aliases

On Leader:

``` http
GET /_cat/indices?format=json&h=health,status,index,pri,rep,docs.count,store.size
```

Retrieve aliases:

``` http
GET /_alias
```

Prepare: - The list of 40 concrete indices to replicate. - Alias
definitions associated with those indices. - Naming patterns for future
indices.

### 4.3. Confirm the proxy product and behavior

Before configuring Elasticsearch, identify the GCP load-balancer type
currently available.

Confirm: - It is a TCP L4 proxy, not an HTTP/HTTPS Layer 7 proxy. - It
supports long-lived TCP connections. - It forwards connections to the
Leader nodes on TCP `9443`. - It performs health checks against a
suitable backend port. - It does not unexpectedly terminate the
Elasticsearch TLS session. - Its backend configuration includes all
intended Leader nodes. - Its frontend private IP and port are stable and
reachable from all Follower VMs.

Do not assume that an existing GCP load balancer is suitable based only
on the fact that it has one frontend IP and multiple backend instance
groups. GCP Internal passthrough Network Load Balancer, Internal Proxy
Network Load Balancer, and Internal Application Load Balancer have
different data paths and protocol behavior.

## 5. Stage 1 --- GCP network and TCP proxy

### 5.1. Leader backend firewall

Allow the proxy infrastructure to reach each Leader VM on TCP `9443`.

The source range depends on the selected GCP load-balancer
implementation and its health-check behavior. Configure the documented
proxy/backend and health-check source ranges for that specific product.
Do not guess or reuse an unrelated source range.

### 5.2. Follower-to-proxy firewall

Allow the three Follower VMs or their private subnet to connect to the
proxy's private frontend IP and configured TCP port.

Example:

  Property      Value
  ------------- ------------------------------------------------
  Source        Follower private subnet
  Destination   Internal TCP proxy frontend
  Protocol      TCP
  Port          `9443` (or the configured proxy frontend port)

### 5.3. Configure the TCP proxy

Configure the selected GCP TCP proxy with: - A stable internal frontend
address. - A TCP frontend port, preferably `9443`. - A backend service
containing the three Leader VMs. - Backend port `9443`. - A health check
appropriate for the selected load-balancer product. - A balancing policy
suitable for long-lived TCP connections.

The proxy should forward the TLS stream to the Leader Remote Cluster
Interface. The Leader remains responsible for presenting its Remote
Cluster Server certificate.

The following is an illustrative endpoint only:

``` text
PROXY_PRIVATE_IP:9443
```

Do not use this example as a real address.

### 5.4. Validate network connectivity

After the proxy is provisioned and the Leader is listening on port
`9443`, test from each Follower VM:

``` bash
nc -vz <PROXY_PRIVATE_IP> 9443
```

Also verify that the proxy reports healthy Leader backends.

## 6. Stage 2 --- Enable Remote Cluster Server on Leader

Proxy mode does not remove the requirement to enable the Remote Cluster
Server on Leader.

### 6.1. Reuse existing certificates

The existing PEM certificate files may be reused if they satisfy the
Remote Cluster Server TLS requirements:

-   The certificate and private key are valid and match.
-   The certificate is signed by the CA that the Follower will trust.
-   The certificate SAN is compatible with the TLS identity used for the
    proxy connection and the selected verification configuration.
-   The certificate is suitable for TLS server use.

The proxy endpoint is the address configured by the Follower. Because
TLS is passed through, the Leader certificate is presented through the
proxy. Ensure the certificate identity can be verified for the endpoint
used by the Follower. If the proxy hostname/IP differs from the
certificate SAN, plan the certificate naming and TLS verification
correctly; do not disable verification as a workaround.

Example existing files:

``` text
certs/
├── ca.crt
├── ca.key
├── es01.crt
├── es01.key
├── es02.crt
├── es02.key
├── es03.crt
└── es03.key
```

Only `ca.crt` is distributed to Follower. Never copy `ca.key` to
Follower.

### 6.2. Configure `elasticsearch.yml`

Enable the Remote Cluster Server on all three Leader nodes.

Example for Leader `es01`:

``` yaml
remote_cluster_server.enabled: true
remote_cluster.host: "LEADER_ES01_PRIVATE_IP"
remote_cluster.port: 9443

xpack.security.remote_cluster_server.ssl.enabled: true
xpack.security.remote_cluster_server.ssl.certificate: certs/es01.crt
xpack.security.remote_cluster_server.ssl.key: certs/es01.key
```

Example for Leader `es02`:

``` yaml
remote_cluster_server.enabled: true
remote_cluster.host: "LEADER_ES02_PRIVATE_IP"
remote_cluster.port: 9443

xpack.security.remote_cluster_server.ssl.enabled: true
xpack.security.remote_cluster_server.ssl.certificate: certs/es02.crt
xpack.security.remote_cluster_server.ssl.key: certs/es02.key
```

Example for Leader `es03`:

``` yaml
remote_cluster_server.enabled: true
remote_cluster.host: "LEADER_ES03_PRIVATE_IP"
remote_cluster.port: 9443

xpack.security.remote_cluster_server.ssl.enabled: true
xpack.security.remote_cluster_server.ssl.certificate: certs/es03.crt
xpack.security.remote_cluster_server.ssl.key: certs/es03.key
```

Use the actual configuration paths and private IPs for the environment.
The Leader Remote Cluster Server must listen on an address reachable by
the proxy backends.

If a private key is encrypted with a passphrase, add it to the
Elasticsearch keystore on the corresponding Leader node:

``` bash
bin/elasticsearch-keystore add \
  xpack.security.remote_cluster_server.ssl.secure_key_passphrase
```

If the key is not encrypted, this setting is not required.

### 6.3. Rolling restart Leader

These are static settings. Restart Leader nodes one at a time:

1.  Confirm cluster health.
2.  Restart Leader node 1.
3.  Wait for it to rejoin and verify cluster health.
4.  Repeat for Leader node 2.
5.  Repeat for Leader node 3.

Check:

``` http
GET /_cluster/health
```

Verify that port `9443` is listening on every Leader node:

``` bash
sudo ss -lntp | grep 9443
```

Then confirm that the GCP proxy reports the Leader backends healthy.

## 7. Stage 3 --- Create Cross-cluster API key on Leader

Use an administrator on Leader (the existing `elastic` superuser in this
deployment).

Create one Cross-cluster API key with replication access to: - The 40
existing indices. - The index patterns that will be used by Auto-follow
for future indices.

Example:

``` http
POST /_security/cross_cluster/api_key
{
  "name": "follower-to-leader-ccr",
  "access": {
    "replication": [
      {
        "names": [
          "index-a",
          "index-b",
          "index-c",
          "logs-*",
          "events-*"
        ]
      }
    ]
  },
  "metadata": {
    "purpose": "CCR replication from Leader to Follower through TCP proxy"
  }
}
```

Replace the sample names and patterns with the actual names. Avoid `"*"`
unless access to every index is intentionally required.

Save the `encoded` value from the response. The Follower uses it as the
remote-cluster credential.

Treat the encoded key as a secret. Do not commit it to source control or
place it in `elasticsearch.yml`.

## 8. Stage 4 --- Configure TLS trust and credentials on Follower

Perform these steps on all three Follower nodes.

### 8.1. Copy the CA certificate

Copy Leader's `ca.crt` to each Follower node, for example:

``` text
config/remote-cluster-ca.crt
```

Do not copy `ca.key`.

### 8.2. Configure `elasticsearch.yml`

Add on every Follower node:

``` yaml
xpack.security.remote_cluster_client.ssl.enabled: true

xpack.security.remote_cluster_client.ssl.certificate_authorities:
  - remote-cluster-ca.crt
```

Use the actual path relative to the Elasticsearch configuration
directory, or an absolute path as appropriate.

### 8.3. Add API key to Elasticsearch keystore

On every Follower node:

``` bash
bin/elasticsearch-keystore add \
  cluster.remote.leader.credentials
```

Enter the `encoded` value returned when creating the Cross-cluster API
key.

The alias `leader` must match the alias used when registering the remote
cluster.

### 8.4. Rolling restart Follower

Because TLS client settings were added to `elasticsearch.yml`, restart
Follower nodes one at a time:

1.  Restart Follower node 1 and wait for it to rejoin.
2.  Verify cluster health.
3.  Repeat for Follower node 2.
4.  Repeat for Follower node 3.

For a later credentials-only update, the secure settings can be reloaded
with the Reload Secure Settings API, provided no other static setting
change requires a restart.

## 9. Stage 5 --- Register Leader as a remote cluster on Follower in Proxy mode

Use the Follower cluster's Dev Tools or REST API.

Configure the single proxy endpoint:

``` http
PUT /_cluster/settings
{
  "persistent": {
    "cluster": {
      "remote": {
        "leader": {
          "mode": "proxy",
          "proxy_address": "PROXY_PRIVATE_IP:9443"
        }
      }
    }
  }
}
```

Replace `PROXY_PRIVATE_IP` and the port with the actual internal TCP
proxy frontend address.

Important: - Use `mode: "proxy"`. - Use `proxy_address`, not `seeds`. -
Do not configure the three Leader node IPs as seeds in Proxy mode. - The
proxy endpoint must forward TCP connections to the Leader Remote Cluster
Interface. - All Follower nodes that perform remote-cluster work must be
able to reach this endpoint.

Check the connection:

``` http
GET /_remote/info
```

Confirm that the `leader` entry reports a successful connection and
`mode: "proxy"`.

If the connection fails, check: - Proxy frontend reachability from all
Follower nodes. - Proxy backend health and TCP forwarding to Leader port
`9443`. - Leader Remote Cluster Server status. - TLS certificate
identity and CA trust. - Cross-cluster API key and alias consistency. -
Whether the proxy is actually a TCP L4 proxy and preserves the TLS
stream.

At this point, the remote connection exists, but no indices have been
replicated yet.

## 10. Stage 6 --- Create Auto-follow patterns for future indices

Create Auto-follow patterns on Follower before manually following
existing indices.

Example:

``` http
PUT /_ccr/auto_follow/logs-events
{
  "remote_cluster": "leader",
  "leader_index_patterns": [
    "logs-*",
    "events-*"
  ],
  "follow_index_pattern": "{{leader_index}}"
}
```

Replace the sample patterns with the actual naming conventions.

Check:

``` http
GET /_ccr/auto_follow/logs-events
```

And:

``` http
GET /_ccr/stats
```

Auto-follow applies to matching indices created after the pattern is
established. It does not automatically create followers for pre-existing
indices.

## 11. Stage 7 --- Create followers for the 40 existing indices

Create one follower index per concrete Leader index.

Example:

``` http
PUT /customer/_ccr/follow?wait_for_active_shards=1
{
  "remote_cluster": "leader",
  "leader_index": "customer"
}
```

Repeat for each of the 40 indices.

Recommended rollout: 1. Start with one small, representative index. 2.
Wait for initial recovery to complete. 3. Validate data and alias
behavior. 4. Continue in batches (for example, 5--10 indices). 5.
Monitor CPU, disk I/O, network throughput, recovery progress, and
cluster health.

Before creating followers, confirm that Leader indices are open and the
Cross-cluster API key grants replication access. Do not create followers
for aliases or system indices.

## 12. Stage 8 --- Validate aliases and index metadata

CCR replicates index data and relevant index metadata, including aliases
associated with the followed index. It does not replicate the entire
cluster configuration.

Retrieve aliases on both clusters:

``` http
GET /_alias
```

Compare: - Alias names. - Indices associated with each alias. - Alias
filters. - Search and index routing. - Write-index behavior.

Follower indices are read-only. Review `is_write_index` and verify the
resulting alias behavior on Follower.

Other configuration that may need to be created separately on Follower
includes: - Index templates and component templates. - ILM policies. -
Users and roles. - Cluster settings. - Snapshot repository
configuration. - Application-specific configuration.

CCR may copy an index's lifecycle policy name in its settings, but it
does not copy the ILM policy definition itself. Create the corresponding
policy on Follower if required.

## 13. Stage 9 --- Validate replication

### 13.1. Check follower information

``` http
GET /customer/_ccr/info
```

### 13.2. Check follower statistics

``` http
GET /customer/_ccr/stats
```

Cluster-wide:

``` http
GET /_ccr/stats
```

Review read/write exceptions, fatal exceptions, and replication
progress.

### 13.3. Compare document counts

On Leader:

``` http
GET /customer/_count
```

On Follower:

``` http
GET /customer/_count
```

Counts may temporarily differ during initial recovery or while
operations are being replicated. They should converge after replication
catches up.

### 13.4. Test a new document

If permitted by the production data process, create a test document on a
suitable Leader index:

``` http
POST /customer/_doc/ccr-test-001
{
  "name": "CCR test",
  "created_at": "2026-11-09T10:00:00Z"
}
```

Then retrieve it from Follower:

``` http
GET /customer/_doc/ccr-test-001
```

Do not attempt to write directly to the follower index.

## 14. Operational considerations

### 14.1. Follower indices are read-only

Perform writes, updates, and deletes on Leader. Follower receives the
replicated operations.

### 14.2. Index deletion is not automatically mirrored

Do not assume deleting a Leader index automatically deletes the
corresponding follower index. Define a separate index lifecycle and
cleanup procedure for Follower.

### 14.3. Manage API key lifecycle

If the Cross-cluster API key is revoked, expires, or is replaced, remote
authentication and replication can be affected.

Key-rotation procedure: 1. Create a replacement key with the required
access. 2. Update the secure setting on all Follower nodes. 3. Reload
secure settings or restart as required. 4. Verify remote connectivity
and CCR statistics. 5. Revoke the old key only after the replacement is
confirmed.

### 14.4. Monitor the deployment

Monitor: - Remote cluster connectivity (`GET /_remote/info`). - CCR
statistics (`GET /_ccr/stats`). - Follower exceptions and recovery
progress. - Follower disk capacity. - CPU, memory, disk I/O, and network
utilization. - Proxy backend health and connection behavior. - Index
lifecycle and retention consistency between clusters.

## 15. End-to-end implementation checklist

### Pre-check

-   [ ] Check Elasticsearch versions and license on both clusters.
-   [ ] Inventory the 40 concrete indices and aliases.
-   [ ] Define future index patterns.
-   [ ] Identify the exact GCP load-balancer product.
-   [ ] Confirm it is a TCP L4 proxy suitable for the Elasticsearch
    remote-cluster interface.

### GCP network and proxy

-   [ ] Provision or validate a stable internal TCP proxy frontend.
-   [ ] Configure backend forwarding to Leader nodes on TCP `9443`.
-   [ ] Configure backend health checks and required GCP firewall source
    ranges.
-   [ ] Allow Follower nodes to reach the proxy frontend.
-   [ ] Confirm proxy backend health and TCP connectivity.

### Leader

-   [ ] Enable `remote_cluster_server.enabled` on all three nodes.
-   [ ] Configure `remote_cluster.host` and port `9443`.
-   [ ] Configure the existing PEM certificate and key on each node.
-   [ ] Configure key passphrase in the Elasticsearch keystore if
    required.
-   [ ] Rolling restart the three Leader nodes.
-   [ ] Confirm port `9443` is listening and proxy backends are healthy.

### Authentication

-   [ ] Create a Cross-cluster API key on Leader.
-   [ ] Grant replication access to the 40 existing indices and future
    patterns.
-   [ ] Store the encoded key securely.

### Follower

-   [ ] Copy `ca.crt` to all three Follower nodes.
-   [ ] Configure Remote Cluster Client TLS.
-   [ ] Add `cluster.remote.leader.credentials` to all three
    Elasticsearch keystores.
-   [ ] Rolling restart the three Follower nodes.

### Remote connection

-   [ ] Register Leader on Follower with `mode: proxy`.
-   [ ] Configure `proxy_address` with the stable internal TCP proxy
    endpoint.
-   [ ] Confirm `connected: true` and `mode: proxy` in
    `GET /_remote/info`.

### Replication

-   [ ] Create Auto-follow patterns for future indices.
-   [ ] Test one existing index with manual follow.
-   [ ] Validate initial recovery and aliases.
-   [ ] Follow the remaining existing indices in batches.

### Validation and operations

-   [ ] Validate all 40 follower indices.
-   [ ] Compare aliases and required metadata.
-   [ ] Compare document counts after recovery.
-   [ ] Verify a new document replicates.
-   [ ] Establish monitoring, alerting, proxy health checks, and
    index-retention procedures.

## 16. Official Elasticsearch and GCP documentation

Consult documentation matching the exact Elasticsearch and GCP
load-balancer versions/products deployed:

-   [Remote clusters using API key
    authentication](https://www.elastic.co/docs/deploy-manage/remote-clusters/remote-clusters-api-key)
-   [Remote clusters on self-managed
    installations](https://www.elastic.co/docs/deploy-manage/remote-clusters/remote-clusters-self-managed)
-   [Create a cross-cluster API
    key](https://www.elastic.co/docs/api/doc/elasticsearch/operation/operation-security-create-cross-cluster-api-key)
-   [Create a follower
    index](https://www.elastic.co/docs/api/doc/elasticsearch/operation/operation-ccr-follow)
-   [Create an auto-follow
    pattern](https://www.elastic.co/docs/api/doc/elasticsearch/operation/operation-ccr-put-auto-follow-pattern)
-   [Cross-cluster
    replication](https://www.elastic.co/docs/deploy-manage/tools/cross-cluster-replication)
-   [Google Cloud Load Balancing
    documentation](https://cloud.google.com/load-balancing/docs)
