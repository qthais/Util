# Elasticsearch Cross-Cluster Replication (CCR) Deployment Guide

## 1. Scope and architecture

This guide describes a one-way CCR deployment between two self-managed
Elasticsearch 9.x clusters hosted on Google Cloud Platform (GCP).

-   **Leader:** Existing production cluster with 3 VMs, existing TLS
    configuration, 40 existing indices, and aliases.
-   **Follower:** New cluster with 3 VMs.
-   **Connectivity:** Private network.
-   **Remote cluster mode:** Sniff.
-   **Authentication:** Cross-cluster API key.
-   **Remote Cluster Interface:** TCP port `9443` (default).
-   **TLS:** Reuse the existing Leader CA and node certificates where
    they satisfy the remote-cluster TLS requirements.
-   **Existing indices:** Create follower indices manually.
-   **New indices:** Use Auto-follow patterns.

CCR replicates data from Leader to Follower. Follower indices are
read-only while following.

## 2. Deployment decisions

  Item                            Decision
  ------------------------------- --------------------------------------------
  Replication direction           Leader → Follower
  Elasticsearch deployment        Self-managed, Elasticsearch 9.x
  Number of nodes                 3 Leader VMs and 3 Follower VMs
  Network                         GCP private network
  Connection mode                 Sniff
  Authentication                  Cross-cluster API key
  Remote Cluster Interface port   TCP 9443
  Follower administration         Existing `elastic` superuser
  Existing indices                Manually create follower indices
  New indices                     Auto-follow
  Load balancer                   Not required for the selected Sniff design

## 3. Prerequisites and pre-checks

Perform these checks before changing cluster configuration.

### 3.1. Check Elasticsearch version and license

Run on both clusters:

``` http
GET /
```

Check the license:

``` http
GET /_license
```

Confirm that both clusters run compatible Elasticsearch versions and
that the license supports CCR and the required cross-cluster features.

### 3.2. Check Leader node roles

Run on Leader:

``` http
GET /_nodes?filter_path=nodes.*.name,nodes.*.roles,nodes.*.attributes
```

In Sniff mode, Elasticsearch discovers gateway nodes and the Follower
must be able to reach their published addresses. By default,
non-master-eligible nodes can be selected as gateway nodes; dedicated
master nodes are not selected by default.

Confirm that the Leader topology has reachable gateway nodes before
proceeding.

### 3.3. Inventory existing indices and aliases

Run on Leader:

``` http
GET /_cat/indices?format=json&h=health,status,index,pri,rep,docs.count,store.size
```

Retrieve aliases:

``` http
GET /_alias
```

Prepare: - The list of 40 concrete indices to replicate. - The alias
definitions associated with those indices. - The naming patterns for
indices that will be created in the future.

An alias is not itself a follower index. Create followers for concrete
indices.

## 4. Stage 1 --- GCP firewall

Allow inbound TCP traffic to the Leader VMs on port `9443`.

  Firewall property   Value
  ------------------- --------------------------------------------
  Direction           Ingress
  Target              The 3 Leader VMs
  Source              The 3 Follower VMs or their private subnet
  Protocol            TCP
  Port                `9443`
  Action              Allow

The Follower initiates connections to the Leader. Ensure that routing
and firewall policy allow each Follower node to reach the Leader gateway
publish addresses.

Port `9300` remains for transport communication within each
Elasticsearch cluster; it is not the remote-cluster interface used by
this API-key design.

After enabling the Remote Cluster Server in a later stage, test
connectivity from the Follower VMs:

``` bash
nc -vz <LEADER_PRIVATE_IP_1> 9443
nc -vz <LEADER_PRIVATE_IP_2> 9443
nc -vz <LEADER_PRIVATE_IP_3> 9443
```

## 5. Stage 2 --- Enable Remote Cluster Server on Leader

### 5.1. Reuse the existing certificates

The existing PEM certificate files may be reused if they meet the Remote
Cluster Server TLS requirements:

-   The certificate and private key are valid and match.
-   The certificate is signed by the CA that will be trusted by the
    Follower.
-   The certificate SAN contains the IP address or DNS name that the
    Follower uses to connect.
-   The certificate is suitable for TLS server use.

Do not create a new CA solely because CCR is being introduced if the
existing CA and certificates satisfy these requirements.

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

Only the CA certificate (`ca.crt`) is distributed to the Follower. Never
copy `ca.key` to the Follower.

### 5.2. Configure `elasticsearch.yml`

Add the Remote Cluster Server settings on every Leader node. Use the
corresponding private IP and node certificate/key on each VM.

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
Ensure that the published addresses used by Sniff are reachable from the
Follower.

