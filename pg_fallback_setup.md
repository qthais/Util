
## 2. First Terraform Apply – Create Master

### Step 1: Configure Jenkins

1. Open the Jenkins Terraform Apply job.
2. Select **Build with Parameters**.
3. Set the following parameters:

| Parameter | Value |
|---|---|
| Repo | `dam-infra` |
| Branch | `develop` |
| Init Options | `--target=google_sql_database_instance.master` |
| Params Option | `--target=google_sql_database_instance.master` |

### Step 2: Apply Terraform

1. Ensure that the backup ID is removed from the master resource.
2. Execute the Jenkins job.
3. Wait for the Terraform apply to complete successfully.
4. Verify that the master instance has been created in GCP.

## 3. Restore Pre-Backup to Fallback Database

1. Open Google Cloud Console and navigate to Cloud SQL.
2. Select the PostgreSQL 17 source instance.
3. Open the **Backups** tab.
4. Select the required pre-backup and click **Restore**.
5. In the restore configuration, enter the instance name of the PostgreSQL 13 Fallback Database master created during the first Terraform apply.
6. Verify that the restore target is the correct fallback master instance.
7. Review the configuration and initiate the restore operation.
8. Wait for the restore to complete successfully.
9. Verify that the fallback master instance is available before proceeding.

## 4. Second Terraform Apply – Complete Infrastructure

### Step 1: Configure Jenkins

1. Open the Jenkins Terraform Apply job.
2. Select **Build with Parameters**.
3. Set the following parameters:

| Parameter | Value |
|---|---|
| Repo | `dam-infra` |
| Branch | `develop` |
| Init Options | `--target=google_sql_database_instance.master` |
| Params Option | Leave the master-only target out; use the remaining release parameters |

### Step 2: Apply Remaining Resources

1. Execute the Jenkins job without the master-only target.
2. Wait for Terraform to complete successfully.
3. Verify that the remaining resources are provisioned.

The second apply is expected to provision approximately 11 resources:

- 3 IP addresses.
- 3 firewall rules forwarding traffic to the database service attachments.
- 2 replica instances.
- 3 Google DNS records.

Verify that all resources are provisioned successfully.