If a private key is encrypted with a passphrase, add the passphrase to
the Elasticsearch keystore on the corresponding Leader node:

``` bash
bin/elasticsearch-keystore add \
  xpack.security.remote_cluster_server.ssl.secure_key_passphrase
```

If the key is not encrypted, this setting is not required.

### 5.3. Rolling restart Leader

These are static settings, so restart the Leader nodes one at a time:

1.  Confirm the cluster is healthy.
2.  Restart Leader node 1.
3.  Wait for it to rejoin and verify cluster health.
4.  Repeat for Leader node 2.
5.  Repeat for Leader node 3.

Check:

``` http
GET /_cluster/health
```

After the restart, verify that Elasticsearch listens on port `9443` on
every Leader node:

``` bash
sudo ss -lntp | grep 9443
```

## 6. Stage 3 --- Create the Cross-cluster API key on Leader

Use an administrator on Leader (for this deployment, the existing
`elastic` superuser).

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
    "purpose": "CCR replication from Leader to Follower"
  }
}
```

Replace the example names and patterns with the actual index names and
future index patterns. Avoid granting `"*"` unless access to all indices
is intentionally required.

Save the `encoded` value from the response. The Follower will use this
value as its remote-cluster credential.

Treat the encoded key as a secret. Do not commit it to source control or
place it in `elasticsearch.yml`.

## 7. Stage 4 --- Configure TLS trust and credentials on Follower

Perform these steps on all three Follower nodes.

### 7.1. Copy the CA certificate

Copy the Leader CA certificate (`ca.crt`) to each Follower node, for
example:

``` text
config/remote-cluster-ca.crt
```

Do not copy `ca.key`.

### 7.2. Configure `elasticsearch.yml`

Add on every Follower node:

``` yaml
xpack.security.remote_cluster_client.ssl.enabled: true

xpack.security.remote_cluster_client.ssl.certificate_authorities:
  - remote-cluster-ca.crt
```

Use the actual path relative to the Elasticsearch configuration
directory, or an absolute path as appropriate.

### 7.3. Add the API key to the Elasticsearch keystore

On every Follower node, run:

``` bash
bin/elasticsearch-keystore add \
  cluster.remote.leader.credentials
```

Enter the `encoded` value returned when the Cross-cluster API key was
created.

The alias `leader` must match the alias used when registering the remote
cluster in the next stage.

### 7.4. Rolling restart Follower

Because the TLS client settings were added to `elasticsearch.yml`,
restart the Follower nodes one at a time:

1.  Restart Follower node 1 and wait for it to rejoin.
2.  Verify cluster health.
3.  Repeat for Follower node 2.
4.  Repeat for Follower node 3.

For a later credentials-only update, Elasticsearch secure settings can
be reloaded using the Reload Secure Settings API, provided no other
static configuration change requires a restart.

## 8. Stage 5 --- Register Leader as a remote cluster on Follower

Use the Follower cluster's Dev Tools or REST API.

The remote cluster alias in this example is `leader`:

``` http
PUT /_cluster/settings
{
  "persistent": {
    "cluster": {
      "remote": {
        "leader": {
          "mode": "sniff",
          "seeds": [
            "LEADER_ES01_PRIVATE_IP:9443",
            "LEADER_ES02_PRIVATE_IP:9443",
            "LEADER_ES03_PRIVATE_IP:9443"
          ]
        }
      }
    }
  }
}
```

Replace the example addresses with the actual Leader private IPs.

Check the connection:

``` http
GET /_remote/info
```

Confirm that the `leader` entry reports:

``` json
{
  "connected": true,
  "mode": "sniff"
}
```

The number of connected nodes can vary according to gateway-node
selection and cluster topology. Do not assume it must always equal
three.

If the remote cluster is not connected, check: - GCP firewall and
routing for TCP `9443`. - Remote Cluster Server status on all Leader
nodes. - CA trust on all Follower nodes. - Certificate SAN versus the
addresses used for connection. - Cross-cluster API key value and alias
consistency. - Leader gateway publish addresses and node roles.

At this point, the remote connection exists, but no indices have been
replicated yet.

## 9. Stage 6 --- Create Auto-follow patterns for future indices

Create Auto-follow patterns on Follower before manually following the
existing indices. This reduces the chance of missing new indices created
during the migration.

Example for future `logs-*` and `events-*` indices:

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

The example preserves the Leader index name on Follower. Replace the
patterns with the actual naming conventions.

Check the pattern:

``` http
GET /_ccr/auto_follow/logs-events
```

Check CCR statistics:

``` http
GET /_ccr/stats
```

Auto-follow applies to indices created after the pattern is established.
It does not automatically create followers for indices that already
existed.

## 10. Stage 7 --- Create followers for the 40 existing indices

Create one follower index per concrete Leader index.

Example for an index named `customer`:

``` http
PUT /customer/_ccr/follow?wait_for_active_shards=1
{
  "remote_cluster": "leader",
  "leader_index": "customer"
}
```

Repeat for each of the 40 existing indices.

Recommended rollout: 1. Start with one small, representative index. 2.
Wait for initial recovery to complete. 3. Validate data and alias
behavior. 4. Continue in batches (for example, 5--10 indices). 5.
Monitor CPU, disk I/O, network throughput, recovery progress, and
cluster health.

Before creating followers, confirm that the Leader indices are open and
that the Cross-cluster API key grants replication access to them. Do not
attempt to create followers for aliases or system indices.

## 11. Stage 8 --- Validate aliases and index metadata

CCR replicates index data and relevant index metadata, including aliases
associated with the followed index. It does not replicate the entire
cluster configuration.

Retrieve aliases on Leader and Follower:

``` http
GET /_alias
```

Compare: - Alias names. - Indices associated with each alias. - Alias
filters. - Search and index routing. - Write-index behavior.

Because a follower index is read-only, a write alias cannot make the
follower index writable. In particular, review any `is_write_index`
configuration and validate the resulting alias behavior on Follower.

Other configuration that may need to be created separately on Follower
includes: - Index templates and component templates. - ILM policies. -
Users and roles. - Cluster settings. - Snapshot repository
configuration. - Application-specific configuration.

For example, CCR may copy an index's lifecycle policy name in its
settings, but it does not copy the ILM policy definition itself. Create
the corresponding policy on Follower if it is required.

## 12. Stage 9 --- Validate replication

### 12.1. Check follower information

For an example index:

``` http
GET /customer/_ccr/info
```

### 12.2. Check follower statistics

``` http
GET /customer/_ccr/stats
```

Cluster-wide statistics:

``` http
GET /_ccr/stats
```

Review read/write exceptions, fatal exceptions, and replication
progress.

### 12.3. Compare document counts

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

### 12.4. Test a new document

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

Remove test data through the normal Leader-side process if appropriate.
Do not attempt to write directly to the follower index.

## 13. Operational considerations

### 13.1. Follower indices are read-only

Writes, updates, and deletes should be performed on Leader. Follower
receives the replicated operations.

### 13.2. Index deletion is not automatically mirrored

Do not assume deleting a Leader index will automatically delete the
corresponding follower index. Define a separate index lifecycle and
cleanup procedure for Follower.

### 13.3. Manage API key lifecycle

If the Cross-cluster API key is revoked, expires, or is replaced, remote
authentication and replication can be affected. Maintain a controlled
key-rotation procedure: 1. Create a replacement key with the required
access. 2. Update the secure setting on all Follower nodes. 3. Reload
secure settings or restart as required. 4. Verify the remote connection
and CCR statistics. 5. Revoke the old key only after the replacement is
confirmed.

### 13.4. Monitor the deployment

Monitor at least: - Remote cluster connectivity (`GET /_remote/info`). -
CCR statistics (`GET /_ccr/stats`). - Follower exceptions and recovery
progress. - Follower disk capacity. - CPU, memory, disk I/O, and network
utilization. - Index lifecycle and retention consistency between
clusters.

## 14. End-to-end implementation checklist

### Pre-check

-   [ ] Check Elasticsearch versions and license on both clusters.
-   [ ] Check Leader node roles and gateway-node availability.
-   [ ] Inventory the 40 concrete indices and aliases.
-   [ ] Define future index patterns.

### Network

-   [ ] Allow TCP `9443` from Follower to all required Leader gateway
    addresses.
-   [ ] Confirm private routing between the clusters.

### Leader

-   [ ] Enable `remote_cluster_server.enabled` on all three nodes.
-   [ ] Configure `remote_cluster.host` and port `9443`.
-   [ ] Configure the existing PEM certificate and key on each node.
-   [ ] Configure a key passphrase in the Elasticsearch keystore if
    required.
-   [ ] Rolling restart the three Leader nodes.
-   [ ] Confirm that port `9443` is listening.

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

-   [ ] Register Leader on Follower in Sniff mode.
-   [ ] Confirm `connected: true` in `GET /_remote/info`.

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
-   [ ] Establish monitoring, alerting, and index-retention procedures.

## 15. Official Elasticsearch documentation

Consult the documentation for the exact Elasticsearch version deployed:

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
